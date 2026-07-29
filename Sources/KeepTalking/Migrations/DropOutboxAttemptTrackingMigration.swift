import FluentKit

/// Drops the outbox's attempt-tracking columns.
///
/// `attempts` and `last_error` were written on every failed push and read by
/// nothing — no SDK caller, no test, and no view in the app. The retry contract
/// is just "the row still exists, so drain it again"; the diagnostics they
/// duplicated already go to `onLog?`.
///
/// Both are plain columns — no index, no foreign key — so SQLite can drop them
/// in place. The `context` foreign key and the `id` primary key are deliberately
/// left alone: SQLite refuses `DROP COLUMN` on a column used in a foreign-key
/// constraint, so removing those would mean a full table rebuild.
struct DropKeepTalkingOutboxAttemptTrackingMigration: AsyncMigration {
    /// One `.update()` per column: SQLite's `ALTER TABLE` accepts a single
    /// `DROP COLUMN` per statement, and Fluent emits one statement per
    /// `.update()`. Batching both into one call produces
    /// `DROP COLUMN attempts, DROP COLUMN last_error`, which SQLite rejects
    /// with `near ",": syntax error`.
    func prepare(on database: any Database) async throws {
        try await database.schema(KeepTalkingOutboxEntry.schema)
            .deleteField("attempts")
            .update()
        try await database.schema(KeepTalkingOutboxEntry.schema)
            .deleteField("last_error")
            .update()
    }

    /// Re-adds both columns as nullable. A `.required` column cannot be added
    /// back to a table that already has rows, and nothing reads either value,
    /// so nullable is the only shape a revert can honestly restore.
    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingOutboxEntry.schema)
            .field("attempts", .int)
            .update()
        try await database.schema(KeepTalkingOutboxEntry.schema)
            .field("last_error", .string)
            .update()
    }
}
