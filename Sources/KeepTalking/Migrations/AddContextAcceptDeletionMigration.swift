import FluentKit

struct AddContextAcceptDeletionMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .field("accept_deletion", .bool)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .deleteField("accept_deletion")
            .update()
    }
}
