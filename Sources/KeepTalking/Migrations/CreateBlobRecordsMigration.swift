import FluentKit

struct CreateKeepTalkingBlobRecordsMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingBlobRecord.schema)
            .field("blob_id", .string, .identifier(auto: false))
            .field("relative_path", .string)
            .field("availability", .string, .required)
            .field("mime_type", .string, .required)
            .field("byte_count", .int, .required)
            .field("received_bytes", .int, .required)
            .field("last_accessed_at", .datetime)
            .field("ai_described_at", .datetime)
            .field("ai_last_native_include_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingBlobRecord.schema).delete()
    }
}
