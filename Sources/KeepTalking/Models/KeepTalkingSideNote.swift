import FluentKit
import Foundation

public final class KeepTalkingSideNote: Model, @unchecked Sendable {
    public static let schema = "kt_side_notes"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "key")
    public var key: String

    @Field(key: "value")
    public var value: String

    @Field(key: "is_archived")
    public var isArchived: Bool

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        key: String,
        value: String,
        isArchived: Bool = false
    ) {
        self.id = id
        self.$context.id = contextID
        self.key = key
        self.value = value
        self.isArchived = isArchived
    }
}

// MARK: - DTO

public struct KeepTalkingSideNoteDTO: Codable, Sendable {
    public let id: UUID
    public let contextID: UUID
    public let key: String
    public let value: String
    public let isArchived: Bool
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        contextID: UUID,
        key: String,
        value: String,
        isArchived: Bool,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.contextID = contextID
        self.key = key
        self.value = value
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init?(_ model: KeepTalkingSideNote) {
        guard let id = model.id else { return nil }
        self.id = id
        self.contextID = model.$context.id
        self.key = model.key
        self.value = model.value
        self.isArchived = model.isArchived
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
    }
}
