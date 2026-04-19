import Foundation

public struct KeepTalkingEncryptedAgentTurnContinuationResponseEnvelope: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .encryptedAgentTurnContinuationResponse }

    public let payload: KeepTalkingAsymmetricCipherEnvelope

    public init(_ payload: KeepTalkingAsymmetricCipherEnvelope) {
        self.payload = payload
    }

    public var participantNodeIDs: [UUID] {
        [payload.senderNodeID, payload.recipientNodeID]
    }

    public var targetPeerNodeID: UUID? {
        payload.recipientNodeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        payload = try container.decode(KeepTalkingAsymmetricCipherEnvelope.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onEncryptedAgentTurnContinuationResponse(
        _ handler: @escaping @Sendable (KeepTalkingAsymmetricCipherEnvelope) async throws -> Void
    ) {
        register(KeepTalkingEncryptedAgentTurnContinuationResponseEnvelope.self) { envelope in
            try await handler(envelope.payload)
        }
    }
}
