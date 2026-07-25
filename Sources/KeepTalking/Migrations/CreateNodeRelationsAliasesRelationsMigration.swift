import FluentKit

struct CreateNodeRelationsAliasesRelationsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingNodeRelationAliasRelation.schema)
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
            .field(
                "alias",
                .uuid,
                .required,
                .references(
                    KeepTalkingMapping.schema,
                    "id",
                    onDelete: .cascade
                )
            )
            .field("approving_context", .json)
            .field("permission", .json)
            .field("allow_remote_confirmation", .bool)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database
            .schema(KeepTalkingNodeRelationAliasRelation.schema)
            .delete()
    }
}
