import Foundation

extension KeepTalkingContextMessage: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .message }

    public var transportContextID: UUID? {
        $context.id
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onMessage(
        _ handler: @escaping @Sendable (KeepTalkingContextMessage) -> Void
    ) {
        register(KeepTalkingContextMessage.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onMessage(
        _ handler: @escaping @Sendable (KeepTalkingContextMessage) async throws -> Void
    ) {
        register(KeepTalkingContextMessage.self, handler)
    }

    /// Variant whose handler reports whether the message was newly applied.
    public mutating func onMessage(
        _ handler: @escaping @Sendable (KeepTalkingContextMessage) async throws -> Bool
    ) {
        registerReportingApplied(KeepTalkingContextMessage.self, handler)
    }
}
