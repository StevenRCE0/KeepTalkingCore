import FluentKit

/// Link previews, images included, ride their message (`link_previews`).
struct AddLinkPreviewsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextMessage.schema)
            .field("link_previews", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContextMessage.schema)
            .deleteField("link_previews")
            .update()
    }
}
