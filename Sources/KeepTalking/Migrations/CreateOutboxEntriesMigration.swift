import FluentKit

struct CreateKeepTalkingOutboxEntriesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingOutboxEntry.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field(
                "context_message",
                .uuid,
                .required,
                .references(KeepTalkingContextMessage.schema, "id", onDelete: .cascade)
            )
            .field("created_at", .datetime, .required)
            .field("attempts", .int, .required)
            .field("last_error", .string)
            .unique(on: "context_message")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingOutboxEntry.schema).delete()
    }
}
