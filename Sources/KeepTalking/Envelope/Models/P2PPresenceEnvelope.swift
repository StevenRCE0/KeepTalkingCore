import Foundation

extension KeepTalkingP2PPresencePayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .p2pPresence }

    public var participantNodeIDs: [UUID] {
        [node]
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onP2PPresence(
        _ handler: @escaping @Sendable (KeepTalkingP2PPresencePayload) -> Void
    ) {
        register(KeepTalkingP2PPresencePayload.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onP2PPresence(
        _ handler: @escaping @Sendable (KeepTalkingP2PPresencePayload) async throws -> Void
    ) {
        register(KeepTalkingP2PPresencePayload.self, handler)
    }
}

extension KeepTalkingEnvelopeHandlers {
    mutating func registerP2PPresenceHandler(
        for transport: KeepTalkingContextTransport
    ) {
        onP2PPresence { presence in
            transport.consumeP2PPresence(presence)
        }
    }
}
