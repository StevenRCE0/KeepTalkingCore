import FluentKit
import Foundation
import SQLKit
import Testing

@testable import KeepTalkingSDK

struct ActivityReportingDatabaseTests {
    @Test("the store's database is an SQLDatabase")
    func databaseIsSQLDatabase() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        #expect(store.database is any SQLDatabase)
        #expect(store.database is ActivityReportingDatabase)
        await store.shutdown()
    }

    @Test("a row fetched, deleted and saved again keeps every column")
    func deleteThenSaveKeepsEveryColumn() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let database = store.database
        let id = UUID()
        let mark = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let context = KeepTalkingContext(id: id, updatedAt: updatedAt)
        context.consumedMarks = [mark]
        try await context.save(on: database)

        // Read back, so every field's input is cleared into its output —
        // the state FluentKit's insert path mishandles on a plain `Database`.
        let fetched = try #require(try await KeepTalkingContext.find(id, on: database))
        try await fetched.delete(on: database)
        #expect(try await KeepTalkingContext.find(id, on: database) == nil)
        // FluentKit regenerates an `@ID` whose input the fetch cleared, so the
        // id is pinned; every other column must come back on its own.
        fetched.id = id
        try await fetched.save(on: database)

        let restored = try #require(try await KeepTalkingContext.find(id, on: database))
        #expect(restored.updatedAt == updatedAt)
        #expect(restored.consumedMarks == [mark])
        await store.shutdown()
    }

    @Test("a transaction with several queries flips activity exactly twice")
    func transactionCountsAsOneOperation() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let (database, activity) = try Self.privatelyCounted(store)

        try await database.transaction { db in
            for _ in 0..<3 {
                try await KeepTalkingContext(id: UUID()).save(on: db)
            }
        }

        #expect(activity.flips.snapshot == [true, false])
        #expect(!activity.isBusy)
        await store.shutdown()
    }

    @Test("raw SQL through the wrapper is counted")
    func rawSQLIsCounted() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let (database, activity) = try Self.privatelyCounted(store)

        let rows = try await database.raw("SELECT 1 AS one").all()

        #expect(rows.count == 1)
        #expect(activity.flips.snapshot == [true, false])
        #expect(!activity.isBusy)
        await store.shutdown()
    }

    /// The store's database re-wrapped over a private gate and counter, so
    /// suites running alongside cannot flip the flag under the test.
    private static func privatelyCounted(
        _ store: KeepTalkingInMemoryStore
    ) throws -> (ActivityReportingDatabase, ActivityRecorder) {
        let wrapped = try #require(store.database as? ActivityReportingDatabase)
        let activity = ActivityRecorder()
        let gate = DatabaseGate(configuration: .automatic, connections: 2, activity: activity.hooks)
        return (ActivityReportingDatabase(base: wrapped.base, gate: gate), activity)
    }
}
