import Foundation
import Testing

@testable import KeepTalkingSDK

struct PacketTransportCryptoTests {
    @Test("message envelopes use encrypted transport payloads")
    func messageEnvelopeRoundTripsThroughTransportCrypto() throws {
        let contextID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let senderNodeID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!
        let secret = Data("transport-secret-32-bytes-length!!".utf8)
        let envelope = KeepTalkingP2PEnvelope.message(
            KeepTalkingContextMessage(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                context: KeepTalkingContext(id: contextID),
                sender: .node(node: senderNodeID),
                content: "hello cryptor"
            )
        )

        let payload = try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: senderNodeID,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )

        let plaintext = try JSONEncoder().encode(envelope)
        #expect(payload != plaintext)

        let decoded = try KeepTalkingPacketTransportCrypto
            .inboundEnvelope(
                from: payload,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )

        let messageEnvelope = try #require(decoded)
        guard case .message(let message) = messageEnvelope else {
            Issue.record("Expected decrypted envelope to be a message")
            return
        }

        #expect(message.content == "hello cryptor")
        #expect(message.$context.id == contextID)
    }

    @Test("non-message envelopes stay plaintext")
    func nonMessageEnvelopeBypassesTransportCrypto() throws {
        let nodeID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let envelope = KeepTalkingP2PEnvelope.node(KeepTalkingNode(id: nodeID))

        let payload = try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: nodeID,
                contextSecretProvider: nil
            )

        let plaintext = try JSONEncoder().encode(envelope)
        #expect(payload == plaintext)

        let decoded = try KeepTalkingPacketTransportCrypto
            .inboundEnvelope(
                from: payload,
                contextSecretProvider: nil
            )
        let nodeEnvelope = try #require(decoded)
        guard case .node(let decodedNode) = nodeEnvelope else {
            Issue.record("Expected plaintext envelope to remain a node payload")
            return
        }
        #expect(decodedNode.id == nodeID)
    }

    @Test("context envelopes use encrypted transport payloads")
    func contextEnvelopeRoundTripsThroughTransportCrypto() throws {
        let contextID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let senderNodeID = UUID(
            uuidString: "66666666-6666-6666-6666-666666666666"
        )!
        let secret = Data("transport-secret-32-bytes-length!!".utf8)
        let message = KeepTalkingContextMessage(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            context: KeepTalkingContext(id: contextID),
            sender: .node(node: senderNodeID),
            content: "embedded context message"
        )
        let envelope = KeepTalkingP2PEnvelope.context(
            KeepTalkingContext(
                id: contextID,
                messages: [message]
            )
        )

        let payload = try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: senderNodeID,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )

        let plaintext = try JSONEncoder().encode(envelope)
        #expect(payload != plaintext)

        let decoded = try KeepTalkingPacketTransportCrypto
            .inboundEnvelope(
                from: payload,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )

        let contextEnvelope = try #require(decoded)
        guard case .context(let context) = contextEnvelope else {
            Issue.record("Expected decrypted envelope to be a context payload")
            return
        }

        #expect(context.id == contextID)
        #expect(context.messages.count == 1)
        #expect(context.messages.first?.content == "embedded context message")
    }

    @Test("context sync envelopes use encrypted transport payloads")
    func contextSyncEnvelopeRoundTripsThroughTransportCrypto() throws {
        let contextID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let requester = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let recipient = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let secret = Data("transport-secret-32-bytes-length!!".utf8)
        let envelope = KeepTalkingP2PEnvelope.contextSync(
            .summaryRequest(
                KeepTalkingContextSyncSummaryRequest(
                    context: contextID,
                    requester: requester,
                    recipient: recipient
                )
            )
        )

        let payload = try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: requester,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )

        let plaintext = try JSONEncoder().encode(envelope)
        #expect(payload != plaintext)

        let decoded = try KeepTalkingPacketTransportCrypto
            .inboundEnvelope(
                from: payload,
                contextSecretProvider: { requestedContextID in
                    requestedContextID == contextID ? secret : nil
                }
            )
        let syncEnvelope = try #require(decoded)
        guard case .contextSync(let contextSyncEnvelope) = syncEnvelope else {
            Issue.record("Expected decrypted envelope to be a context-sync payload")
            return
        }
        guard case .summaryRequest(let request) = contextSyncEnvelope else {
            Issue.record("Expected decrypted context-sync envelope to be a summary request")
            return
        }
        #expect(request.context == contextID)
        #expect(request.requester == requester)
        #expect(request.recipient == recipient)
    }
}
