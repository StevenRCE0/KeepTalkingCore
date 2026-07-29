import Foundation
import Testing

@testable import KeepTalkingSDK

struct ModelStoreTests {
    /// Exercises the whole migration list against a real file-backed store,
    /// including the schema-altering ones.
    ///
    /// Worth its own test because the in-memory store every other test uses
    /// only ever proves that migrations apply to an EMPTY database. The
    /// `ALTER TABLE` migrations are the ones that can fail — SQLite takes a
    /// single column operation per statement, so batching two `deleteField`
    /// calls into one `.update()` emits invalid SQL that only shows up here.
    @Test("every migration applies, reverts, and re-applies on a real file")
    func migrationListAppliesAndReverts() async throws {
        let databaseURL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
        .appendingPathExtension("sqlite")

        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: databaseURL)
            try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
            try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        }

        let store = try await KeepTalkingModelStore.make(databaseURL: databaseURL)

        // A side note exercises the columns the version migration adds, and
        // proves the backfill left them readable rather than NULL.
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)
        let note = KeepTalkingSideNote(
            contextID: try context.requireID(),
            key: "plan",
            value: "ship it",
            versionCounter: 1,
            versionWriter: UUID()
        )
        try await note.save(on: store.database)

        let loaded = try #require(
            try await KeepTalkingSideNote.query(on: store.database).first()
        )
        #expect(loaded.versionCounter == 1)

        // revert + re-apply: catches a migration whose `revert` does not undo
        // what `prepare` did.
        try await store.reset()
        #expect(try await KeepTalkingSideNote.query(on: store.database).count() == 0)
    }

    /// The case the full-list test cannot reach: applying a schema migration to
    /// a table that ALREADY HAS ROWS.
    ///
    /// Running the list on a fresh database only proves migrations apply to an
    /// empty schema. `AddSideNoteVersionMigration` shipped a fatal bug that was
    /// invisible that way — its backfill read rows through the model, whose
    /// version fields are non-optional, while the freshly-added columns were
    /// still NULL. On an empty table there is nothing to decode and it passed;
    /// on any real database it failed at launch.
    @Test("a schema migration backfills a table that already has rows")
    func versionMigrationBackfillsExistingRows() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)
        let contextID = try context.requireID()

        for key in ["alpha", "beta", "gamma"] {
            let note = KeepTalkingSideNote(
                contextID: contextID,
                key: key,
                value: "value-\(key)",
                versionCounter: 7,
                versionWriter: UUID()
            )
            try await note.save(on: store.database)
        }

        // Drop the version columns, then re-add them with rows in place — the
        // exact shape of upgrading an existing install.
        let migration = AddSideNoteVersionMigration()
        try await migration.revert(on: store.database)
        try await migration.prepare(on: store.database)

        // Decoding at all is the assertion: a NULL in either column throws here.
        let notes = try await KeepTalkingSideNote.query(on: store.database)
            .filter(\.$context.$id, .equal, contextID)
            .all()
        #expect(notes.count == 3)
        // Backfilled rows share one version, so two nodes' pre-existing notes
        // tie rather than overwriting each other.
        #expect(notes.allSatisfy { $0.versionCounter == 0 })
        #expect(notes.allSatisfy { $0.versionWriter == KeepTalkingSideNote.unknownWriter })
        #expect(Set(notes.map(\.key)) == ["alpha", "beta", "gamma"])

        // And a real write still wins over every backfilled row.
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        let updated = try await client.upsertSideNote(
            key: "alpha", value: "edited", in: contextID)
        #expect(updated.versionCounter > 0)
    }

    @Test("model store reset recreates an empty schema")
    func resetRecreatesEmptySchema() async throws {
        let databaseURL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
        .appendingPathExtension("sqlite")

        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: databaseURL)
            try? fm.removeItem(
                at: URL(fileURLWithPath: databaseURL.path + "-shm")
            )
            try? fm.removeItem(
                at: URL(fileURLWithPath: databaseURL.path + "-wal")
            )
        }

        let store = try await KeepTalkingModelStore.make(databaseURL: databaseURL)
        let node = KeepTalkingNode(id: UUID())

        try await node.save(on: store.database)
        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 1
        )

        try await store.reset()

        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 0
        )

        let replacementNode = KeepTalkingNode(id: UUID())
        try await replacementNode.save(on: store.database)
        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 1
        )
    }
}
