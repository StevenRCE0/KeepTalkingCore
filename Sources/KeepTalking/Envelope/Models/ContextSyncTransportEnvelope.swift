import Foundation

extension KeepTalkingContextSyncEnvelope: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .contextSync }

    public var transportContextID: UUID? {
        contextID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onContextSync(
        _ handler: @escaping @Sendable (KeepTalkingContextSyncEnvelope) -> Void
    ) {
        register(KeepTalkingContextSyncEnvelope.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onContextSync(
        _ handler: @escaping @Sendable (KeepTalkingContextSyncEnvelope) async throws -> Void
    ) {
        register(KeepTalkingContextSyncEnvelope.self, handler)
    }
}
