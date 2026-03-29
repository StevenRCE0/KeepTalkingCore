import Foundation

extension KeepTalkingNodeStatus: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .nodeStatus }

    public var participantNodeIDs: [UUID] {
        node.id.map { [$0] } ?? []
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onNodeStatus(
        _ handler: @escaping @Sendable (KeepTalkingNodeStatus) -> Void
    ) {
        register(KeepTalkingNodeStatus.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onNodeStatus(
        _ handler: @escaping @Sendable (KeepTalkingNodeStatus) async throws -> Void
    ) {
        register(KeepTalkingNodeStatus.self, handler)
    }
}
