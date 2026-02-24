import FluentKit
import Foundation

public enum KeepTalkingRelationship: String, Codable, Sendable, Hashable, Equatable {
    case owner, trusted, pending
}



public final class KeepTalkingNode: Model, @unchecked Sendable {
    public static let schema = "kt_nodes"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "last_seen_at")
    public var lastSeenAt: Date

    @OptionalField(key: "discovered_during_logon")
    public var discoveredDuringLogon: UUID?

    @Children(for: \.$node)
    public var actions: [KeepTalkingAction]

    @Siblings(through: KeepTalkingNodeRelation.self, from: \.$from, to: \.$to)
    public var nodeRelations: [KeepTalkingNode]

    public init() {}

    public init(
        id: UUID = UUID(),
        lastSeenAt: Date = Date(),
        discoveredDuringLogon: UUID? = nil,
        actions: [KeepTalkingAction] = []
    ) {
        self.id = id
        self.lastSeenAt = lastSeenAt
        self.discoveredDuringLogon = discoveredDuringLogon
    }
}
