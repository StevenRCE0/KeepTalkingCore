import Foundation

public protocol KeepTalkingEnvelope: Codable, Sendable {
    static var kind: KeepTalkingEnvelopeKind { get }

    var targetPeerNodeID: UUID? { get }
    var transportContextID: UUID? { get }
}

extension KeepTalkingEnvelope {
    public var kind: KeepTalkingEnvelopeKind { Self.kind }

    public var targetPeerNodeID: UUID? { nil }
    public var transportContextID: UUID? { nil }
}
