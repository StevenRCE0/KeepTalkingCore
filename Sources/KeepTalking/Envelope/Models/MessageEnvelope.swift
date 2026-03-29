import Foundation

extension KeepTalkingContextMessage: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .message }

    public var participantNodeIDs: [UUID] {
        if case .node(let nodeID) = sender {
            return [nodeID]
        }
        return []
    }

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
}
