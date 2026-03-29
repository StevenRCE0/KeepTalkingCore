import Foundation

public struct KeepTalkingSequencedEnvelope: Codable, Sendable {
    public let senderNode: UUID
    public let sequence: UInt64
    public let envelope: any KeepTalkingEnvelope

    enum CodingKeys: String, CodingKey {
        case senderNode
        case sequence
        case envelope
    }

    public init(
        senderNode: UUID,
        sequence: UInt64,
        envelope: any KeepTalkingEnvelope
    ) {
        self.senderNode = senderNode
        self.sequence = sequence
        self.envelope = envelope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        senderNode = try container.decode(UUID.self, forKey: .senderNode)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        envelope = try container.decode(
            KeepTalkingEnvelopePacket.self,
            forKey: .envelope
        ).envelope
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(senderNode, forKey: .senderNode)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(
            KeepTalkingEnvelopePacket(envelope),
            forKey: .envelope
        )
    }
}
