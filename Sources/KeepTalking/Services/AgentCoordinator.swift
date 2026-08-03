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

    public init(
        id: UUID,
        contextID: UUID,
        promptPreview: String,
        createdAt: Date,
        state: State,
        agentTurnID: UUID?
    ) {
        self.id = id
        self.contextID = contextID
        self.promptPreview = promptPreview
        self.createdAt = createdAt
        self.state = state
        self.agentTurnID = agentTurnID
    }
}

// MARK: - Agent coordinator

/// Coordinates agent runs across contexts. A context's LOCAL turns are still
/// serialized — at most one active, the rest queued and started automatically —
/// but runs no longer execute strictly one-at-a-time overall: a suspended turn
/// frees its slot so the next can start, and delegated runs (`runDelegated`) bring
/// in work this node does on behalf of others. Hence "coordinator", not "queue".
actor AgentCoordinator {

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
    /// Continuations waiting for resume, keyed by their individual persisted
    /// continuation-message id. One agent run can suspend more than once.
    private var suspensionContinuations:
        [UUID: CheckedContinuation<KeepTalkingAgentTurnContinuationResponse, any Error>] = [:]
    /// Outer run id for each installed inner continuation.
    private var continuationTurnIDs: [UUID: UUID] = [:]
    /// Responses that arrived before the matching inner continuation suspended.
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
            if let turnID = runItem.agentTurnID {
                failContinuations(forTurn: turnID)
            }
            startNextQueued(contextID: contextID)
            emit()
            return
        }
        // Suspended run: it no longer holds an active slot. Resolve its
        // continuation with cancellation so its parked task unwinds; the next
        // queued run already started when it suspended.
        if let turnEntry = suspended.first(where: { $0.value.id == runID }) {
            let turnID = turnEntry.key
            suspended.removeValue(forKey: turnID)
            failContinuations(forTurn: turnID)
            emit()
            return
        }
        // Queued run: remove it. It never started, so its task can't deliver
        // completion — invoke `onCompleted` directly so anything awaiting it (a
        // `runDelegated` continuation) unwinds with cancellation instead of
        // hanging on a resume that would otherwise never come.
        for contextID in queued.keys {
            guard
                let idx = queued[contextID]?.firstIndex(where: { $0.id == runID })
            else { continue }
            let removed = queued[contextID]?.remove(at: idx)
            if queued[contextID]?.isEmpty == true { queued[contextID] = nil }
            removed?.onCompleted?(CancellationError())
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

    // MARK: - Delegated runs

    /// Holds a delegated run's typed result across the queue's `Void` work
    /// boundary. Safe as `@unchecked Sendable`: the write (in `work`) and the read
    /// (in `onCompleted`) both run inside this actor's isolation and are serialized
    /// with the awaiting continuation, so there is no concurrent access.
    private final class ResultBox<R>: @unchecked Sendable { var value: R? }

    /// Runs `work` as a CANCEL-ONLY run — no `agentTurnID`, so it is never parked
    /// for continuation/resume and is simply discarded if interrupted — and AWAITS
    /// its typed result. Cancelling the awaiting task (or `cancel(runID:)`) cancels
    /// the run, unwinding `work` as `CancellationError`. This is the delegation
    /// primitive: a node executing a unit of work on behalf of a caller, visible
    /// and stoppable in the same queue as local turns but never resumed like one.
    func runDelegated<R: Sendable>(
        runID: UUID = UUID(),
        contextID: UUID,
        label: String,
        work: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let box = ResultBox<R>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<R, Error>) in
                enqueue(
                    id: runID,
                    contextID: contextID,
                    agentTurnID: nil,
                    promptPreview: label,
                    work: { box.value = try await work() },
                    onCompleted: { error in
                        if let value = box.value {
                            continuation.resume(returning: value)
                        } else {
                            continuation.resume(throwing: error ?? CancellationError())
                        }
                    }
                )
            }
        } onCancel: {
            Task { await self.cancel(runID: runID) }
        }
    }

    /// Enqueues `work` as a cancel-only run and RETURNS the run id IMMEDIATELY;
    /// `onComplete` fires when it finishes (success, failure, or cancellation) —
    /// the push-wake hook for callers that must not hold the connection open.
    @discardableResult
    func runDelegatedDetached<R: Sendable>(
        runID: UUID = UUID(),
        contextID: UUID,
        label: String,
        work: @escaping @Sendable () async throws -> R,
        onComplete: @escaping @Sendable (Result<R, Error>) -> Void
    ) -> UUID {
        let box = ResultBox<R>()
        enqueue(
            id: runID,
            contextID: contextID,
            agentTurnID: nil,
            promptPreview: label,
            work: { box.value = try await work() },
            onCompleted: { error in
                if let value = box.value {
                    onComplete(.success(value))
                } else {
                    onComplete(.failure(error ?? CancellationError()))
                }
            }
        )
        return runID
    }

    var currentSnapshots: [KeepTalkingAgentRunSnapshot] { makeSnapshots() }

    /// Returns true if any active or suspended run is associated with the given agent turn ID.
    func hasActiveTurn(agentTurnID: UUID) -> Bool {
        active.values.contains { $0.item.agentTurnID == agentTurnID }
            || suspended[agentTurnID] != nil
    }

    // MARK: - Suspension & Resumption

    /// Called from within a running agent turn to suspend and wait for a
    /// continuation response from a remote node.  The run slot is freed so
    /// queued runs can proceed.  Returns when `deliverContinuationResponse`
    /// is called with a matching `continuationMessageID`.
    ///
    /// Freeing the slot means a queued run for the same context may start while
    /// this one is parked, and both may briefly overlap once this one resumes.
    /// That is the intended trade-off — a turn waiting on a remote/human
    /// response must not hold the context hostage. Runs that never entered the
    /// queue (the durable dispatcher path) have no slot here, so this is a
    /// no-op for them.
    func awaitContinuation(
        continuationID: UUID,
        agentTurnID: UUID,
        contextID: UUID
    ) async throws -> KeepTalkingAgentTurnContinuationResponse {
        // Check for early arrival
        if let early = earlyResponses.removeValue(forKey: continuationID) {
            return early
        }

        // Close the early-cancel race: if the parent task is already cancelled
        // before we install the continuation, throw immediately rather than
        // suspending forever (the onCancel handler can't see a continuation
        // that hasn't been installed yet).
        try Task.checkCancellation()

        // Vacate the per-context slot before parking, so a queued run can start.
        freeSlotForSuspension(agentTurnID: agentTurnID, contextID: contextID)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                suspensionContinuations[continuationID] = continuation
                continuationTurnIDs[continuationID] = agentTurnID
                emit()  // transition active run to .suspended in snapshots
            }
        } onCancel: {
            Task {
                await cancelContinuation(
                    continuationID: continuationID,
                    agentTurnID: agentTurnID
                )
            }
        }
    }

    /// Moves the active run for `agentTurnID` out of its context's active slot
    /// and into the suspended set, then starts the next queued run. The run's
    /// own task keeps executing — it is merely parked at the continuation await.
    /// No-op when the run has no active slot (the durable dispatcher path runs
    /// `runAI` directly without enqueueing here).
    private func freeSlotForSuspension(agentTurnID: UUID, contextID: UUID) {
        guard let entry = active[contextID], entry.item.agentTurnID == agentTurnID else {
            return
        }
        suspended[agentTurnID] = entry.item
        active[contextID] = nil
        startNextQueued(contextID: contextID)
        emit()
    }

    /// Delivers a continuation response, resuming a suspended agent turn.
    func deliverContinuationResponse(
        _ response: KeepTalkingAgentTurnContinuationResponse
    ) {
        let continuationID = response.continuationMessageID
        if let continuation = suspensionContinuations.removeValue(forKey: continuationID) {
            continuationTurnIDs[continuationID] = nil
            emit()  // transition back to .running before resuming
            continuation.resume(returning: response)
        } else {
            // The run hasn't suspended yet — stash for pickup
            earlyResponses[continuationID] = response
        }
    }

    /// Cancels a suspended run by failing its continuation.
    func cancelSuspended(agentTurnID: UUID) {
        suspended.removeValue(forKey: agentTurnID)
        failContinuations(forTurn: agentTurnID)
    }

    /// Continuation ids installed for `agentTurnID`.
    ///
    /// `suspensionContinuations` and `earlyResponses` are keyed by the per-park
    /// continuation-message id — one agent run can suspend more than once — while
    /// `active`/`suspended` are keyed by agentTurnID. `continuationTurnIDs` is the
    /// only bridge between the two; neither map may be indexed with the other's key.
    private func continuationIDs(forTurn agentTurnID: UUID) -> [UUID] {
        continuationTurnIDs.compactMap { $0.value == agentTurnID ? $0.key : nil }
    }

    /// True while at least one of `agentTurnID`'s continuations is still parked.
    private func hasPendingContinuation(forTurn agentTurnID: UUID) -> Bool {
        continuationIDs(forTurn: agentTurnID).contains {
            suspensionContinuations[$0] != nil
        }
    }

    /// Unwinds every continuation parked for `agentTurnID` with cancellation and
    /// discards any response stashed for it, so the run's task cannot be left
    /// awaiting a response that will never arrive. Idempotent.
    private func failContinuations(forTurn agentTurnID: UUID) {
        for continuationID in continuationIDs(forTurn: agentTurnID) {
            continuationTurnIDs[continuationID] = nil
            suspensionContinuations.removeValue(forKey: continuationID)?
                .resume(throwing: CancellationError())
        }
        earlyResponses = earlyResponses.filter { $0.value.agentTurnID != agentTurnID }
    }

    private func cancelContinuation(continuationID: UUID, agentTurnID: UUID) {
        suspended.removeValue(forKey: agentTurnID)
        continuationTurnIDs[continuationID] = nil
        if let continuation = suspensionContinuations.removeValue(forKey: continuationID) {
            continuation.resume(throwing: CancellationError())
        }
        earlyResponses[continuationID] = nil
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

        // A run that suspended was moved out of `active`; drop its suspended
        // record now that it has finished.
        if let turnID = item.agentTurnID {
            suspended.removeValue(forKey: turnID)
        }

        // Only clear/advance the slot if this run still owns it. A suspended run
        // that resumes may have been displaced by a later run that took the
        // freed slot — that later run owns the slot and will advance the queue
        // when it finishes.
        if active[item.contextID]?.item.id == item.id {
            active[item.contextID] = nil
            startNextQueued(contextID: item.contextID)
        }

        // Park failures so the UI can offer Retry / Dismiss — but ONLY resumable
        // local turns (agentTurnID != nil). A delegated/cancel-only run has
        // already unwound its awaiter via `onCompleted` (which resumed a one-shot
        // continuation); parking it would let `retry` re-run it and fire that
        // continuation a SECOND time → fatal "continuation misuse". Delegated runs
        // are discard-on-failure by design.
        if let error, !(error is CancellationError), item.agentTurnID != nil {
            failed[item.id] = (item: item, message: error.localizedDescription)
        }

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
                entry.item.agentTurnID.map(hasPendingContinuation(forTurn:)) ?? false
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
        for (turnID, item) in suspended {
            // An item stays in `suspended` from the moment it parks until it
            // actually finishes. It is only truly suspended WHILE its continuation
            // is still pending; once `deliverContinuationResponse` resumes it (drops
            // the pending continuation) it is running again — reflect that, otherwise
            // a resumed run reads as "suspended" until it completes.
            let isStillSuspended = hasPendingContinuation(forTurn: turnID)
            result.append(
                KeepTalkingAgentRunSnapshot(
                    id: item.id,
                    contextID: item.contextID,
                    promptPreview: item.promptPreview,
                    createdAt: item.createdAt,
                    state: isStillSuspended ? .suspended : .running,
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
