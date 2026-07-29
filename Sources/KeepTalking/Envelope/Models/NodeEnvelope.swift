import Foundation

extension KeepTalkingNode: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .node }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onNode(
        _ handler: @escaping @Sendable (KeepTalkingNode) -> Void
    ) {
        register(KeepTalkingNode.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onNode(
        _ handler: @escaping @Sendable (KeepTalkingNode) async throws -> Void
    ) {
        register(KeepTalkingNode.self, handler)
    }
}
