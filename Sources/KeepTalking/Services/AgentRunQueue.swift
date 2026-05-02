import Foundation

// MARK: - Public types

public struct KeepTalkingAgentRunSnapshot: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case queued
        case running
        case suspended
        case failed(message: String)
    }

    public let id: UUID
    public let contextID: UUID
    public let promptPreview: String
    public let createdAt: Date
    public let state: State
    public let agentTurnID: UUID?
}

// MARK: - Queue actor

/// Serial per-context run queue.  At most one AI run is active per context;
/// additional enqueues are held in order and started automatically when the
/// preceding run finishes.
actor AgentRunQueue {

    private struct RunItem {
        let id: UUID
        let contextID: UUID
        let agentTurnID: UUID?
        let promptPreview: String
        let createdAt: Date
        let work: @Sendable () async throws -> Void
        /// Closure used to re-execute this run after a failure. May skip steps
        /// that were already side-effected (e.g. the user prompt was already
        /// persisted to the context). If nil, retry falls back to `work`.
        let retryWork: (@Sendable () async throws -> Void)?
        let onCompleted: (@Sendable (Error?) -> Void)?
    }

    /// Per-context backlog (items not yet running).
    private var queued: [UUID: [RunItem]] = [:]
    /// Per-context active run.
    private var active: [UUID: (item: RunItem, task: Task<Void, Never>)] = [:]
    /// Suspended turns awaiting continuation response, keyed by agentTurnID.
    private var suspended: [UUID: RunItem] = [:]
    /// Continuations waiting for resume, keyed by agentTurnID.
    private var suspensionContinuations:
        [UUID: CheckedContinuation<KeepTalkingAgentTurnContinuationResponse, any Error>] = [:]
    /// Continuation responses that arrived before the run suspended, keyed by agentTurnID.
    private var earlyResponses: [UUID: KeepTalkingAgentTurnContinuationResponse] = [:]
    /// Failed runs that the UI is still showing (with retry/dismiss buttons).
    private var failed: [UUID: (item: RunItem, message: String)] = [:]
    /// Run IDs that were cancelled by the user — their slot has already been
    /// freed and a new run may have started; the cancelled task's `finish`
    /// callback must NOT touch the slot when this set contains its ID.
    private var cancelledRunIDs: Set<UUID> = []

    /// Called on every state transition with the current flat snapshot list.
    nonisolated(unsafe) var onChanged: (@Sendable ([KeepTalkingAgentRunSnapshot]) -> Void)?

    // MARK: - Interface

    /// Enqueues a unit of work for `contextID`.  Starts immediately if the
    /// context has no active run; otherwise appends to the backlog.
    /// Returns the stable run ID so callers can cancel by ID if needed.
    @discardableResult
    func enqueue(
        id: UUID = UUID(),
        contextID: UUID,
        agentTurnID: UUID? = nil,
        promptPreview: String,
        work: @escaping @Sendable () async throws -> Void,
        retryWork: (@Sendable () async throws -> Void)? = nil,
        onCompleted: (@Sendable (Error?) -> Void)? = nil
    ) -> UUID {
        let item = RunItem(
            id: id,
            contextID: contextID,
            agentTurnID: agentTurnID,
            promptPreview: String(promptPreview.prefix(120)),
            createdAt: Date(),
            work: work,
            retryWork: retryWork,
            onCompleted: onCompleted
        )
        if active[contextID] == nil {
            start(item)
        } else {
            queued[contextID, default: []].append(item)
        }
        emit()
        return id
    }

    /// Cancels a run by ID regardless of whether it is active, queued, or
    /// suspended. The user-facing snapshot for the run disappears
    /// immediately; the underlying task continues unwinding in the
    /// background but its slot is freed so any queued run can start.
    /// Idempotent — repeated calls are no-ops.
    func cancel(runID: UUID) {
        // Active run: free the slot immediately, cancel its task, resolve any
        // suspended continuation, and start the next queued run if there is
        // one. The cancelled task's `finish` callback will see the run ID in
        // `cancelledRunIDs` and skip slot cleanup.
        if let entry = active.first(where: { $0.value.item.id == runID }) {
            let contextID = entry.key
            let runItem = entry.value.item
            guard !cancelledRunIDs.contains(runID) else { return }
            cancelledRunIDs.insert(runID)
            entry.value.task.cancel()
            active[contextID] = nil
            if let turnID = runItem.agentTurnID,
                let continuation = suspensionContinuations.removeValue(forKey: turnID)
            {
                continuation.resume(throwing: CancellationError())
            }
            startNextQueued(contextID: contextID)
            emit()
            return
        }
        // Queued run: drop silently.
        for contextID in queued.keys {
            guard
                let idx = queued[contextID]?.firstIndex(where: { $0.id == runID })
            else { continue }
            queued[contextID]?.remove(at: idx)
            if queued[contextID]?.isEmpty == true { queued[contextID] = nil }
            emit()
            return
        }
        // Failed run is dismissed via `dismiss(runID:)`, not cancel — but if a
        // caller does invoke cancel on a failed entry, treat it as dismiss.
        if failed.removeValue(forKey: runID) != nil {
            emit()
        }
    }

    /// Removes a failed run from the queue (the user clicked Dismiss).
    func dismiss(runID: UUID) {
        if failed.removeValue(forKey: runID) != nil {
            emit()
        }
    }

    /// Re-runs a previously failed entry. Returns false if no failed entry
    /// exists for `runID`. Uses the captured `retryWork` closure if present
    /// (which typically skips the prompt-persist step) — otherwise the
    /// original `work` closure.
    @discardableResult
    func retry(runID: UUID) -> Bool {
        guard let entry = failed.removeValue(forKey: runID) else { return false }
        let original = entry.item
        let work = original.retryWork ?? original.work
        let newItem = RunItem(
            id: original.id,
            contextID: original.contextID,
            agentTurnID: original.agentTurnID,
            promptPreview: original.promptPreview,
            createdAt: Date(),
            work: work,
            retryWork: original.retryWork,
            onCompleted: original.onCompleted
        )
        if active[original.contextID] == nil {
            start(newItem)
        } else {
            queued[original.contextID, default: []].append(newItem)
        }
        emit()
        return true
    }

    var currentSnapshots: [KeepTalkingAgentRunSnapshot] { makeSnapshots() }

    /// Returns true if any active or suspended run is associated with the given agent turn ID.
    func hasActiveTurn(agentTurnID: UUID) -> Bool {
        active.values.contains { $0.item.agentTurnID == agentTurnID }
    }

    // MARK: - Suspension & Resumption

    /// Called from within a running agent turn to suspend and wait for a
    /// continuation response from a remote node.  The run slot is freed so
    /// queued runs can proceed.  Returns when `deliverContinuationResponse`
    /// is called with a matching `agentTurnID`.
    func awaitContinuation(
        agentTurnID: UUID
    ) async throws -> KeepTalkingAgentTurnContinuationResponse {
        // Check for early arrival
        if let early = earlyResponses.removeValue(forKey: agentTurnID) {
            return early
        }

        // Close the early-cancel race: if the parent task is already cancelled
        // before we install the continuation, throw immediately rather than
        // suspending forever (the onCancel handler can't see a continuation
        // that hasn't been installed yet).
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                suspensionContinuations[agentTurnID] = continuation
                emit()  // transition active run to .suspended in snapshots
            }
        } onCancel: {
            Task {
                await cancelSuspended(agentTurnID: agentTurnID)
            }
        }
    }

    /// Delivers a continuation response, resuming a suspended agent turn.
    func deliverContinuationResponse(
        _ response: KeepTalkingAgentTurnContinuationResponse
    ) {
        let turnID = response.agentTurnID
        if let continuation = suspensionContinuations.removeValue(forKey: turnID) {
            emit()  // transition back to .running before resuming
            continuation.resume(returning: response)
        } else {
            // The run hasn't suspended yet — stash for pickup
            earlyResponses[turnID] = response
        }
    }

    /// Cancels a suspended run by failing its continuation.
    func cancelSuspended(agentTurnID: UUID) {
        if let continuation = suspensionContinuations.removeValue(forKey: agentTurnID) {
            continuation.resume(throwing: CancellationError())
        }
        earlyResponses.removeValue(forKey: agentTurnID)
    }

    // MARK: - Private

    private func start(_ item: RunItem) {
        let task = Task {
            var workError: (any Error)? = nil
            do {
                try await item.work()
            } catch is CancellationError {
                // intentional stop — treat as clean
            } catch {
                workError = error
            }
            item.onCompleted?(workError)
            finish(item: item, error: workError)
        }
        active[item.contextID] = (item: item, task: task)
    }

    private func finish(item: RunItem, error: (any Error)?) {
        // If this run was cancelled by the user, the slot was already freed
        // (and possibly reassigned to a new active run). Don't touch state.
        if cancelledRunIDs.remove(item.id) != nil {
            emit()
            return
        }

        active[item.contextID] = nil

        // Park failures so the UI can offer Retry / Dismiss.
        if let error, !(error is CancellationError) {
            failed[item.id] = (item: item, message: error.localizedDescription)
        }

        startNextQueued(contextID: item.contextID)
        emit()
    }

    private func startNextQueued(contextID: UUID) {
        guard active[contextID] == nil else { return }
        guard var queue = queued[contextID], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queued[contextID] = queue.isEmpty ? nil : queue
        start(next)
    }

    private func makeSnapshots() -> [KeepTalkingAgentRunSnapshot] {
        var result: [KeepTalkingAgentRunSnapshot] = []
        for (_, entry) in active {
            let isSuspended =
                entry.item.agentTurnID.map {
                    suspensionContinuations[$0] != nil
                } ?? false
            result.append(
                KeepTalkingAgentRunSnapshot(
                    id: entry.item.id,
                    contextID: entry.item.contextID,
                    promptPreview: entry.item.promptPreview,
                    createdAt: entry.item.createdAt,
                    state: isSuspended ? .suspended : .running,
                    agentTurnID: entry.item.agentTurnID
                ))
        }
        for (_, items) in queued {
            for item in items {
                result.append(
                    KeepTalkingAgentRunSnapshot(
                        id: item.id,
                        contextID: item.contextID,
                        promptPreview: item.promptPreview,
                        createdAt: item.createdAt,
                        state: .queued,
                        agentTurnID: item.agentTurnID
                    ))
            }
        }
        for (_, item) in suspended {
            result.append(
                KeepTalkingAgentRunSnapshot(
                    id: item.id,
                    contextID: item.contextID,
                    promptPreview: item.promptPreview,
                    createdAt: item.createdAt,
                    state: .suspended,
                    agentTurnID: item.agentTurnID
                ))
        }
        for (_, entry) in failed {
            result.append(
                KeepTalkingAgentRunSnapshot(
                    id: entry.item.id,
                    contextID: entry.item.contextID,
                    promptPreview: entry.item.promptPreview,
                    createdAt: entry.item.createdAt,
                    state: .failed(message: entry.message),
                    agentTurnID: entry.item.agentTurnID
                ))
        }
        result.sort { lhs, rhs in
            // running first, then suspended/queued by createdAt, failed last.
            func order(_ s: KeepTalkingAgentRunSnapshot.State) -> Int {
                switch s {
                    case .running: return 0
                    case .suspended: return 1
                    case .queued: return 2
                    case .failed: return 3
                }
            }
            let lo = order(lhs.state)
            let ro = order(rhs.state)
            if lo != ro { return lo < ro }
            return lhs.createdAt < rhs.createdAt
        }
        return result
    }

    private func emit() {
        onChanged?(makeSnapshots())
    }
}
