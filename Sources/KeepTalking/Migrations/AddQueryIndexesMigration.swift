import FluentKit
import SQLKit

/// The indexes every per-context read needs. Until this migration no table
/// had one, so paging a chat, counting a thread or cascading a delete scanned
/// the whole table.
///
/// `IF NOT EXISTS` because the app and its extensions open the same file and
/// can run the migration at the same time.
struct AddQueryIndexesMigration: AsyncMigration {
    struct Index {
        let name: String
        let table: String
        let columns: [String]
    }

    static let indexes: [Index] = [
        // Covers `context = ? ORDER BY timestamp, id` pages and range counts.
        Index(
            name: "kt_context_messages_context_timestamp_id",
            table: KeepTalkingContextMessage.schema,
            columns: ["context", "timestamp", "id"]
        ),
        // Eager-loading a page's attachments, and the cascade on message delete.
        Index(
            name: "kt_context_attachments_parent_message",
            table: KeepTalkingContextAttachment.schema,
            columns: ["parent_message"]
        ),
        Index(
            name: "kt_context_attachments_context",
            table: KeepTalkingContextAttachment.schema,
            columns: ["context"]
        ),
        Index(
            name: "kt_threads_context",
            table: KeepTalkingThread.schema,
            columns: ["context"]
        ),
        // The set-null cascades on message delete.
        Index(
            name: "kt_threads_start_message",
            table: KeepTalkingThread.schema,
            columns: ["start_message"]
        ),
        Index(
            name: "kt_threads_end_message",
            table: KeepTalkingThread.schema,
            columns: ["end_message"]
        ),
    ]

    func prepare(on database: any Database) async throws {
        let sql = try Self.sql(database)
        for index in Self.indexes {
            var statement: SQLQueryString =
                "CREATE INDEX IF NOT EXISTS \(ident: index.name) ON \(ident: index.table) ("
            for (offset, column) in index.columns.enumerated() {
                if offset > 0 { statement.appendLiteral(", ") }
                statement.appendInterpolation(ident: column)
            }
            statement.appendLiteral(")")
            try await sql.raw(statement).run()
        }
    }

    func revert(on database: any Database) async throws {
        let sql = try Self.sql(database)
        for index in Self.indexes.reversed() {
            try await sql.raw("DROP INDEX IF EXISTS \(ident: index.name)").run()
        }
    }

    private static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw KeepTalkingStoreError.notSQL
        }
        return sql
    }
}

enum KeepTalkingStoreError: Error {
    /// The store's database does not speak SQL — never the case with SQLite.
    case notSQL
    /// SQLite reported a journal mode other than the one just requested.
    case journalModeRefused(requested: String, actual: String)
}
