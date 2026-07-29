import Foundation

public enum KeepTalkingEnvelopeKind: String, Codable, Sendable {
    case message
    case attachment
    case node
    case nodeStatus
    case encryptedNodeStatus
    case contextSync
    case actionCallRequest
    case requestAck
    case actionCallResult
    case encryptedActionCallRequest
    case encryptedRequestAck
    case encryptedActionCallResult
    case actionCatalogRequest
    case actionCatalogResult
    case encryptedActionCatalogRequest
    case encryptedActionCatalogResult
    case encryptedAgentTurnContinuationResponse
    case p2pSignal
    case p2pPresence
    case trustRequest
    case trustAccept
    case trustComplete
    case trustReject
    /// Broadcast: "I have started or joined the voice call in this
    /// context." Peers use it to populate their participant set and,
    /// when they're also in the call, to drive SDP handshake.
    case voiceCallStarted
    /// Broadcast: "I have left the voice call." Peers tear down ICE
    /// to this node and drop it from the participant set.
    case voiceCallEnded
    /// Directed: SDP exchange between two participants. Carried as an
    /// envelope so it rides the same encrypted, addressable path as
    /// the call presence pings — replaces the SFU `.p2pSignal` raw
    /// channel previously used for SDP.
    case voiceCallSignal
    /// One line of a call's federated transcript, authored by the speaking
    /// node. Rides the reliable context (chat) transport — NOT the lossy
    /// voice-UDP frame path — and is reconciled/backfilled as a tuned resource
    /// on `ContextSyncController`. Carries the session id so peers group it.
    case voiceCallTranscriptLine
}

extension KeepTalkingEnvelopeKind {
    var channel: KeepTalkingEnvelopeChannel {
        switch self {
            case .message,
                .attachment,
                .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .contextSync,
                .voiceCallTranscriptLine:
                return .chat
            case .actionCallRequest,
                .requestAck,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedRequestAck,
                .encryptedActionCallResult,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult,
                .encryptedAgentTurnContinuationResponse:
                return .actionCall
            case .p2pSignal,
                .p2pPresence,
                .trustRequest,
                .trustAccept,
                .trustComplete,
                .trustReject,
                .voiceCallStarted,
                .voiceCallEnded,
                .voiceCallSignal:
                return .signaling
        }
    }

    /// Whether this kind may travel over a direct P2P channel at all.
    ///
    /// This is a permission, not a route: a directed envelope uses the one
    /// channel to its target, while a broadcast-addressed envelope fans out
    /// over every ready direct channel with the SFU covering the remainder.
    /// `false` means SFU only, always.
    public var allowsDirect: Bool {
        switch self {
            // Signaling, presence, trust, voice — must reach every peer,
            // including ones no direct channel exists for yet.
            case .p2pSignal,
                .p2pPresence,
                .trustRequest,
                .trustAccept,
                .trustComplete,
                .trustReject,
                .voiceCallStarted,
                .voiceCallEnded,
                .voiceCallSignal:
                return false
            // Context reconciliation has no direct-path delivery ack, so a
            // stale P2P channel could accept and silently lose it.
            case .contextSync:
                return false
            // Service envelopes — catalog, node state, agent continuations.
            // Reliability matters more than latency; SFU is the safe path.
            case .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult,
                .encryptedAgentTurnContinuationResponse:
                return false
            // User-visible payload — chat and action calls. Latency wins.
            case .message,
                .attachment,
                .voiceCallTranscriptLine,
                .actionCallRequest,
                .requestAck,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedRequestAck,
                .encryptedActionCallResult:
                return true
        }
    }

    /// Whether this kind is safe to deliver to a peer more than once.
    ///
    /// Only these three are both broadcast-addressed and `allowsDirect`, so
    /// only these can physically fan out — and all three are idempotent at
    /// persistence (`filterNewMessages`, `filterNewAttachmentDTOs`, and the
    /// transcript line's find-by-id-and-compare). Every other `allowsDirect`
    /// kind carries a target and takes the directed path instead.
    ///
    /// Two kinds are known NOT to be redelivery-safe — `.voiceCallSignal`
    /// (re-applying an SDP can tear down a connected ICE agent) and
    /// `.trustRequest` (a second approval prompt mints a fresh ephemeral key
    /// and strands the handshake). Both are `allowsDirect == false`, so they
    /// never reach the fan-out path. Keep it that way.
    public var isFanOutEligible: Bool {
        switch self {
            case .message, .attachment, .voiceCallTranscriptLine:
                return true
            default:
                return false
        }
    }
}
