import FluentKit

struct CreateKeepTalkingWorkspacePlansMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspacePlanRecord.schema)
            .id()
            .field(
                "context",
                .uuid,
                .references(KeepTalkingContext.schema, "id", onDelete: .cascade)
            )
            .field("prompt", .string, .required)
            .field("plan_data", .data, .required)
            .field("state_data", .data, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingWorkspacePlanRecord.schema).delete()
    }
}
