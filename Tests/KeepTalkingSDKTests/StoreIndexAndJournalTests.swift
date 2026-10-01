import FluentKit
import Foundation
import SQLKit
import Testing

@testable import KeepTalkingSDK

struct StoreIndexAndJournalTests {
    @Test("the migration creates every index")
    func indexesExist() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let sql = try #require(store.database as? any SQLDatabase)

        for index in AddQueryIndexesMigration.indexes {
            let names = try await sql.raw("PRAGMA index_list(\(ident: index.table))")
                .all()
                .map { try $0.decode(column: "name", as: String.self) }
            #expect(names.contains(index.name), "\(index.name) missing on \(index.table)")
        }
        await store.shutdown()
    }

    @Test("a context range count is answered from the covering index")
    func rangeCountUsesCoveringIndex() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let sql = try #require(store.database as? any SQLDatabase)

        let plan = try await sql.raw(
            """
            EXPLAIN QUERY PLAN SELECT COUNT(*) FROM kt_context_messages
            WHERE context = \(bind: UUID().uuidString)
            AND timestamp >= \(bind: 0.0) AND timestamp <= \(bind: 1.0)
            """
        )
        .all()
        .map { try $0.decode(column: "detail", as: String.self) }
        .joined(separator: "\n")

        #expect(plan.contains("USING COVERING INDEX kt_context_messages_context_timestamp_id"), Comment(rawValue: plan))
        await store.shutdown()
    }

    @Test("a keyed page and a thread count seek the index to their cuts")
    func keyedReadsSeekTheIndex() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let sql = try #require(store.database as? any SQLDatabase)
        let contextID = UUID()
        let start = KeepTalkingMessageKey(timestamp: 10, id: UUID())
        let end = KeepTalkingMessageKey(timestamp: 20, id: UUID())

        // The next older page above a window's head, and a stored thread's rows.
        let page = MessageRangeReader.keysStatement(
            in: contextID, range: .before(end), direction: .backward, limit: 51
        )
        let count = MessageRangeReader.countStatement(
            in: contextID, range: .thread(start: start, end: end)
        )
        for statement in [page, count] {
            let plan = try await sql.raw("EXPLAIN QUERY PLAN " + statement)
                .all()
                .map { try $0.decode(column: "detail", as: String.self) }
                .joined(separator: "\n")
            // A seek bounded by the row value, not a scan of the context's
            // whole index segment filtered row by row.
            #expect(
                plan.contains("kt_context_messages_context_timestamp_id (context=? AND (timestamp,id)"),
                Comment(rawValue: plan))
            #expect(!plan.contains("TEMP B-TREE"), Comment(rawValue: plan))
        }
        await store.shutdown()
    }

    @Test("a file store switches to WAL once and stays there when reopened")
    func fileStoreUsesWAL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kt-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")

        let first = try await KeepTalkingModelStore.make(databaseURL: url, journal: .wal)
        #expect(try await first.journalMode() == "wal")
        // Migrating again is a no-op, journal included.
        try await first.migrate()
        #expect(try await first.journalMode() == "wal")
        await first.shutdown()

        let reopened = try await KeepTalkingModelStore.make(databaseURL: url, journal: .unchanged)
        #expect(try await reopened.journalMode() == "wal")
        await reopened.shutdown()
    }

    @Test("`unchanged` leaves a fresh file on the rollback journal")
    func unchangedLeavesRollbackJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kt-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")

        let store = try await KeepTalkingModelStore.make(databaseURL: url, journal: .unchanged)
        #expect(try await store.journalMode() == "delete")
        await store.shutdown()
    }
}
