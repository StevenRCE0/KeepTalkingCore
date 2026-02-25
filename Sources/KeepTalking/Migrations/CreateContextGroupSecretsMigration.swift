import FluentKit

struct CreateContextGroupSecretsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextGroupSecret.schema)
            .field(
                "context_id",
                .uuid,
                .identifier(auto: false),
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("secret", .data, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextGroupSecret.schema).delete()
    }
}
