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
    case p2pPresence
    case trustRequest
    case trustAccept
    case trustComplete
    case trustReject
    /// Broadcast: "I have started or joined the voice call in this
    /// context." Peers use it to populate their participant set.
    case voiceCallStarted
    /// Broadcast: "I have left the voice call."
    case voiceCallEnded
    /// One line of a call's federated transcript, authored by the speaking
    /// node. Rides the reliable context transport — NOT the lossy voice
    /// datagrams — and is reconciled/backfilled as a tuned resource on
    /// `ContextSyncController`. Carries the session id so peers group it.
    case voiceCallTranscriptLine
    /// Blob negotiation: who wants a blob, who has it, and the pull that
    /// opens its stream. The bytes never ride an envelope.
    case blobTransfer

    /// Trust handshake kinds, handled before the sender is trusted.
    var isTrustHandshake: Bool {
        switch self {
            case .trustRequest, .trustAccept, .trustComplete, .trustReject:
                return true
            default:
                return false
        }
    }
}
