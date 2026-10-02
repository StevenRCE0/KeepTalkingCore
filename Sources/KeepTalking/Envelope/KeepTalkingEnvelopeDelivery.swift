import Foundation

/// How a transport carries an envelope kind, whatever the route.
///
/// Each lane is its own ordered QUIC stream on every route, so traffic on one
/// lane never waits behind another: a context-sync page can't hold up a chat
/// message, and neither holds up an ack or a voice heartbeat.
public struct KeepTalkingEnvelopeDelivery: Sendable, Hashable {
    public enum Lane: UInt8, Sendable, CaseIterable {
        /// Small and urgent: presence, trust, voice call state, acks, blob
        /// negotiation.
        case control = 0x01
        /// What a person or an agent waits on: messages, attachment records,
        /// transcript lines, action calls and their results.
        case interactive = 0x02
        /// Background bulk: context sync and node state. Each envelope rides
        /// its own stream, so a large page never blocks another.
        case bulk = 0x03
    }

    public let lane: Lane
    /// Safe to deliver more than once — after a resync, or over a second
    /// route. Kinds that aren't must be sent exactly once.
    public let isIdempotent: Bool
}

extension KeepTalkingEnvelopeKind {
    public var delivery: KeepTalkingEnvelopeDelivery {
        switch self {
            case .p2pPresence,
                .trustAccept,
                .trustComplete,
                .trustReject,
                .voiceCallStarted,
                .voiceCallEnded,
                .requestAck,
                .encryptedRequestAck,
                .blobTransfer:
                return .init(lane: .control, isIdempotent: true)
            case .trustRequest:
                // A second trust request mints a fresh ephemeral key and
                // strands the handshake.
                return .init(lane: .control, isIdempotent: false)
            case .message,
                .attachment,
                .voiceCallTranscriptLine,
                .actionCallRequest,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedActionCallResult,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult,
                .encryptedAgentTurnContinuationResponse:
                return .init(lane: .interactive, isIdempotent: true)
            case .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .contextSync:
                return .init(lane: .bulk, isIdempotent: true)
        }
    }
}
