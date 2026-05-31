import Foundation

public protocol KeepTalkingEnvelope: Codable, Sendable {
    static var kind: KeepTalkingEnvelopeKind { get }

    var participantNodeIDs: [UUID] { get }
    var targetPeerNodeID: UUID? { get }
    var transportContextID: UUID? { get }
}

extension KeepTalkingEnvelope {
    public var kind: KeepTalkingEnvelopeKind { Self.kind }

    public var routingPolicy: KeepTalkingRoutingPolicy {
        kind.routingPolicy
    }

    /// Legacy shim.
    public var preferredRoutes: [KeepTalkingTransportRoute] {
        routingPolicy.orderedRoutes
    }

    public var envelopeType: KeepTalkingEnvelopeType {
        kind.envelopeType
    }

    public var channel: KeepTalkingEnvelopeChannel {
        kind.channel
    }

    public var participantNodeIDs: [UUID] { [] }
    public var targetPeerNodeID: UUID? { nil }
    public var transportContextID: UUID? { nil }
}
