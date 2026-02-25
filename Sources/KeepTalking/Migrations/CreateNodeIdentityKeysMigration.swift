import FluentKit

struct CreateNodeIdentityKeysMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingNodeIdentityKey.schema)
            .id()
            .field(
                "relation",
                .uuid,
                .required,
                .references(
                    KeepTalkingNodeRelation.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field("public_key", .string, .required)
            .field("private_key", .data)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingNodeIdentityKey.schema).delete()
    }
}
