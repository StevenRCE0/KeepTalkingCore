import Foundation

extension KeepTalkingActionCallResult: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .actionCallResult }

    public var participantNodeIDs: [UUID] {
        [callerNodeID, targetNodeID]
    }

    public var targetPeerNodeID: UUID? {
        callerNodeID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onActionCallResult(
        _ handler: @escaping @Sendable (KeepTalkingActionCallResult) -> Void
    ) {
        register(KeepTalkingActionCallResult.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onActionCallResult(
        _ handler: @escaping @Sendable (KeepTalkingActionCallResult) async throws -> Void
    ) {
        register(KeepTalkingActionCallResult.self, handler)
    }
}
