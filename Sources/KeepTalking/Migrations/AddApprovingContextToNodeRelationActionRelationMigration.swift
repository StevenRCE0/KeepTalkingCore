import FluentKit

struct AddApprovingContextToNodeRelationActionRelationMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingNodeRelationActionRelation.schema)
            .field("approving_context", .data)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingNodeRelationActionRelation.schema)
            .deleteField("approving_context")
            .update()
    }
}
