import FluentKit

struct CreateKeepTalkingThreadWorkspacesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingThreadWorkspace.schema)
            .id()
            .field(
                "thread",
                .uuid,
                .required,
                .references(
                    KeepTalkingThread.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field("path", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "thread")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingThreadWorkspace.schema).delete()
    }
}
