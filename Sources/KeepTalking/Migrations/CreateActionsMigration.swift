import FluentKit

struct CreateKeepTalkingActionsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingAction.schema)
            .id()
            .field("payload", .json, .required)
            .field(
                "node",
                .uuid,
                .references(KeepTalkingNode.schema, "id")
            )
            .field("descriptor", .json, .required)
            .field("remote_authorisable", .bool, .required)
            .field("blocking_authorisation", .bool, .required)
            .field("disabled", .bool)
            .field("created_at", .datetime, .required)
            .field("last_used", .datetime)
            .field("cached_mcp_tools", .json)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingAction.schema).delete()
    }
}
