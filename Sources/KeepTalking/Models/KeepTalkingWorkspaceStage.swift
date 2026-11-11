import FluentKit
import Foundation

public final class KeepTalkingWorkspaceStageRow: Model, @unchecked Sendable {
    public static let schema = "kt_workspace_stages"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "schema")
    public var workspaceSchema: String

    @Field(key: "holder")
    public var holder: UUID

    @Field(key: "blob_id")
    public var blobID: String

    @Field(key: "mime_type")
    public var mimeType: String

    @Field(key: "updated_at")
    public var updatedAt: Date

    @OptionalField(key: "merged_blob_id")
    public var mergedBlobID: String?

    public init() {}

    init(contextID: UUID, stage: KeepTalkingWorkspaceStage) {
        self.id = UUID.v7()
        self.$context.id = contextID
        adopt(stage)
    }

    func adopt(_ stage: KeepTalkingWorkspaceStage) {
        workspaceSchema = stage.schema
        holder = stage.holder
        blobID = stage.blobID
        mimeType = stage.mimeType
        updatedAt = stage.updatedAt
    }

    var stage: KeepTalkingWorkspaceStage {
        KeepTalkingWorkspaceStage(
            schema: workspaceSchema, holder: holder, blobID: blobID, mimeType: mimeType, updatedAt: updatedAt)
    }

    var claimedBlobIDs: Set<String> { [blobID] }
}

struct CreateKeepTalkingWorkspaceStagesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspaceStageRow.schema)
            .id()
            .field("context", .uuid, .required, .references(KeepTalkingContext.schema, "id", onDelete: .cascade))
            .field("schema", .string, .required)
            .field("holder", .uuid, .required)
            .field("blob_id", .string, .required)
            .field("mime_type", .string, .required)
            .field("updated_at", .datetime, .required)
            .field("merged_blob_id", .string)
            .unique(on: "context", "schema", "holder")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspaceStageRow.schema).delete()
    }
}
