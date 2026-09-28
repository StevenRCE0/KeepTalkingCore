import Crypto
import Foundation

/// A side note's position in its context's write order.
///
/// Replaces wall-clock last-writer-wins. `counter` is monotonic within a
/// context; `writer` breaks ties between two nodes that allocated the same
/// counter while partitioned. Both sides of a partition compare the same pair
/// and reach the same answer, with no dependency on clock agreement.
public struct KeepTalkingSideNoteVersion: Sendable, Equatable, Comparable {
    public let counter: Int
    public let writer: UUID

    public init(counter: Int, writer: UUID) {
        self.counter = counter
        self.writer = writer
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.writer.uuidString.lowercased() < rhs.writer.uuidString.lowercased()
    }
}

/// Detection half of side-note sync.
///
/// A digest over `(key, counter, writer, archived)` for every note in a
/// context, tombstones included. Deliberately excludes `value`: the version
/// pair already changes on every write, so hashing content adds nothing but
/// makes the digest churn on data that is not part of the comparison.
///
/// Tombstones MUST be in the digest. With a whole-set exchange, a key that is
/// present locally and absent remotely is otherwise ambiguous between "we
/// created it and they have not seen it" and "they deleted it and we have not
/// seen that" — and those need opposite outcomes.
public enum KeepTalkingSideNoteDigest {
    /// Total order over the set, so the digest never depends on input order.
    ///
    /// Key alone is not enough. Swift's sort is not stable, so any pair the
    /// comparator calls equal can hash in either order — and two keys CAN
    /// compare equal while differing on the wire, because Swift's `String`
    /// equality is Unicode-canonical while SQLite's unique index is bytewise.
    /// One node hashing those two rows in the opposite order would disagree
    /// with its peer forever, on a set that is actually identical.
    private static func isOrderedBefore(
        _ lhs: KeepTalkingSideNoteDTO,
        _ rhs: KeepTalkingSideNoteDTO
    ) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.versionCounter != rhs.versionCounter {
            return lhs.versionCounter < rhs.versionCounter
        }
        return lhs.versionWriter.uuidString.lowercased()
            < rhs.versionWriter.uuidString.lowercased()
    }

    /// The digest's total order, shared with the page cursor so a paged set and
    /// its digest can never disagree about sequence.
    static func canonicallyOrdered(
        _ notes: [KeepTalkingSideNoteDTO]
    ) -> [KeepTalkingSideNoteDTO] {
        notes.sorted(by: isOrderedBefore)
    }

    public static func digest(of notes: [KeepTalkingSideNoteDTO]) -> Data {
        var hasher = SHA256()
        for note in canonicallyOrdered(notes) {
            hasher.update(data: Data(note.key.utf8))
            withUnsafeBytes(of: Int64(note.versionCounter).littleEndian) {
                hasher.update(data: Data($0))
            }
            hasher.update(
                data: Data(note.versionWriter.uuidString.lowercased().utf8))
            hasher.update(data: Data([note.isArchived ? 1 : 0]))
        }
        return Data(hasher.finalize())
    }
}

/// Position in a context's side-note set, for paging it.
///
/// The digest's total order, `(key, counter, writer)`, as a cursor. Key alone
/// cannot be one: two distinct keys can compare equal as Swift strings (see
/// `KeepTalkingSideNoteDigest.isOrderedBefore`), and a page boundary falling
/// between them would skip one.
public struct KeepTalkingSideNotePageKey: Codable, Sendable, Equatable, Comparable {
    public let key: String
    public let versionCounter: Int
    public let versionWriter: UUID

    public init(_ note: KeepTalkingSideNoteDTO) {
        key = note.key
        versionCounter = note.versionCounter
        versionWriter = note.versionWriter
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.versionCounter != rhs.versionCounter {
            return lhs.versionCounter < rhs.versionCounter
        }
        return lhs.versionWriter.uuidString.lowercased()
            < rhs.versionWriter.uuidString.lowercased()
    }
}

/// Bounds on what one note and one context may hold.
///
/// Side notes sync by exchanging the entire set when digests disagree, paged
/// like messages so the set never has to fit one envelope. These bounds keep
/// each note inside a page and keep a context's set, and so the exchange,
/// small; they no longer stand between the set and the transport ceiling.
public enum KeepTalkingSideNoteLimits {
    /// Cap on one note's value.
    public static let maximumValueBytes = 4 * 1024

    /// Cap on one note's key.
    public static let maximumKeyBytes = 256

    /// Cap on live (non-archived) notes in a context. Updating an existing note
    /// is always allowed — only creating a new one past the cap is refused.
    public static let maximumLiveNotes = 32

    /// Tombstones retained per context. Beyond this the oldest are deleted
    /// outright.
    ///
    /// Dropping a tombstone gives up the ability to distinguish "deleted" from
    /// "never seen" for that key, so a peer that still holds the live note and
    /// has been partitioned across more than this many archives can resurrect
    /// it. That is the standard tombstone-GC trade, taken knowingly: the
    /// alternative is a set, and a digest exchange, that grows without bound.
    public static let maximumTombstones = 96
}
