import Foundation

/// The KeepTalking heartbeat: "this node is in the context". Members publish
/// it to the room periodically; it's what tells SFU-only peers we're here.
public struct KeepTalkingP2PPresencePayload: Codable, Sendable {
    public let node: UUID

    public init(node: UUID) {
        self.node = node
    }
}

extension KeepTalkingP2PPresencePayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .p2pPresence }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onP2PPresence(
        _ handler: @escaping @Sendable (KeepTalkingP2PPresencePayload) -> Void
    ) {
        register(KeepTalkingP2PPresencePayload.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onP2PPresence(
        _ handler: @escaping @Sendable (KeepTalkingP2PPresencePayload) async throws -> Void
    ) {
        register(KeepTalkingP2PPresencePayload.self, handler)
    }
}
