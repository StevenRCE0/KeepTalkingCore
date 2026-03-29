import Foundation

extension KeepTalkingActionCatalogResult: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .actionCatalogResult }

    public var participantNodeIDs: [UUID] {
        [callerNodeID, targetNodeID]
    }

    public var targetPeerNodeID: UUID? {
        callerNodeID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onActionCatalogResult(
        _ handler: @escaping @Sendable (KeepTalkingActionCatalogResult) -> Void
    ) {
        register(KeepTalkingActionCatalogResult.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onActionCatalogResult(
        _ handler: @escaping @Sendable (KeepTalkingActionCatalogResult) async throws -> Void
    ) {
        register(KeepTalkingActionCatalogResult.self, handler)
    }
}
