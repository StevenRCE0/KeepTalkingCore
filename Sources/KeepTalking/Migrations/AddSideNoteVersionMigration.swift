import FluentKit
import Foundation

/// Adds the `(counter, writer)` version pair that replaces wall-clock
/// last-writer-wins for side-note merges.
///
/// Wall-clock LWW compares `updatedAt` across nodes whose clocks are not
/// synchronised, so the "winner" of a concurrent edit is decided by whichever
/// machine's clock happened to run fast. The counter is monotonic per context
/// and the writer node id breaks ties deterministically, so both sides of a
/// partition converge on the same value without trusting any clock.
///
/// Two column additions, one `.update()` each: SQLite's `ALTER TABLE` takes a
/// single column operation per statement, and Fluent emits one statement per
/// `.update()`.
///
/// The backfill and both ALTERs run in ONE transaction. The model declares
/// these fields non-optional, so a half-applied migration — columns present,
/// values still NULL — would make every side-note query throw at decode.
struct AddSideNoteVersionMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { db in
            try await db.schema(KeepTalkingSideNote.schema)
                .field("version_counter", .int)
                .update()
            try await db.schema(KeepTalkingSideNote.schema)
                .field("version_writer", .uuid)
                .update()

            // Backfill every existing row to the SAME version, in one
            // filterless update.
            //
            // Two things matter here. First, this must not read rows through
            // the model: `versionCounter`/`versionWriter` are non-optional, the
            // columns are still NULL at this point, and any `.all()` would fail
            // to decode before the backfill could run. A `.set(...).update()`
            // writes without decoding.
            //
            // Second, giving pre-existing rows DISTINCT counters would be
            // actively harmful. Each node ranks only its own rows, so node A's
            // rank-3 and node B's rank-5 for the same key are not comparable —
            // the ordering is locally invented either way. Distinct counters
            // would just make one node's backfilled content arbitrarily
            // overwrite the other's. Identical versions tie instead, strict `>`
            // means neither side clobbers the other, and the first genuine
            // post-migration edit (counter >= 1) wins everywhere.
            try await KeepTalkingSideNote.query(on: db)
                .set(\.$versionCounter, to: 0)
                .set(\.$versionWriter, to: KeepTalkingSideNote.unknownWriter)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KeepTalkingSideNote.schema)
            .deleteField("version_counter")
            .update()
        try await database.schema(KeepTalkingSideNote.schema)
            .deleteField("version_writer")
            .update()
    }
}
