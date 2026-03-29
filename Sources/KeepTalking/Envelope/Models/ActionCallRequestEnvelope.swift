import Foundation

extension KeepTalkingActionCallRequest: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .actionCallRequest }

    public var participantNodeIDs: [UUID] {
        [callerNodeID, targetNodeID]
    }

    public var targetPeerNodeID: UUID? {
        targetNodeID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onActionCallRequest(
        _ handler: @escaping @Sendable (KeepTalkingActionCallRequest) -> Void
    ) {
        register(KeepTalkingActionCallRequest.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onActionCallRequest(
        _ handler: @escaping @Sendable (KeepTalkingActionCallRequest) async throws -> Void
    ) {
        register(KeepTalkingActionCallRequest.self, handler)
    }
}
