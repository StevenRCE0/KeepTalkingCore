import FluentKit

struct CreateSideNotesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingSideNote.schema)
            .id()
            .field(
                "context",
                .uuid,
                .required,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("key", .string, .required)
            .field("value", .string, .required)
            .field("is_archived", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "context", "key")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingSideNote.schema).delete()
    }
}
