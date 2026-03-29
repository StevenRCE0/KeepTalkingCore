import Foundation

extension KeepTalkingActionCatalogRequest: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .actionCatalogRequest }

    public var participantNodeIDs: [UUID] {
        [callerNodeID, targetNodeID]
    }

    public var targetPeerNodeID: UUID? {
        targetNodeID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onActionCatalogRequest(
        _ handler: @escaping @Sendable (KeepTalkingActionCatalogRequest) -> Void
    ) {
        register(KeepTalkingActionCatalogRequest.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onActionCatalogRequest(
        _ handler: @escaping @Sendable (KeepTalkingActionCatalogRequest) async throws -> Void
    ) {
        register(KeepTalkingActionCatalogRequest.self, handler)
    }
}
