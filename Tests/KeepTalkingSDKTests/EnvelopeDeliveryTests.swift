import Foundation
import Testing

@testable import KeepTalkingSDK

/// Which lane each kind rides, which may be redelivered, and how blob
/// negotiation travels.
struct EnvelopeDeliveryTests {
    @Test("Trust requests are the one kind never delivered twice")
    func idempotence() {
        #expect(!KeepTalkingEnvelopeKind.trustRequest.delivery.isIdempotent)
        for kind in [KeepTalkingEnvelopeKind.message, .attachment, .contextSync, .p2pPresence, .blobTransfer] {
            #expect(kind.delivery.isIdempotent)
        }
    }

    @Test("Presence, trust, call state and blob negotiation ride control; sync and node state ride bulk")
    func lanes() {
        for kind in [KeepTalkingEnvelopeKind.p2pPresence, .trustRequest, .voiceCallStarted, .blobTransfer, .requestAck]
        {
            #expect(kind.delivery.lane == .control)
        }
        for kind in [KeepTalkingEnvelopeKind.message, .attachment, .actionCallRequest, .voiceCallTranscriptLine] {
            #expect(kind.delivery.lane == .interactive)
        }
        for kind in [KeepTalkingEnvelopeKind.contextSync, .nodeStatus, .encryptedNodeStatus, .node] {
            #expect(kind.delivery.lane == .bulk)
        }
    }

    @Test("Only the four trust kinds are handshake kinds")
    func trustHandshake() {
        let trustKinds: [KeepTalkingEnvelopeKind] = [.trustRequest, .trustAccept, .trustComplete, .trustReject]
        let allHandshake = trustKinds.allSatisfy { $0.isTrustHandshake }
        #expect(allHandshake)
        #expect(!KeepTalkingEnvelopeKind.message.isTrustHandshake)
    }

    @Test("A blob negotiation survives the envelope packet and names its recipient")
    func blobTransferPacket() throws {
        let holder = UUID()
        let envelope = KeepTalkingBlobTransferEnvelope(
            context: UUID(),
            sender: UUID(),
            recipient: holder,
            step: .pull(.oneTimeBlob(transferID: UUID()), offset: 3)
        )
        let decoded = try JSONDecoder().decode(
            KeepTalkingEnvelopePacket.self,
            from: JSONEncoder().encode(KeepTalkingEnvelopePacket(envelope))
        ).envelope
        let roundTripped = try #require(decoded as? KeepTalkingBlobTransferEnvelope)
        #expect(roundTripped == envelope)
        #expect(roundTripped.targetPeerNodeID == holder)
        #expect(roundTripped.transportContextID == envelope.context)

        let wanted = KeepTalkingBlobTransferEnvelope(
            context: UUID(), sender: UUID(), recipient: nil, step: .wanted([.attachment(blobID: "ab")])
        )
        #expect(wanted.targetPeerNodeID == nil)
    }
}

/// Node-status snapshots ride the bulk lane, a stream each, so they can
/// arrive out of order.
struct NodeStatusOrderingTests {
    private func status(node: UUID, context: UUID, at ms: UInt64) -> KeepTalkingNodeStatus {
        KeepTalkingNodeStatus(node: KeepTalkingNode(id: node), contextID: context, nodeRelations: [], issuedAtMs: ms)
    }

    @Test("An older snapshot arriving after a newer one is dropped; other senders and contexts are separate")
    func watermarks() {
        let marks = KeepTalkingNodeStatusWatermarks()
        let node = UUID()
        let context = UUID()
        #expect(marks.admit(status(node: node, context: context, at: 20)))
        #expect(!marks.admit(status(node: node, context: context, at: 10)))
        #expect(!marks.admit(status(node: node, context: context, at: 20)))
        #expect(marks.admit(status(node: node, context: context, at: 21)))
        #expect(marks.admit(status(node: UUID(), context: context, at: 5)))
        #expect(marks.admit(status(node: node, context: UUID(), at: 5)))
    }

    @Test("Issue times strictly increase even when the clock steps back")
    func issueTimes() {
        let later = KeepTalkingNodeStatus.nextIssuedAtMs(now: Date(timeIntervalSince1970: 2_000_000_000))
        let earlier = KeepTalkingNodeStatus.nextIssuedAtMs(now: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(earlier > later)
    }
}
