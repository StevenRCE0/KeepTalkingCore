import Foundation

/// A message's position in its context: `(timestamp, id)`, the order every
/// page, thread and sync cursor agrees on.
///
/// The timestamp is the seconds-since-1970 `Double` exactly as the store
/// holds it — not the `Date` Fluent decodes, which it rounds to the
/// microsecond. Keys come from the store (`KeepTalkingClient.messageKeys`),
/// so comparing one against a column in SQL is exact, and the store's
/// `ORDER BY timestamp, id` is this type's order: ids are stored as uppercase
/// hex text, and hex digits sort the same in either case.
public struct KeepTalkingMessageKey: Hashable, Comparable, Sendable, Codable {
    public let timestamp: Double
    public let id: UUID

    public init(timestamp: Double, id: UUID) {
        self.timestamp = timestamp
        self.id = id
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}

/// A cut between two rows of a context, named by the row beside it.
public enum KeepTalkingMessageBound: Sendable, Hashable {
    /// Before the first row.
    case start
    /// Just before this row: as a lower bound it includes the row, as an
    /// upper bound it excludes it.
    case before(KeepTalkingMessageKey)
    /// Just after this row: as a lower bound it excludes the row, as an
    /// upper bound it includes it.
    case after(KeepTalkingMessageKey)
    /// After the last row.
    case end

    /// Whether `key`'s row lies after this cut.
    func precedes(_ key: KeepTalkingMessageKey) -> Bool {
        switch self {
            case .start: true
            case .end: false
            case .before(let cut): cut <= key
            case .after(let cut): cut < key
        }
    }
}

/// The rows between two cuts. `.thread(start:end:)` is a thread's rows:
/// from its start row through its end row, or to the end of the context for
/// the live thread.
public struct KeepTalkingMessageRange: Sendable, Hashable {
    public var lower: KeepTalkingMessageBound
    public var upper: KeepTalkingMessageBound

    public init(lower: KeepTalkingMessageBound = .start, upper: KeepTalkingMessageBound = .end) {
        self.lower = lower
        self.upper = upper
    }

    public static let all = Self()

    public static func thread(start: KeepTalkingMessageKey, end: KeepTalkingMessageKey?) -> Self {
        Self(lower: .before(start), upper: end.map { .after($0) } ?? .end)
    }

    /// Rows strictly before `key`.
    public static func before(_ key: KeepTalkingMessageKey) -> Self {
        Self(lower: .start, upper: .before(key))
    }

    /// Rows strictly after `key`.
    public static func after(_ key: KeepTalkingMessageKey) -> Self {
        Self(lower: .after(key), upper: .end)
    }

    public func contains(_ key: KeepTalkingMessageKey) -> Bool {
        lower.precedes(key) && !upper.precedes(key)
    }

    /// This range cut down to the rows before `key`.
    public func before(_ key: KeepTalkingMessageKey) -> Self {
        Self(lower: lower, upper: .before(key))
    }

    /// This range cut down to the rows after `key`.
    public func after(_ key: KeepTalkingMessageKey) -> Self {
        Self(lower: .after(key), upper: upper)
    }
}

/// What a page fetch loads beside the message rows.
public enum KeepTalkingMessagePageAttachments: Sendable {
    /// Messages only; `message.attachments` is not loaded.
    case none
    /// Attachment rows, eager-loaded onto each message.
    case rows
    /// Attachment rows and the blob records they point at, so a window can
    /// resolve files without a second lookup.
    case rowsAndBlobRecords
}

/// Messages from a range, oldest first, with the exact keys the store holds
/// for them.
public struct KeepTalkingMessagePage: Sendable {
    public var messages: [KeepTalkingContextMessage]
    public var keysByID: [UUID: KeepTalkingMessageKey]
    /// Whether the range held more rows past the edge this page extended
    /// toward. Always false for a fetch by id.
    public var hasMore: Bool
    public var blobRecords: [String: KeepTalkingBlobRecord]

    public init(
        messages: [KeepTalkingContextMessage] = [],
        keysByID: [UUID: KeepTalkingMessageKey] = [:],
        hasMore: Bool = false,
        blobRecords: [String: KeepTalkingBlobRecord] = [:]
    ) {
        self.messages = messages
        self.keysByID = keysByID
        self.hasMore = hasMore
        self.blobRecords = blobRecords
    }

    public var firstKey: KeepTalkingMessageKey? {
        messages.first?.id.flatMap { keysByID[$0] }
    }

    public var lastKey: KeepTalkingMessageKey? {
        messages.last?.id.flatMap { keysByID[$0] }
    }
}
