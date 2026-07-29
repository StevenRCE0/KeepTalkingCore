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

    public static func digest(of notes: [KeepTalkingSideNoteDTO]) -> Data {
        var hasher = SHA256()
        for note in notes.sorted(by: isOrderedBefore) {
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

/// Bounds that keep the whole-set exchange viable.
///
/// Side notes sync by sending the entire set when digests disagree. That is a
/// deliberately simple protocol — no paging, no per-key negotiation, no cursor
/// to get wrong — and it is correct precisely while the set stays small.
///
/// The set staying small used to be an assumption. Nothing capped a value,
/// nothing capped how many notes a context could hold, and archived notes lived
/// forever as tombstones, so the set could only grow. Past the transport budget
/// the responder attached nothing, and since a requester cannot tell "no notes
/// attached because we agree" from "no notes attached because I refused", side
/// notes stopped syncing permanently and silently.
///
/// These bounds make the assumption true instead. Every write is checked
/// against them and tombstones are pruned to fit, so the encoded set provably
/// cannot reach the budget: worst case is
/// `maximumLiveNotes × (maximumValueBytes + maximumKeyBytes + per-note framing)`
/// plus `maximumTombstones × (maximumKeyBytes + framing)`, which leaves room for
/// JSON escaping and still lands well under `maximumEncodedBytes`.
/// `sideNoteSetFitsItsBudgetWhenFull` pins that arithmetic down in a test.
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
    /// alternative is a set that grows without bound and eventually disables
    /// side-note sync for everyone, permanently.
    public static let maximumTombstones = 96

    /// Budget for the encoded set riding a summary result. Sits far below the
    /// transport's envelope ceiling so the result carrying it always fits.
    public static let maximumEncodedBytes = 256 * 1024
}
