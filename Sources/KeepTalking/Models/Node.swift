import FluentKit
import Foundation

public final class KeepTalkingNode: Model, @unchecked Sendable {
    public static let schema = "kt_nodes"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "last_seen_at")
    public var lastSeenAt: Date

    @Children(for: \.$node)
    public var actions: [KeepTalkingAction]

    @Siblings(through: KeepTalkingNodeRelation.self, from: \.$from, to: \.$to)
    public var nodeRelations: [KeepTalkingNode]

    @Children(for: \.$from)
    public var outgoingNodeRelations: [KeepTalkingNodeRelation]

    public init() {}

    public init(
        id: UUID = UUID(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.lastSeenAt = lastSeenAt
    }
}

extension KeepTalkingNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case lastSeenAt
    }

    public convenience init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let lastSeenAt =
            try container.decodeIfPresent(
                Date.self,
                forKey: .lastSeenAt
            ) ?? Date()
        self.init(
            id: id,
            lastSeenAt: lastSeenAt
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
    }
}
