import Foundation

/// Runtime coordinator for DELEGATED execution — this node doing a unit of work
/// ON BEHALF OF a caller. Deliberately general so the whole roadmap funnels
/// through one seam:
///
/// - **Provider-side ACT (today):** a caller's `kt_run_action` arrives over the
///   wire and this node executes the action's agent loop. The execution is
///   registered cancel-only in the run queue so it is visible, serialized per
///   context, and stoppable.
/// - **Task delegation (roadmap):** a weak device hands a whole TASK to a stronger
///   node; that node `summonMainOrchestrator(...)`s a full orchestrator turn as
///   the delegated work — not just a single action.
///
/// The run MECHANICS live in `AgentCoordinator` (`runDelegated` / `runDelegatedDetached`):
/// a delegated run is a cancel-only queue run — no `agentTurnID`, never parked for
/// continuation, discarded if interrupted. This coordinator is the thin policy +
/// capability facade over them, and the home of the orchestrator-summon hook.
actor KeepTalkingDelegationCoordinator {

    /// Mirrors `KeepTalkingActionExecutionMode`, kept distinct so delegation stays
    /// independent of the action-call wire model (task delegation reuses it
    /// without an action call).
    enum Mode: Sendable {
        case sync
        case detach
    }

    private let queue: AgentCoordinator
    private let log: (@Sendable (String) -> Void)?

    /// Runs a full MAIN orchestrator turn as delegated work. Injected post-init by
    /// the client (avoids a construction cycle with `KeepTalkingClient`).
    private var summonOrchestrator:
        (@Sendable (_ contextID: UUID, _ prompt: String, _ agentTurnID: UUID?) async -> Void)?

    init(queue: AgentCoordinator, log: (@Sendable (String) -> Void)? = nil) {
        self.queue = queue
        self.log = log
    }

    /// Wire the orchestrator-summon capability after construction.
    func setOrchestratorSummon(
        _ summon:
            @escaping @Sendable (_ contextID: UUID, _ prompt: String, _ agentTurnID: UUID?)
            async -> Void
    ) {
        self.summonOrchestrator = summon
    }

    // MARK: - Delegated execution

    /// Runs `work` as a cancel-only delegated run and AWAITS its result
    /// (exec-RPC: the caller holds the connection). Cancellation propagates into
    /// `work`.
    func runDelegatedSync<R: Sendable>(
        contextID: UUID,
        label: String,
        runID: UUID = UUID(),
        work: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let tag = runID.uuidString.prefix(8)
        log?(
            "[delegation] start run=\(tag) context=\(contextID.uuidString.prefix(8)) "
                + "mode=sync label=\(label)")
        do {
            let result = try await queue.runDelegated(
                runID: runID, contextID: contextID, label: label, work: work)
            log?("[delegation] done run=\(tag) label=\(label)")
            return result
        } catch is CancellationError {
            log?("[delegation] cancelled run=\(tag) label=\(label)")
            throw CancellationError()
        } catch {
            log?("[delegation] failed run=\(tag) label=\(label) error=\(error.localizedDescription)")
            throw error
        }
    }

    /// Enqueues `work` as a cancel-only delegated run and RETURNS the run id
    /// immediately; `onComplete` fires on finish — the push-wake path for callers
    /// that must not babysit a long run.
    @discardableResult
    func runDelegatedDetached<R: Sendable>(
        contextID: UUID,
        label: String,
        runID: UUID = UUID(),
        work: @escaping @Sendable () async throws -> R,
        onComplete: @escaping @Sendable (Result<R, Error>) -> Void
    ) async -> UUID {
        await queue.runDelegatedDetached(
            runID: runID, contextID: contextID, label: label, work: work,
            onComplete: onComplete)
    }

    /// Summons a full MAIN orchestrator turn as delegated work (roadmap: task
    /// delegation). No-op with a log line if the summon capability was never wired.
    func summonMainOrchestrator(
        contextID: UUID,
        prompt: String,
        agentTurnID: UUID? = nil
    ) async {
        guard let summonOrchestrator else {
            log?("[delegation] orchestrator summon requested but not wired")
            return
        }
        await summonOrchestrator(contextID, prompt, agentTurnID)
    }

    /// Cancels a delegated run by id (idempotent; no-op if already done).
    func cancel(runID: UUID) async {
        await queue.cancel(runID: runID)
    }
}
