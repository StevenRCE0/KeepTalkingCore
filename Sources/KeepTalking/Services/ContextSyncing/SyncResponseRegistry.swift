import Foundation

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
/// `disconnect()`, matching the previous `DispatchQueue`-guarded behavior
/// (the continuation is resumed while holding the lock, exactly as before).
final class KeepTalkingSyncResponseRegistry<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Result, Error>] = [:]

    /// Register `request`, run `send`, and await the matching `resolve(_:with:)`
    /// or a `contextSyncTimeout` after `timeout` seconds. If `send` throws, the
    /// pending entry is failed immediately.
    func response(
        for request: UUID,
        timeout: TimeInterval,
        send: @escaping @Sendable () throws -> Void
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Result, Error>) in
                    self.lock.withLock { self.pending[request] = continuation }
                    do {
                        try send()
                    } catch {
                        self.fail(request, error: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fail(
                    request,
                    error: KeepTalkingClientError.contextSyncTimeout(request)
                )
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }
            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }
            return first
        }
    }

    /// Deliver `result` to its waiter. Returns false if none is pending (already
    /// timed out, or a stray/duplicate result).
    @discardableResult
    func resolve(_ request: UUID, with result: Result) -> Bool {
        lock.withLock {
            guard let continuation = pending.removeValue(forKey: request) else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    /// Fail a single pending request (no-op if not present).
    func fail(_ request: UUID, error: Error) {
        lock.withLock {
            guard let continuation = pending.removeValue(forKey: request) else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    /// Fail every pending request — used on disconnect.
    func failAll(error: Error) {
        let drained: [UUID: CheckedContinuation<Result, Error>] = lock.withLock {
            let snapshot = pending
            pending.removeAll()
            return snapshot
        }
        for continuation in drained.values {
            continuation.resume(throwing: error)
        }
    }
}
