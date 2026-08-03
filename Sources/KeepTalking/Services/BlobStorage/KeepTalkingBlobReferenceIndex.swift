import FluentKit
import Foundation

public enum KeepTalkingBlobReferenceIndexError: LocalizedError {
    case malformedBlobID(String)

    public var errorDescription: String? {
        switch self {
            case .malformedBlobID(let blobID):
                return "Blob record has an unreadable blob ID: \(blobID)"
        }
    }
}

/// Answers "which blob files is this database still referencing?" across
/// several identities.
///
/// Blob files are content-addressed and deduplicated into one shared directory,
/// so a file is reachable from any identity that happens to hold a record for
/// it. Deciding whether a blob is orphaned therefore requires looking at *every*
/// identity's database, not just the one being deleted.
///
/// Everything here takes a `Database` handle and nothing else: this type never
/// opens, migrates, or closes a store. That keeps store lifetime with the
/// caller, which can open one identity at a time and release it before moving
/// on rather than holding every store open at once. Staying on FluentKit (rather
/// than reaching for raw SQL) means swapping the database backbone later touches
/// this file and no caller.
public enum KeepTalkingBlobReferenceIndex {
    /// A blob ID in decoded binary form.
    ///
    /// Blob IDs are 64-character hex SHA-256 digests (`KeepTalkingBlobStore`
    /// validates `^[0-9a-f]{64}$`). Holding them as four big-endian words makes
    /// a comparison four integer compares instead of a `String` compare, and
    /// costs 32 bytes per blob instead of a heap allocation.
    ///
    /// Big-endian packing is order-preserving, so digest order, raw-byte order
    /// and hex-string order are all the same order.
    public struct Digest: Hashable, Comparable, Sendable, CustomStringConvertible {
        private let w0: UInt64
        private let w1: UInt64
        private let w2: UInt64
        private let w3: UInt64

        /// Decodes a 64-character hex digest. Accepts either case; `nil` for
        /// anything else.
        public init?(hex: String) {
            let utf8 = hex.utf8
            guard utf8.count == 64 else { return nil }

            var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            var index = 0
            for byte in utf8 {
                let nibble: UInt64
                switch byte {
                    case 0x30...0x39: nibble = UInt64(byte - 0x30)  // 0-9
                    case 0x61...0x66: nibble = UInt64(byte - 0x61 + 10)  // a-f
                    case 0x41...0x46: nibble = UInt64(byte - 0x41 + 10)  // A-F
                    default: return nil
                }
                // 16 hex characters per 64-bit word, most significant first.
                switch index >> 4 {
                    case 0: words.0 = (words.0 << 4) | nibble
                    case 1: words.1 = (words.1 << 4) | nibble
                    case 2: words.2 = (words.2 << 4) | nibble
                    default: words.3 = (words.3 << 4) | nibble
                }
                index += 1
            }

            (w0, w1, w2, w3) = words
        }

        /// The canonical lowercase-hex form, for mapping back to a file path via
        /// `KeepTalkingBlobStore.relativePath(for:)`.
        public var hexString: String {
            var scalars = [UInt8]()
            scalars.reserveCapacity(64)
            for word in [w0, w1, w2, w3] {
                var shift = 60
                while shift >= 0 {
                    let nibble = UInt8((word >> UInt64(shift)) & 0xF)
                    scalars.append(nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10)
                    shift -= 4
                }
            }
            return String(decoding: scalars, as: UTF8.self)
        }

        public var description: String { hexString }

        public static func < (lhs: Digest, rhs: Digest) -> Bool {
            if lhs.w0 != rhs.w0 { return lhs.w0 < rhs.w0 }
            if lhs.w1 != rhs.w1 { return lhs.w1 < rhs.w1 }
            if lhs.w2 != rhs.w2 { return lhs.w2 < rhs.w2 }
            return lhs.w3 < rhs.w3
        }
    }

    /// A blob record reduced to what storage reclamation needs: the digest to
    /// compare on, and the on-disk path its record claims.
    ///
    /// The path is carried separately because it encodes the file extension,
    /// which the digest alone does not determine — `KeepTalkingBlobStore` keys
    /// ready files by `prefix/hash.ext` and only partials by bare blob ID.
    public struct Reference: Hashable, Sendable {
        public let digest: Digest
        public let relativePath: String?

        public var blobID: String { digest.hexString }
    }

    /// Every blob `database` references, with its on-disk path, ascending by
    /// digest.
    ///
    /// Use this for the side of a comparison whose files you may delete, or to
    /// build a keep-set for `KeepTalkingBlobStore.pruneOrphanFiles`. When only
    /// the digests matter, prefer `referencedBlobIDs(on:)` — it reads one column.
    public static func references(
        on database: any Database
    ) async throws -> [Reference] {
        let records = try await KeepTalkingBlobRecord.query(on: database)
            .field(\.$id)
            .field(\.$relativePath)
            .all()

        var references = [Reference]()
        references.reserveCapacity(records.count)
        for record in records {
            guard let rawID = record.id else { continue }
            guard let digest = Digest(hex: rawID) else {
                throw KeepTalkingBlobReferenceIndexError.malformedBlobID(rawID)
            }
            references.append(
                Reference(digest: digest, relativePath: record.relativePath)
            )
        }

        references.sort { $0.digest < $1.digest }
        return references
    }

    /// Every blob file present on disk, in the same shape `references(on:)`
    /// returns — the file tree standing in for an index.
    ///
    /// This is what reclamation falls back to for an identity being deleted
    /// whose database cannot be read: the largest reference set that identity
    /// could possibly have is "every blob on this device". Taking it as the
    /// candidate set is what makes a broken store deletable — the candidates are
    /// still narrowed by every readable identity's own references before
    /// anything is removed.
    ///
    /// A file whose name is not a well-formed blob hash cannot be attributed to
    /// any identity, so it never becomes a candidate here. `pruneOrphanFiles` is
    /// the path that reclaims those.
    public static func references(
        inFileTreeOf store: KeepTalkingBlobStore
    ) -> [Reference] {
        var byDigest = [Digest: Reference]()
        for file in store.scanBlobFiles() {
            guard let digest = Digest(hex: file.blobID) else { continue }
            // A blob can be on disk twice — a promoted file plus a leftover
            // partial. Keep the ready path: `KeepTalkingBlobStore.remove` clears
            // the partial alongside it either way, and one reference per blob
            // keeps reclamation counts honest.
            if let existing = byDigest[digest],
                existing.relativePath?.hasPrefix("partial/") == false
            {
                continue
            }
            byDigest[digest] = Reference(digest: digest, relativePath: file.relativePath)
        }

        return byDigest.values.sorted { $0.digest < $1.digest }
    }

    /// Every blob ID `database` references, ascending and deduplicated.
    ///
    /// Reads the primary-key column alone rather than hydrating whole records.
    /// Throws on an unreadable blob ID instead of skipping it — a skipped
    /// reference would look like "nothing points at this file", which is the
    /// direction that deletes live bytes.
    public static func referencedBlobIDs(
        on database: any Database
    ) async throws -> [Digest] {
        let rawIDs = try await KeepTalkingBlobRecord.query(on: database)
            .all(\.$id)

        var digests = [Digest]()
        digests.reserveCapacity(rawIDs.count)
        for rawID in rawIDs {
            guard let digest = Digest(hex: rawID) else {
                throw KeepTalkingBlobReferenceIndexError.malformedBlobID(rawID)
            }
            digests.append(digest)
        }

        // Sorted in Swift rather than by the query. `blob_id` is the primary key
        // so SQLite could return it in order for free, but that order is its
        // TEXT collation over the *hex* form — which only matches digest order
        // while every stored ID is lowercase. Sorting the decoded values instead
        // makes the merge below correct regardless of how a row was written.
        digests.sort()
        return digests
    }

    /// Removes from `candidates` every digest `database` still references.
    ///
    /// Call once per surviving identity, releasing each store before opening the
    /// next; `candidates` only shrinks, so later identities do less work. What
    /// remains afterwards is referenced by none of the databases visited.
    ///
    /// Both sides are sorted, so this is a linear two-pointer merge compacting
    /// in place — no `Set`, no hashing, no allocation per identity.
    public static func subtractReferences(
        on database: any Database,
        from candidates: inout [Digest]
    ) async throws {
        guard !candidates.isEmpty else { return }
        let references = try await referencedBlobIDs(on: database)
        subtract(references, from: &candidates, digest: { $0 })
    }

    /// `subtractReferences(on:from:)` for candidates that carry their on-disk
    /// path — what identity deletion works with, since it has to remove files.
    public static func subtractReferences(
        on database: any Database,
        from candidates: inout [Reference]
    ) async throws {
        guard !candidates.isEmpty else { return }
        let references = try await referencedBlobIDs(on: database)
        subtract(references, from: &candidates, digest: \.digest)
    }

    /// Both inputs are sorted ascending, so this is a linear two-pointer merge.
    private static func subtract<Candidate>(
        _ references: [Digest],
        from candidates: inout [Candidate],
        digest: (Candidate) -> Digest
    ) {
        guard !references.isEmpty else { return }

        // Indexed rather than `for ... in candidates`: a for-in holds the
        // original buffer alive, so the first write would trigger a full
        // copy-on-write copy. `kept` never outruns `read`, so compacting into
        // the same buffer cannot clobber an element still to be read.
        var kept = 0
        var read = 0
        var referenceIndex = 0
        while read < candidates.count {
            let candidate = candidates[read]
            let candidateDigest = digest(candidate)
            read += 1

            while referenceIndex < references.count,
                references[referenceIndex] < candidateDigest
            {
                referenceIndex += 1
            }
            if referenceIndex < references.count,
                references[referenceIndex] == candidateDigest
            {
                continue
            }
            candidates[kept] = candidate
            kept += 1
        }
        candidates.removeLast(candidates.count - kept)
    }
}
