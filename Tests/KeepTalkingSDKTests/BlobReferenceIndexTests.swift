import Foundation
import Testing

@testable import KeepTalkingSDK

struct BlobReferenceIndexTests {
    private typealias Digest = KeepTalkingBlobReferenceIndex.Digest

    /// Blob IDs are 64-char hex SHA-256 digests; build one from a seed so each
    /// test blob is distinct and valid.
    private func blobID(_ seed: Int) -> String {
        String(format: "%064x", seed)
    }

    private func makeStore(
        blobIDs: [String],
        relativePaths: [String: String] = [:]
    ) async throws -> KeepTalkingInMemoryStore {
        let store = try await KeepTalkingInMemoryStore.make()
        for blobID in blobIDs {
            let record = KeepTalkingBlobRecord(
                blobID: blobID,
                relativePath: relativePaths[blobID],
                availability: .ready,
                mimeType: "application/octet-stream",
                byteCount: 1,
                receivedBytes: 1
            )
            try await record.create(on: store.database)
        }
        return store
    }

    // MARK: - Digest

    @Test("digest round-trips hex and normalizes case")
    func digestRoundTrip() throws {
        let hex =
            "0123456789abcdef" + "fedcba9876543210" + String(repeating: "a", count: 16)
            + String(repeating: "f", count: 16)
        let digest = try #require(Digest(hex: hex))
        #expect(digest.hexString == hex)

        let upper = try #require(Digest(hex: hex.uppercased()))
        #expect(upper == digest)
        #expect(upper.hexString == hex)
    }

    @Test("digest rejects anything that is not 64 hex characters")
    func digestRejectsMalformed() {
        #expect(Digest(hex: "") == nil)
        #expect(Digest(hex: String(repeating: "a", count: 63)) == nil)
        #expect(Digest(hex: String(repeating: "a", count: 65)) == nil)
        #expect(Digest(hex: String(repeating: "g", count: 64)) == nil)
        // Right length, wrong alphabet in the last position.
        #expect(Digest(hex: String(repeating: "a", count: 63) + "-") == nil)
    }

    /// The whole merge depends on digest order matching hex-string order — if
    /// big-endian packing were wrong, the two would disagree and the set
    /// difference would silently drop or keep the wrong blobs.
    @Test("digest order matches hex-string order")
    func digestOrderMatchesHexOrder() throws {
        let hexes =
            (0..<64).map { blobID($0 * 7_919) } + [
                String(repeating: "f", count: 64),
                String(repeating: "0", count: 63) + "1",
            ]
        let digests = try hexes.map { try #require(Digest(hex: $0)) }

        #expect(digests.sorted().map(\.hexString) == hexes.sorted())
    }

    // MARK: - referencedBlobIDs

    @Test("referenced IDs come back sorted, and an empty database yields none")
    func referencedIDsAreSorted() async throws {
        let empty = try await makeStore(blobIDs: [])
        #expect(try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(on: empty.database).isEmpty)

        // Insert out of order to prove the sort is ours, not insertion order.
        let ids = [blobID(9), blobID(1), blobID(5)]
        let store = try await makeStore(blobIDs: ids)
        let found = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(on: store.database)

        #expect(found.map(\.hexString) == ids.sorted())
    }

    /// Fail-closed: a reference we cannot decode must abort the caller, never be
    /// skipped. Skipping it reads as "nothing points at this file", which is the
    /// direction that deletes bytes still in use.
    @Test("a malformed blob ID throws instead of being skipped")
    func malformedBlobIDThrows() async throws {
        let store = try await makeStore(blobIDs: [blobID(1), "not-a-digest"])

        await #expect(throws: KeepTalkingBlobReferenceIndexError.self) {
            _ = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(on: store.database)
        }
    }

    // MARK: - references

    /// Ready files are keyed on disk by `prefix/hash.ext`, so reclamation needs
    /// the recorded path, not just the digest — the extension is not derivable.
    @Test("references carry each record's on-disk path, sorted by digest")
    func referencesCarryPaths() async throws {
        let withPath = blobID(3)
        let withoutPath = blobID(1)
        let store = try await makeStore(
            blobIDs: [withPath, withoutPath],
            relativePaths: [withPath: "00/\(withPath).png"]
        )

        let references = try await KeepTalkingBlobReferenceIndex.references(
            on: store.database
        )

        #expect(references.map(\.blobID) == [withoutPath, withPath].sorted())
        #expect(references.first { $0.blobID == withPath }?.relativePath == "00/\(withPath).png")
        // A record that never reached `.ready` has no file to remove.
        #expect(references.first { $0.blobID == withoutPath }?.relativePath == nil)
    }

    @Test("subtracting keeps paths attached to the survivors")
    func subtractPreservesPaths() async throws {
        let shared = blobID(42)
        let exclusive = blobID(7)
        let doomed = try await makeStore(
            blobIDs: [shared, exclusive],
            relativePaths: [
                shared: "00/\(shared).png",
                exclusive: "00/\(exclusive).pdf",
            ]
        )
        let survivor = try await makeStore(blobIDs: [shared])

        var candidates = try await KeepTalkingBlobReferenceIndex.references(
            on: doomed.database
        )
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: survivor.database,
            from: &candidates
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.blobID == exclusive)
        #expect(candidates.first?.relativePath == "00/\(exclusive).pdf")
    }

    // MARK: - references(inFileTreeOf:)

    private func makeBlobStore() throws -> KeepTalkingBlobStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KTBlobScan-\(UUID().uuidString)", isDirectory: true)
        let store = KeepTalkingBlobStore(baseURL: base)
        try store.ensureBaseDirectory()
        return store
    }

    @Test("the file tree stands in for an index, ready files and partials alike")
    func fileTreeReferences() async throws {
        let store = try makeBlobStore()
        defer { try? FileManager.default.removeItem(at: store.baseURL) }

        let ready = blobID(1)
        let partial = blobID(2)
        try store.put(data: Data([0xAB]), blobID: ready, pathExtension: "png")
        try store.appendPartial(data: Data([0xCD]), blobID: partial)
        // Not a blob: nothing may attribute it to an identity, so nothing may
        // delete it on an identity's behalf.
        try Data().write(to: store.baseURL.appendingPathComponent("README"))

        let references = KeepTalkingBlobReferenceIndex.references(inFileTreeOf: store)

        #expect(references.map(\.blobID) == [ready, partial].sorted())
        #expect(
            references.first { $0.blobID == ready }?.relativePath
                == (try store.relativePath(for: ready, pathExtension: "png"))
        )
        #expect(
            references.first { $0.blobID == partial }?.relativePath
                == (try store.partialRelativePath(for: partial))
        )
    }

    /// A blob can be on disk twice — a promoted file plus a leftover partial.
    /// One reference per blob, carrying the ready path, keeps deletion counts
    /// honest (and `remove` clears the partial either way).
    @Test("a blob present as both ready and partial yields one reference")
    func fileTreeDeduplicatesReadyAndPartial() async throws {
        let store = try makeBlobStore()
        defer { try? FileManager.default.removeItem(at: store.baseURL) }

        let both = blobID(5)
        try store.put(data: Data([0xAB]), blobID: both, pathExtension: "pdf")
        try store.appendPartial(data: Data([0xCD]), blobID: both)

        let references = KeepTalkingBlobReferenceIndex.references(inFileTreeOf: store)

        #expect(references.count == 1)
        #expect(references.first?.relativePath?.hasPrefix("partial/") == false)
    }

    @Test("an empty or missing blob directory yields no references")
    func fileTreeHandlesEmptyDirectory() throws {
        let store = try makeBlobStore()
        defer { try? FileManager.default.removeItem(at: store.baseURL) }
        #expect(KeepTalkingBlobReferenceIndex.references(inFileTreeOf: store).isEmpty)

        let missing = KeepTalkingBlobStore(
            baseURL: store.baseURL.appendingPathComponent("nope", isDirectory: true)
        )
        #expect(KeepTalkingBlobReferenceIndex.references(inFileTreeOf: missing).isEmpty)
    }

    /// The tolerance path end to end: the identity being deleted has a database
    /// nobody can read, so its claim is taken to be every blob on disk — and the
    /// surviving identity still narrows it down to what only the doomed identity
    /// had. What the survivor references must come through untouched.
    @Test("file-tree candidates still exclude a survivor's references")
    func fileTreeCandidatesExcludeSurvivor() async throws {
        let store = try makeBlobStore()
        defer { try? FileManager.default.removeItem(at: store.baseURL) }

        let shared = blobID(42)
        let doomedOnly = blobID(7)
        for id in [shared, doomedOnly] {
            try store.put(data: Data([0x01]), blobID: id, pathExtension: "bin")
        }
        let survivor = try await makeStore(blobIDs: [shared])

        var candidates = KeepTalkingBlobReferenceIndex.references(inFileTreeOf: store)
        #expect(candidates.count == 2)

        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: survivor.database,
            from: &candidates
        )

        #expect(candidates.map(\.blobID) == [doomedOnly])
    }

    // MARK: - subtractReferences

    @Test("disjoint references leave every candidate standing")
    func disjointKeepsAll() async throws {
        let doomed = try await makeStore(blobIDs: [blobID(1), blobID(2), blobID(3)])
        let survivor = try await makeStore(blobIDs: [blobID(7), blobID(8)])

        var candidates = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(
            on: doomed.database
        )
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: survivor.database,
            from: &candidates
        )

        #expect(candidates.map(\.hexString) == [blobID(1), blobID(2), blobID(3)])
    }

    @Test("identical references leave nothing to delete")
    func identicalRemovesAll() async throws {
        let ids = [blobID(1), blobID(2), blobID(3)]
        let doomed = try await makeStore(blobIDs: ids)
        let survivor = try await makeStore(blobIDs: ids)

        var candidates = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(
            on: doomed.database
        )
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: survivor.database,
            from: &candidates
        )

        #expect(candidates.isEmpty)
    }

    /// The case that motivated the whole design: two identities joined the same
    /// context, so both hold a record for one deduplicated file on disk.
    /// Deleting either identity must not free those bytes.
    @Test("a blob shared with a survivor is never a deletion candidate")
    func sharedBlobSurvives() async throws {
        let shared = blobID(42)
        let doomed = try await makeStore(blobIDs: [blobID(1), shared, blobID(99)])
        let survivor = try await makeStore(blobIDs: [shared, blobID(500)])

        var candidates = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(
            on: doomed.database
        )
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: survivor.database,
            from: &candidates
        )

        #expect(candidates.map(\.hexString) == [blobID(1), blobID(99)].sorted())
        #expect(!candidates.contains { $0.hexString == shared })
    }

    @Test("an empty survivor subtracts nothing, an empty candidate set stays empty")
    func emptySidesAreNoOps() async throws {
        let doomed = try await makeStore(blobIDs: [blobID(1), blobID(2)])
        let emptySurvivor = try await makeStore(blobIDs: [])

        var candidates = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(
            on: doomed.database
        )
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: emptySurvivor.database,
            from: &candidates
        )
        #expect(candidates.count == 2)

        var empty: [Digest] = []
        try await KeepTalkingBlobReferenceIndex.subtractReferences(
            on: doomed.database,
            from: &empty
        )
        #expect(empty.isEmpty)
    }

    /// Callers subtract one identity at a time, releasing each store in between.
    @Test("subtracting several survivors in sequence narrows to the exclusive set")
    func sequentialSubtractionAcrossIdentities() async throws {
        let doomed = try await makeStore(
            blobIDs: [blobID(1), blobID(2), blobID(3), blobID(4), blobID(5)]
        )
        let first = try await makeStore(blobIDs: [blobID(2)])
        let second = try await makeStore(blobIDs: [blobID(4), blobID(5)])

        var candidates = try await KeepTalkingBlobReferenceIndex.referencedBlobIDs(
            on: doomed.database
        )
        for survivor in [first, second] {
            try await KeepTalkingBlobReferenceIndex.subtractReferences(
                on: survivor.database,
                from: &candidates
            )
        }

        #expect(candidates.map(\.hexString) == [blobID(1), blobID(3)].sorted())
    }
}
