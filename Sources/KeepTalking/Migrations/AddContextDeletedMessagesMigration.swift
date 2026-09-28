import FluentKit

struct AddContextDeletedMessagesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .field("deleted_messages", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .deleteField("deleted_messages")
            .update()
    }
}
