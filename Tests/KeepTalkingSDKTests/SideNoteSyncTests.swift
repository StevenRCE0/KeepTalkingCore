import Foundation
import Testing

@testable import KeepTalkingSDK

/// The whole-set exchange is only correct while the set stays small. These
/// cover the bounds that make that true, and the version/merge rules the
/// exchange rests on — which had no coverage at all.
struct SideNoteSyncTests {
    private func makeClient() async throws -> (KeepTalkingClient, UUID) {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: store.database)
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        return (client, contextID)
    }

    // MARK: - Bounds

    @Test("a full context's side notes still encode under the sync budget")
    func sideNoteSetFitsItsBudgetWhenFull() throws {
        // The arithmetic the bounds rest on. If someone raises a limit without
        // re-checking the budget, the whole-set exchange starts silently
        // refusing to attach — this is what catches that at desk time.
        let key = String(
            repeating: "k",
            count: KeepTalkingSideNoteLimits.maximumKeyBytes
        )
        let value = String(
            repeating: "v",
            count: KeepTalkingSideNoteLimits.maximumValueBytes
        )
        let live = (0..<KeepTalkingSideNoteLimits.maximumLiveNotes).map { index in
            KeepTalkingSideNoteDTO(
                key: "\(index)-\(key)".prefix(
                    KeepTalkingSideNoteLimits.maximumKeyBytes
                ).description,
                value: value,
                isArchived: false,
                versionCounter: index,
                versionWriter: UUID()
            )
        }
        let tombstones = (0..<KeepTalkingSideNoteLimits.maximumTombstones).map {
            index in
            KeepTalkingSideNoteDTO(
                key: "t\(index)-\(key)".prefix(
                    KeepTalkingSideNoteLimits.maximumKeyBytes
                ).description,
                value: "",
                isArchived: true,
                versionCounter: index,
                versionWriter: UUID()
            )
        }

        let encoded = try JSONEncoder().encode(live + tombstones)
        #expect(encoded.count <= KeepTalkingSideNoteLimits.maximumEncodedBytes)
    }

    @Test("an oversized value is refused instead of breaking sync later")
    func oversizedValueIsRefused() async throws {
        let (client, contextID) = try await makeClient()
        await #expect(throws: KeepTalkingClientError.self) {
            try await client.upsertSideNote(
                key: "note",
                value: String(
                    repeating: "v",
                    count: KeepTalkingSideNoteLimits.maximumValueBytes + 1
                ),
                in: contextID
            )
        }
        #expect(try await client.allSideNoteDTOs(in: contextID).isEmpty)
    }

    @Test("a new note past the live cap is refused but updates still work")
    func liveNoteCapRefusesNewKeysOnly() async throws {
        let (client, contextID) = try await makeClient()
        for index in 0..<KeepTalkingSideNoteLimits.maximumLiveNotes {
            try await client.upsertSideNote(
                key: "note-\(index)",
                value: "v",
                in: contextID
            )
        }

        await #expect(throws: KeepTalkingClientError.self) {
            try await client.upsertSideNote(key: "one-too-many", value: "v", in: contextID)
        }

        // A full context must still be editable — the cap is on how many notes
        // exist, not on writing to the ones that do.
        let updated = try await client.upsertSideNote(
            key: "note-0",
            value: "revised",
            in: contextID
        )
        #expect(updated.value == "revised")
    }

    @Test("tombstones are pruned so the set cannot grow without bound")
    func tombstonesArePruned() async throws {
        let (client, contextID) = try await makeClient()
        let overflow = 5
        for index in 0..<(KeepTalkingSideNoteLimits.maximumTombstones + overflow) {
            try await client.upsertSideNote(key: "note-\(index)", value: "v", in: contextID)
            _ = try await client.archiveSideNote(key: "note-\(index)", in: contextID)
        }

        let notes = try await client.allSideNoteDTOs(in: contextID)
        let tombstones = notes.filter(\.isArchived)
        #expect(tombstones.count == KeepTalkingSideNoteLimits.maximumTombstones)
        // Newest retained, oldest dropped.
        #expect(!tombstones.contains { $0.key == "note-0" })
        #expect(
            tombstones.contains {
                $0.key
                    == "note-\(KeepTalkingSideNoteLimits.maximumTombstones + overflow - 1)"
            }
        )
    }

    // MARK: - Version and merge rules

    @Test("version ordering breaks counter ties deterministically by writer")
    func versionOrderingIsTotalAndDeterministic() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

        #expect(
            KeepTalkingSideNoteVersion(counter: 1, writer: lower)
                < KeepTalkingSideNoteVersion(counter: 2, writer: lower)
        )
        // Same counter on both sides of a partition: the writer decides, and
        // both nodes compare the same pair, so both reach the same answer.
        #expect(
            KeepTalkingSideNoteVersion(counter: 2, writer: lower)
                < KeepTalkingSideNoteVersion(counter: 2, writer: higher)
        )
        #expect(
            !(KeepTalkingSideNoteVersion(counter: 2, writer: higher)
                < KeepTalkingSideNoteVersion(counter: 2, writer: lower))
        )
    }

    @Test("merge takes strictly greater versions and is idempotent")
    func mergeTakesStrictlyGreaterVersionsOnly() async throws {
        let (client, contextID) = try await makeClient()
        try await client.upsertSideNote(key: "topic", value: "local", in: contextID)
        let local = try #require(
            try await client.allSideNoteDTOs(in: contextID).first
        )

        // Older loses.
        _ = try await client.mergeSideNotes(
            [
                KeepTalkingSideNoteDTO(
                    key: "topic",
                    value: "stale",
                    isArchived: false,
                    versionCounter: local.versionCounter - 1,
                    versionWriter: UUID()
                )
            ],
            contextID: contextID
        )
        #expect(try await client.allSideNoteDTOs(in: contextID).first?.value == "local")

        // Newer wins.
        let newer = KeepTalkingSideNoteDTO(
            key: "topic",
            value: "remote",
            isArchived: false,
            versionCounter: local.versionCounter + 1,
            versionWriter: UUID()
        )
        #expect(try await client.mergeSideNotes([newer], contextID: contextID))
        #expect(try await client.allSideNoteDTOs(in: contextID).first?.value == "remote")

        // Replaying the same delivery changes nothing — the redelivery
        // guarantee the fire-and-forget push depends on.
        #expect(try await client.mergeSideNotes([newer], contextID: contextID) == false)
        #expect(try await client.allSideNoteDTOs(in: contextID).first?.value == "remote")
    }

    @Test("the digest covers tombstones and ignores values")
    func digestCoversTombstonesAndIgnoresValues() {
        let writer = UUID()
        let base = KeepTalkingSideNoteDTO(
            key: "topic",
            value: "one",
            isArchived: false,
            versionCounter: 1,
            versionWriter: writer
        )
        let differentValue = KeepTalkingSideNoteDTO(
            key: "topic",
            value: "two",
            isArchived: false,
            versionCounter: 1,
            versionWriter: writer
        )
        let archived = KeepTalkingSideNoteDTO(
            key: "topic",
            value: "",
            isArchived: true,
            versionCounter: 1,
            versionWriter: writer
        )

        // Value is excluded: the version pair already changes on every write.
        #expect(
            KeepTalkingSideNoteDigest.digest(of: [base])
                == KeepTalkingSideNoteDigest.digest(of: [differentValue])
        )
        // A tombstone must be distinguishable from an absent key, otherwise
        // "they deleted it" and "we never saw it" reconcile the wrong way.
        #expect(
            KeepTalkingSideNoteDigest.digest(of: [base])
                != KeepTalkingSideNoteDigest.digest(of: [archived])
        )
        #expect(KeepTalkingSideNoteDigest.digest(of: [archived]) != Data())

        let other = KeepTalkingSideNoteDTO(
            key: "another",
            value: "x",
            isArchived: false,
            versionCounter: 3,
            versionWriter: writer
        )
        // Order-independent: each side sorts before hashing, so two peers
        // holding the same set agree however they happened to read it.
        #expect(
            KeepTalkingSideNoteDigest.digest(of: [base, other])
                == KeepTalkingSideNoteDigest.digest(of: [other, base])
        )
    }

    @Test("the digest is stable for keys Swift considers equal but bytes do not")
    func digestIsStableAcrossCanonicallyEqualKeys() {
        // Precomposed "é" and "e" + combining acute: `==` in Swift, distinct on
        // the wire and to SQLite's unique index. Sorting by key alone leaves
        // their relative order to an unstable sort, so two peers could hash the
        // same set in opposite orders and disagree forever.
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        #expect(precomposed == decomposed)

        let writerA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let writerB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let first = KeepTalkingSideNoteDTO(
            key: precomposed,
            value: "one",
            isArchived: false,
            versionCounter: 1,
            versionWriter: writerA
        )
        let second = KeepTalkingSideNoteDTO(
            key: decomposed,
            value: "two",
            isArchived: false,
            versionCounter: 2,
            versionWriter: writerB
        )

        #expect(
            KeepTalkingSideNoteDigest.digest(of: [first, second])
                == KeepTalkingSideNoteDigest.digest(of: [second, first])
        )
    }

    @Test("keys are normalized on write so one key cannot become two rows")
    func keysAreNormalizedOnWrite() async throws {
        let (client, contextID) = try await makeClient()
        try await client.upsertSideNote(key: "caf\u{00E9}", value: "one", in: contextID)
        try await client.upsertSideNote(key: "cafe\u{0301}", value: "two", in: contextID)

        // One key to Swift must be one row to SQLite, or the merge's
        // uniquing silently drops one of them.
        let notes = try await client.allSideNoteDTOs(in: contextID)
        #expect(notes.count == 1)
        #expect(notes.first?.value == "two")
    }
}
