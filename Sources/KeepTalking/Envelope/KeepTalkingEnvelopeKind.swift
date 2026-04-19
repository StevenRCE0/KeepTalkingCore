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
            case .p2pSignal, .p2pPresence:
                return .signaling
        }
    }

    public var preferredRoutes: [KeepTalkingTransportRoute] {
        switch self {
            case .p2pSignal, .p2pPresence:
                return [.sfu]
            case .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult,
                .encryptedAgentTurnContinuationResponse:
                return [.sfu]
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
                return [.p2p, .sfu]
        }
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
            case .p2pSignal, .p2pPresence:
                return .p2pSignaling
        }
    }
}
