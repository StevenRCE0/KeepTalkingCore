import FluentKit

struct AddDiscoveredDuringLogonToNodesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingNode.schema)
            .field("discovered_during_logon", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingNode.schema)
            .deleteField("discovered_during_logon")
            .update()
    }
}
