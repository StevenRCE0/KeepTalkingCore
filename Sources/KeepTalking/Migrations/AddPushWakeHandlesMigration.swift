import FluentKit

struct AddPushWakeHandlesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingNode.schema)
            .field("context_wake_handles", .json)
            .update()

        try await database
            .schema(KeepTalkingNodeRelationActionRelation.schema)
            .field("wake_handles", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingNode.schema)
            .deleteField("context_wake_handles")
            .update()

        try await database
            .schema(KeepTalkingNodeRelationActionRelation.schema)
            .deleteField("wake_handles")
            .update()
    }
}
