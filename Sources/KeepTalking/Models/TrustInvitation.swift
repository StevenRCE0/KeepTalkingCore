import FluentKit
import Foundation

public enum KeepTalkingTrustInvitationDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

public enum KeepTalkingTrustInvitationStatus: String, Codable, Sendable {
    case pending
    case accepted
    case skipped
    case declined
    case established
    case failed
}

public final class KeepTalkingTrustInvitation: Model, @unchecked Sendable {
    public static let schema = "kt_trust_invitations"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "inviter_node_id")
    public var inviterNodeID: UUID

    @Field(key: "recipient_node_id")
    public var recipientNodeID: UUID

    @Field(key: "direction")
    public var direction: KeepTalkingTrustInvitationDirection

    @Field(key: "status")
    public var status: KeepTalkingTrustInvitationStatus

    @Field(key: "created_at")
    public var createdAt: Date

    @Field(key: "updated_at")
    public var updatedAt: Date

    @OptionalField(key: "resolved_at")
    public var resolvedAt: Date?

    @OptionalField(key: "last_error")
    public var lastError: String?

    public init() {}

    public init(
        id: UUID = UUID.v7(),
        context: KeepTalkingContext,
        inviterNodeID: UUID,
        recipientNodeID: UUID,
        direction: KeepTalkingTrustInvitationDirection,
        status: KeepTalkingTrustInvitationStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolvedAt: Date? = nil,
        lastError: String? = nil
    ) throws {
        self.id = id
        self.$context.id = try context.requireID()
        self.inviterNodeID = inviterNodeID
        self.recipientNodeID = recipientNodeID
        self.direction = direction
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.lastError = lastError
    }
}
