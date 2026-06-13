import Foundation

/// Why an in-flight action call is being cancelled. Travels on
/// `KeepTalkingActionCallCancel`. `.upstreamCancelled` is reserved for the
/// (currently single-hop) relay cascade — a parent run being cancelled.
public enum KeepTalkingActionCancelReason: String, Codable, Sendable {
    case userCancelled
    case runAborted
    case timeout
    case upstreamCancelled
}

/// Caller → provider request to cancel an in-flight action call.
///
/// Addressed by the ORIGINAL `KeepTalkingActionCallRequest.id` — that is already
/// the addressable handle on both sides, so no new run id is minted. The provider
/// handles it idempotently under its action-call queue:
/// - completed → no-op (the real result already won);
/// - in-flight → `task.cancel()`, letting the run finalize a CANCELLED result
///   (`isError = true`, `outputTransfers == nil`, so no partial OTB output is
///   ever assembled or materialized);
/// - not-yet-arrived → recorded in a bounded set and short-circuited when the
///   request lands (handles reorder / push-wake-first).
///
/// Authorized by matching `callerNodeID` to the stored request's caller, over a
/// trusted/decrypted envelope.
public struct KeepTalkingActionCallCancel: Codable, Sendable {
    /// The `KeepTalkingActionCallRequest.id` to cancel.
    public var requestID: UUID
    public var contextID: UUID
    public var callerNodeID: UUID
    public var targetNodeID: UUID
    public var reason: KeepTalkingActionCancelReason

    public init(
        requestID: UUID,
        contextID: UUID,
        callerNodeID: UUID,
        targetNodeID: UUID,
        reason: KeepTalkingActionCancelReason
    ) {
        self.requestID = requestID
        self.contextID = contextID
        self.callerNodeID = callerNodeID
        self.targetNodeID = targetNodeID
        self.reason = reason
    }
}

/// How the caller wants a provider-side ACT run's result returned.
///
/// - `.sync`  — the caller awaits the result (patient wait + liveness poll).
/// - `.detach` — the caller delegates and may disconnect; the provider runs to
///   completion and the result is delivered on reconnect/wake, reusing the
///   agent-turn continuation + push-wake precedent. For weak/intermittent
///   devices (a phone shouldn't stay online babysitting a run).
///
/// A detached provider-side ACT run is registered in the agent queue as
/// CANCEL-ONLY: it is **not resumable** and is **discarded if interrupted**
/// (never persisted for resume, unlike a suspended local agent turn).
public enum KeepTalkingActionExecutionMode: String, Codable, Sendable {
    case sync
    case detach
}
