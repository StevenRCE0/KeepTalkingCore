import Foundation

extension KeepTalkingContext: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .context }

    public var participantNodeIDs: [UUID] {
        var nodeIDs: [UUID] = []
        for message in messages {
            if case .node(let nodeID) = message.sender {
                nodeIDs.append(nodeID)
            }
        }
        for attachment in attachments {
            if case .node(let nodeID) = attachment.sender {
                nodeIDs.append(nodeID)
            }
        }
        return nodeIDs
    }

    public var transportContextID: UUID? {
        id
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onContext(
        _ handler: @escaping @Sendable (KeepTalkingContext) -> Void
    ) {
        register(KeepTalkingContext.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onContext(
        _ handler: @escaping @Sendable (KeepTalkingContext) async throws -> Void
    ) {
        register(KeepTalkingContext.self, handler)
    }
}
