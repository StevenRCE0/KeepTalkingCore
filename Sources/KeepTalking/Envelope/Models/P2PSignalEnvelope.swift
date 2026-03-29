import Foundation

extension KeepTalkingP2PSignalPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .p2pSignal }

    public var participantNodeIDs: [UUID] {
        [from]
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onP2PSignal(
        _ handler: @escaping @Sendable (KeepTalkingP2PSignalPayload) -> Void
    ) {
        register(KeepTalkingP2PSignalPayload.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onP2PSignal(
        _ handler: @escaping @Sendable (KeepTalkingP2PSignalPayload) async throws -> Void
    ) {
        register(KeepTalkingP2PSignalPayload.self, handler)
    }
}

extension KeepTalkingEnvelopeHandlers {
    mutating func registerP2PSignalHandler(
        for transport: KeepTalkingContextTransport
    ) {
        onP2PSignal { signal in
            transport.consumeP2PSignal(signal)
        }
    }
}
