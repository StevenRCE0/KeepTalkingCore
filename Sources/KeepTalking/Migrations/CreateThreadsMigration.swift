import FluentKit

struct CreateKeepTalkingThreadsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingThread.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field(
                "start_message",
                .uuid,
                .references(KeepTalkingContextMessage.schema, "id", onDelete: .setNull)
            )
            .field(
                "end_message",
                .uuid,
                .references(KeepTalkingContextMessage.schema, "id", onDelete: .setNull)
            )
            .field("state", .string, .required)
            .field("summary", .string)
            .field("chitter_chatter", .json, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingThread.schema).delete()
    }
}
