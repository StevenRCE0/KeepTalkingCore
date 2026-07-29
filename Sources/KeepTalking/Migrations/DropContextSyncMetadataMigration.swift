import FluentKit

/// Drops the context's persisted sync metadata.
///
/// `sync_metadata` cached a per-sender summary plus chunk digests over the
/// whole message table, recomputed — a full-table read and SHA256 per chunk —
/// on every batch that persisted a message. Nothing on the wire used the cached
/// copy: a sync request rebuilds the summary fresh from the table each time,
/// reconcile compares only fresh summaries, and `KeepTalkingContext`'s `Codable`
/// conformance excluded the field, so it was never shared. Its single reader
/// took one number back out of it, `chunkSize`, which no production caller ever
/// set to anything but the default.
///
/// A plain column with no index or foreign key, so SQLite drops it in place.
struct DropContextSyncMetadataMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .deleteField("sync_metadata")
            .update()
    }

    /// Restored as nullable — its only shape. The column held a cache, so a
    /// revert has nothing to backfill: the next summary rebuild reproduces
    /// every value it ever contained.
    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingContext.schema)
            .field("sync_metadata", .json)
            .update()
    }
}
