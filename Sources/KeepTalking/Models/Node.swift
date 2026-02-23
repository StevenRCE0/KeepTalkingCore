import FluentKit
import Foundation

public enum KeepTalkingRelationship: String, Codable, Sendable, Hashable {
    case owner, trusted, pending
}

public final class KeepTalkingNodeRelation: Model, @unchecked Sendable {
    public static let schema = "kt_node_relation"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "relationship")
    public var relationship: KeepTalkingRelationship

    @Parent(key: "from")
    public var from: KeepTalkingNode

    @Parent(key: "to")
    public var to: KeepTalkingNode

    @Field(key: "authorised_actions")
    public var authorisedActions: [KeepTalkingAction]

    public init() {}

    public init(
        id: UUID = UUID(),
        from: KeepTalkingNode,
        to: KeepTalkingNode,
        relationship: KeepTalkingRelationship,
        authorisedActions: [KeepTalkingAction] = []
    ) {
        self.id = id
        self.$from.id = from.id!
        self.$to.id = to.id!
        self.relationship = relationship
        self.authorisedActions = authorisedActions
    }
}

public final class KeepTalkingNode: Model, @unchecked Sendable {
    public static let schema = "kt_nodes"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "last_seen_at")
    public var lastSeenAt: Date

    public var actions: [KeepTalkingAction] = []

    @Siblings(through: KeepTalkingNodeRelation.self, from: \.$from, to: \.$to)
    public var nodeRelations: [KeepTalkingNode]

    public init() {}

    public init(
        id: UUID = UUID(),
        lastSeenAt: Date = Date(),
        actions: [KeepTalkingAction] = [],
    ) {
        self.id = id
        self.lastSeenAt = lastSeenAt
        self.actions = actions
    }
}
