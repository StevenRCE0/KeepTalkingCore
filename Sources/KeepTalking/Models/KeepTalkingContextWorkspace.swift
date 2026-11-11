import FluentKit
import Foundation

public final class KeepTalkingContextWorkspace: Model, @unchecked Sendable {
    public static let schema = "kt_context_workspaces"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "schema")
    public var workspaceSchema: String

    @Field(key: "title")
    public var title: String

    @Field(key: "kind")
    public var kind: String

    @Field(key: "provider")
    public var provider: String

    @Field(key: "added_by")
    public var addedBy: UUID

    @Field(key: "updated_at")
    public var updatedAt: Date

    @Field(key: "is_removed")
    public var isRemoved: Bool

    public init() {}

    init(contextID: UUID, record: KeepTalkingContextWorkspaceRecord) {
        self.id = UUID.v7()
        self.$context.id = contextID
        adopt(record)
    }

    func adopt(_ record: KeepTalkingContextWorkspaceRecord) {
        workspaceSchema = record.schema
        title = record.title
        kind = record.kind.rawValue
        provider = record.provider
        addedBy = record.addedBy
        updatedAt = record.updatedAt
        isRemoved = record.isRemoved
    }

    var record: KeepTalkingContextWorkspaceRecord {
        KeepTalkingContextWorkspaceRecord(
            schema: workspaceSchema, title: title, kind: KeepTalkingWorkspaceKind(rawValue: kind) ?? .custom,
            provider: provider, addedBy: addedBy, updatedAt: updatedAt, isRemoved: isRemoved)
    }
}

struct CreateKeepTalkingContextWorkspacesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextWorkspace.schema)
            .id()
            .field(
                "context", .uuid, .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("schema", .string, .required)
            .field("title", .string, .required)
            .field("kind", .string, .required)
            .field("provider", .string, .required)
            .field("added_by", .uuid, .required)
            .field("updated_at", .datetime, .required)
            .field("is_removed", .bool, .required)
            .unique(on: "context", "schema")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextWorkspace.schema).delete()
    }
}
