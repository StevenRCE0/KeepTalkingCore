import Foundation

public enum KeepTalkingEnvelopeKind: String, Codable, Sendable {
    case message
    case attachment
    case context
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
}

extension KeepTalkingEnvelopeKind {
    var channel: KeepTalkingEnvelopeChannel {
        switch self {
            case .message,
                .attachment,
                .context,
                .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .contextSync:
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

    public var routingStrategy: KeepTalkingRoutingStrategy {
        switch self {
            // Signaling, presence, trust, voice — must fan out via SFU.
            case .p2pSignal,
                .p2pPresence,
                .trustRequest,
                .trustAccept,
                .trustComplete,
                .trustReject,
                .voiceCallStarted,
                .voiceCallEnded,
                .voiceCallSignal:
                return .sfuOnly
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
                return .sfuOnly
            // User-visible payload — chat, sync, action calls. Latency wins.
            case .contextSync,
                .message,
                .attachment,
                .context,
                .actionCallRequest,
                .requestAck,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedRequestAck,
                .encryptedActionCallResult:
                return .preferDirect
        }
    }

    /// Legacy shim — migrate callers to `routingStrategy` and remove.
    public var preferredRoutes: [KeepTalkingTransportRoute] {
        routingStrategy.orderedRoutes
    }

    public var envelopeType: KeepTalkingEnvelopeType {
        switch self {
            case .message, .attachment, .context:
                return .chat
            case .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .contextSync,
                .actionCallRequest,
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
                return .service
            case .p2pSignal,
                .p2pPresence,
                .trustRequest,
                .trustAccept,
                .trustComplete,
                .trustReject,
                .voiceCallStarted,
                .voiceCallEnded,
                .voiceCallSignal:
                return .p2pSignaling
        }
    }
}
