import FluentKit

struct CreateKeepTalkingMappingsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema)
            .id()
            .field(
                "node",
                .uuid,
                .references(KeepTalkingNode.schema, "id", onDelete: .cascade)
            )
            .field(
                "context",
                .uuid,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("kind", .string, .required)
            .field("namespace", .string)
            .field("value", .string, .required)
            .field("normalized_value", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingMapping.schema).delete()
    }
}
