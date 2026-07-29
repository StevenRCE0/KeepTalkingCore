import Foundation

extension KeepTalkingP2PSignalPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .p2pSignal }
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
