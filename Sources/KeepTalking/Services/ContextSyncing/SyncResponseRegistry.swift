import Foundation

private enum KeepTalkingSyncResponseRegistryError: LocalizedError {
    case duplicateRequest(UUID)

    var errorDescription: String? {
        switch self {
            case .duplicateRequest(let request):
                return "A context-sync request is already pending: \(request)."
        }
    }
}

/// One request/response round-trip keyed by request id, with a timeout.
///
/// The context-sync layer is request/response: send an envelope tagged with a
/// request UUID, await the matching result envelope (or time out). Every sync
/// resource (summary, messages, side notes, transcript summary, transcript
/// lines) needs the exact same wait/resolve/fail/timeout machinery — only the
/// `Result` type differs. This holds that machinery **once**; the client keeps
/// one instance per result type instead of a hand-rolled dict + trio each.
///
/// Lock-guarded (`@unchecked Sendable`) rather than an actor so `resolve`/`fail`
/// stay synchronous — they're called from the envelope handler and from
/// `disconnect()`, matching the previous `DispatchQueue`-guarded behavior.
final class KeepTalkingSyncResponseRegistry<Result: Sendable>: @unchecked Sendable {
    private struct Pending {
        let registrationID: UUID
        let continuation: CheckedContinuation<Result, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var closedError: Error?
    private var activeGeneration: UInt64?

    /// Register `request`, run `send`, and await the matching `resolve(_:with:)`
    /// or a `contextSyncTimeout` after `timeout` seconds. If `send` throws, the
    /// pending entry is failed immediately.
    func response(
        for request: UUID,
        timeout: TimeInterval,
        generation: UInt64? = nil,
        send: @escaping @Sendable () throws -> Void
    ) async throws -> Result {
        let registrationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Result, Error>) in
                let registrationError: Error? = lock.withLock {
                    if let generation,
                        generation != activeGeneration
                    {
                        return KeepTalkingClientError.clientDisconnected
                    }
                    if let closedError {
                        return closedError
                    }
                    guard pending[request] == nil else {
                        return
                            KeepTalkingSyncResponseRegistryError
                            .duplicateRequest(request)
                    }
                    pending[request] = Pending(
                        registrationID: registrationID,
                        continuation: continuation,
                        timeoutTask: nil
                    )
                    return nil
                }
                if let registrationError {
                    continuation.resume(throwing: registrationError)
                    return
                }

                guard !Task.isCancelled else {
                    failRegistered(
                        request,
                        registrationID: registrationID,
                        error: CancellationError()
                    )
                    return
                }

                do {
                    try send()
                } catch {
                    failRegistered(
                        request,
                        registrationID: registrationID,
                        error: error
                    )
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.failRegistered(
                        request,
                        registrationID: registrationID,
                        error: KeepTalkingClientError.contextSyncTimeout(request)
                    )
                }
                let retained = lock.withLock {
                    guard var entry = pending[request],
                        entry.registrationID == registrationID
                    else {
                        return false
                    }
                    entry.timeoutTask = timeoutTask
                    pending[request] = entry
                    return true
                }
                if !retained {
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            failRegistered(
                request,
                registrationID: registrationID,
                error: CancellationError()
            )
        }
    }

    /// Deliver `result` to its waiter. Returns false if none is pending (already
    /// timed out, or a stray/duplicate result).
    @discardableResult
    func resolve(_ request: UUID, with result: Result) -> Bool {
        guard let entry = take(request) else {
            return false
        }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(returning: result)
        return true
    }

    /// Fail a single pending request. Returns false if none is pending.
    @discardableResult
    func fail(_ request: UUID, error: Error) -> Bool {
        guard let entry = take(request) else {
            return false
        }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(throwing: error)
        return true
    }

    /// Reject new registrations until `open()` and fail every current waiter.
    func close(error: Error) {
        let drained: [Pending] = lock.withLock {
            closedError = error
            activeGeneration = nil
            let snapshot = pending
            pending.removeAll()
            return Array(snapshot.values)
        }
        for entry in drained {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    func open(generation: UInt64) {
        lock.withLock {
            activeGeneration = generation
            closedError = nil
        }
    }

    private func failRegistered(
        _ request: UUID,
        registrationID: UUID,
        error: Error
    ) {
        guard
            let entry = take(
                request,
                registrationID: registrationID
            )
        else {
            return
        }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func take(
        _ request: UUID,
        registrationID: UUID? = nil
    ) -> Pending? {
        lock.withLock {
            guard let entry = pending[request] else { return nil }
            if let registrationID {
                guard entry.registrationID == registrationID else {
                    return nil
                }
            }
            return pending.removeValue(forKey: request)
        }
    }
}
