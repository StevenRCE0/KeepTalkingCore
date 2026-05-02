import FluentKit
import Foundation

public final class KeepTalkingNodeIdentityKey: Model, @unchecked Sendable {
    public static let schema = "kt_node_identity_keys"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "relation")
    public var relation: KeepTalkingNodeRelation

    @Field(key: "public_key")
    public var publicKey: String

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(),
        relation: KeepTalkingNodeRelation,
        publicKey: String
    ) throws {
        self.id = id
        self.$relation.id = try relation.requireID()
        self.publicKey = publicKey
    }
}
