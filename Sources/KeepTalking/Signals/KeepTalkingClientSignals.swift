import Foundation

/// Everything a `KeepTalkingClient` pushes out, in one owned box.
///
/// Every event the client reports leaves through a signal: multicast,
/// delivered asynchronously in emission order, never inline on the producer
/// (see ``KeepTalkingSignal``). Handlers that return a decision
/// (`setActionApprovalHandler`, `setIncomingTrustHandler`, …) stay closures on
/// the client and are deliberately *not* signals.
///
/// The box owns every primitive, including the ones a sub-object *drives*:
/// the connection writes `lifecycle`, `presence` and `transportStats`, the
/// agent coordinator writes `agentRuns`. Ownership here, authorship there —
/// so a signal is always the client instance's view, never a hook on the
/// component that happens to produce it. `KeepTalkingClient` exposes the
/// members flat through dynamic member lookup (`client.lifecycle`).
public final class KeepTalkingClientSignals: Sendable {
    /// Every envelope applied locally — inbound, after the SDK's own handlers
    /// ran and only when it changed something, plus the local echo of an
    /// outgoing message, attachment or continuation update.
    public let envelopes = KeepTalkingSignal<any KeepTalkingEnvelope>()
    public let rawMessages = KeepTalkingSignal<String>()
    /// A blob changed availability or crossed a visible receive-progress step.
    public let blobAvailabilityChanges = KeepTalkingSignal<KeepTalkingBlobAvailabilityChange>()
    /// Fires on BOTH sides of a completed trust handshake — initiator when the
    /// accept lands, responder when the complete lands. At that instant the
    /// local relation is `.trusted`, so a grant issued from a handler rides
    /// the very next node-status broadcast.
    public let trustEstablishments = KeepTalkingSignal<KeepTalkingTrustEstablishment>()
    /// One batch per committed grant mutation — after the database work
    /// returned, with one commit per peer whose access changed. Never emits
    /// when the mutation throws; only the instance mutators emit.
    public let grantCommits = KeepTalkingSignal<[KeepTalkingGrantCommit]>()
    public let contextSyncEvents = KeepTalkingSignal<KeepTalkingContextSyncEvent>()
    /// A context's side notes changed — locally or by merge.
    public let sideNoteChanges = KeepTalkingSignal<UUID>()
    /// Messages were deleted from a context — locally or by merge. Message
    /// pages only ever add rows, so a message cache must re-read on this.
    public let messageDeletions = KeepTalkingSignal<KeepTalkingMessageDeletion>()
    /// A context's threads changed — a mark, a merge, a chitter-chatter flag,
    /// an archive, a sync's re-threading. Carries the context; re-read its
    /// threads and boundaries.
    public let threadChanges = KeepTalkingSignal<UUID>()
    /// The derived semantic index for a context needs reconciling. Enqueue
    /// best-effort work; the persisted thread rows remain the source of truth.
    public let semanticIndexReconciliations = KeepTalkingSignal<UUID>()
    /// Invalidation ping: the mappings table moved; re-read.
    public let mappingChanges = KeepTalkingSignal<Void>()
    public let actionCallActivities = KeepTalkingSignal<KeepTalkingActionCallActivity>()
    /// An agent run finished — normally, with an error, or after cancellation.
    public let agentRunCompletions = KeepTalkingSignal<KeepTalkingAgentRunCompletion>()
    /// An agent turn suspended to wait on an out-of-band continuation. A
    /// non-blocking driver (e.g. the voice bridge) acknowledges and detaches.
    public let agentTurnSuspensions = KeepTalkingSignal<KeepTalkingAgentTurnSuspension>()
    /// A previously suspended turn resumed (fulfilled or rejected).
    public let agentTurnResumptions = KeepTalkingSignal<KeepTalkingAgentTurnResumption>()
    /// A voice-call transcript line was persisted — own mic or a peer's.
    /// Carries the Sendable envelope payload so no Fluent model crosses the
    /// actor boundary.
    public let voiceTranscriptLines = KeepTalkingSignal<KeepTalkingVoiceCallTranscriptLinePayload>()
    /// Diagnostic log lines from every layer of the SDK. Subscribe early: an
    /// event signal does not replay.
    public let log = KeepTalkingSignal<String>()
    /// Progress of `registerLocalActionsInExecutors()`.
    public let executorRegistration = KeepTalkingStateSignal<KeepTalkingExecutorRegistration>(.idle)

    // MARK: State driven by sub-objects

    /// Connection lifecycle: phase, generation, transport health and route.
    /// Replays on subscribe. Driven by the connection.
    public let lifecycle = KeepTalkingStateSignal<KeepTalkingClientLifecycle>(
        .init(phase: .idle, generation: 0, transport: .down, route: .sfu, cause: .initial)
    )
    /// Which remote peers are reachable right now, and the last change.
    /// Driven by the connection.
    public let presence = KeepTalkingStateSignal<KeepTalkingClientPresence>(
        .init(onlineNodeIDs: [], change: .reset)
    )
    /// Transport counters, sampled once a second while connected and
    /// published only when they changed. Driven by the connection.
    public let transportStats: KeepTalkingStateSignal<KeepTalkingRuntimeStats>
    /// Flat snapshot of every agent run, republished on each transition.
    /// Driven by the agent coordinator.
    public let agentRuns = KeepTalkingStateSignal<[KeepTalkingAgentRunSnapshot]>([])
    /// A context's joinable-call picture changed — someone started, ended,
    /// or was swept out of a call. Carries the context; re-read the set via
    /// `voiceCallPresence.participants(in:)`. Driven by the presence registry.
    public let voiceCallPresenceChanges = KeepTalkingSignal<UUID>()

    /// `initialTransportStats` is the transport's first sample, so
    /// `transportStats.current` is never a placeholder.
    init(initialTransportStats: KeepTalkingRuntimeStats) {
        transportStats = .init(initialTransportStats)
    }
}
