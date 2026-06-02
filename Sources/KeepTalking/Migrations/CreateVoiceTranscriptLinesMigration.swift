import FluentKit

struct CreateKeepTalkingVoiceTranscriptLinesMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Flat table: `session` and `context` are plain id columns (no foreign
        // keys). Voice calls are in-memory only, so a line never references a
        // parent row — it persists on its own.
        try await database.schema(KeepTalkingVoiceTranscriptLine.schema)
            .id()
            .field("session", .uuid, .required)
            .field("context", .uuid, .required)
            .field("author", .uuid, .required)
            .field("text", .string, .required)
            .field("source", .string, .required)
            .field("timestamp", .datetime, .required)
            .field("sequence", .int64, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingVoiceTranscriptLine.schema).delete()
    }
}
