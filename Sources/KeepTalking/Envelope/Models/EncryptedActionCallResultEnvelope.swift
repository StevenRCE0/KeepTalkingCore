import Foundation

public struct KeepTalkingEncryptedActionCallResultEnvelope: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .encryptedActionCallResult }

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

extension KeepTalkingEnvelopeHandlers {
    public mutating func onEncryptedActionCallResult(
        _ handler: @escaping @Sendable (KeepTalkingAsymmetricCipherEnvelope) -> Void
    ) {
        register(KeepTalkingEncryptedActionCallResultEnvelope.self) { envelope in
            handler(envelope.payload)
        }
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onEncryptedActionCallResult(
        _ handler: @escaping @Sendable (KeepTalkingAsymmetricCipherEnvelope) async throws -> Void
    ) {
        register(KeepTalkingEncryptedActionCallResultEnvelope.self) { envelope in
            try await handler(envelope.payload)
        }
    }
}
