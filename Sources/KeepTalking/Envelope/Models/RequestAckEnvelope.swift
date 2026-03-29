import Foundation

extension KeepTalkingRequestAck: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .requestAck }

    public var participantNodeIDs: [UUID] {
        [callerNodeID, targetNodeID]
    }

    public var targetPeerNodeID: UUID? {
        callerNodeID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onRequestAck(
        _ handler: @escaping @Sendable (KeepTalkingRequestAck) -> Void
    ) {
        register(KeepTalkingRequestAck.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onRequestAck(
        _ handler: @escaping @Sendable (KeepTalkingRequestAck) async throws -> Void
    ) {
        register(KeepTalkingRequestAck.self, handler)
    }
}
