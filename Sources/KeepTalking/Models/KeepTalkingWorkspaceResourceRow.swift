import FluentKit
import Foundation

public struct KeepTalkingWorkspaceResourceRecord: Codable, Sendable, Equatable, Identifiable {
    public var schema: String
    public var resourceID: UUID
    public var blobID: String
    public var mimeType: String
    public var filename: String
    public var addedBy: UUID
    public var updatedAt = Date()
    public var isRemoved = false

    public var id: UUID { resourceID }
}

public final class KeepTalkingWorkspaceResourceRow: Model, @unchecked Sendable {
    public static let schema = "kt_workspace_resources"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "schema")
    public var workspaceSchema: String

    @Field(key: "resource_id")
    public var resourceID: UUID

    @Field(key: "blob_id")
    public var blobID: String

    @Field(key: "mime_type")
    public var mimeType: String

    @Field(key: "filename")
    public var filename: String

    @Field(key: "added_by")
    public var addedBy: UUID

    @Field(key: "updated_at")
    public var updatedAt: Date

    @Field(key: "is_removed")
    public var isRemoved: Bool

    public init() {}

    init(contextID: UUID, record: KeepTalkingWorkspaceResourceRecord) {
        self.id = UUID.v7()
        self.$context.id = contextID
        adopt(record)
    }

    func adopt(_ record: KeepTalkingWorkspaceResourceRecord) {
        workspaceSchema = record.schema
        resourceID = record.resourceID
        blobID = record.blobID
        mimeType = record.mimeType
        filename = record.filename
        addedBy = record.addedBy
        updatedAt = record.updatedAt
        isRemoved = record.isRemoved
    }

    var record: KeepTalkingWorkspaceResourceRecord {
        KeepTalkingWorkspaceResourceRecord(
            schema: workspaceSchema, resourceID: resourceID, blobID: blobID, mimeType: mimeType, filename: filename,
            addedBy: addedBy, updatedAt: updatedAt, isRemoved: isRemoved)
    }

    var claimedBlobIDs: Set<String> { isRemoved ? [] : [blobID] }
}

struct CreateKeepTalkingWorkspaceResourcesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspaceResourceRow.schema)
            .id()
            .field("context", .uuid, .required, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .field("schema", .string, .required)
            .field("resource_id", .uuid, .required)
            .field("blob_id", .string, .required)
            .field("mime_type", .string, .required)
            .field("filename", .string, .required)
            .field("added_by", .uuid, .required)
            .field("updated_at", .datetime, .required)
            .field("is_removed", .bool, .required)
            .unique(on: "context", "schema", "resource_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspaceResourceRow.schema).delete()
    }
}
