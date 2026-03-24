import FluentKit

struct CreateKeepTalkingContextAttachmentsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextAttachment.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(
                    KeepTalkingContext.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field(
                "parent_message",
                .uuid,
                .references(
                    KeepTalkingContextMessage.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field("sender", .json, .required)
            .field("blob_id", .string, .required)
            .field("filename", .string, .required)
            .field("mime_type", .string, .required)
            .field("byte_count", .int, .required)
            .field("created_at", .datetime, .required)
            .field("sort_index", .int, .required)
            .field("metadata", .json, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextAttachment.schema).delete()
    }
}
