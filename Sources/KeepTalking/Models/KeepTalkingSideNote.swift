import FluentKit
import Foundation

public final class KeepTalkingSideNote: Model, @unchecked Sendable {
    public static let schema = "kt_side_notes"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "key")
    public var key: String

    @Field(key: "value")
    public var value: String

    @Field(key: "is_archived")
    public var isArchived: Bool

    /// Monotonic within a context. Allocated as `max(counter) + 1` at write
    /// time, inside the same transaction that writes the row.
    @Field(key: "version_counter")
    public var versionCounter: Int

    /// The node that made this write. Breaks counter ties deterministically so
    /// two partitioned nodes converge without consulting a clock.
    @Field(key: "version_writer")
    public var versionWriter: UUID

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    /// Internal: every write must allocate a version, which only
    /// `KeepTalkingClient`'s side-note API does. Constructing one directly
    /// would let a caller skip the bump and silently lose the next merge.
    init(
        id: UUID = UUID.v7(),
        contextID: UUID,
        key: String,
        value: String,
        isArchived: Bool = false,
        versionCounter: Int,
        versionWriter: UUID
    ) {
        self.id = id
        self.$context.id = contextID
        self.key = key
        self.value = value
        self.isArchived = isArchived
        self.versionCounter = versionCounter
        self.versionWriter = versionWriter
    }

    /// Writer stamped on rows that predate versioning. Always loses to a real
    /// write, because any real write allocates a higher counter.
    static let unknownWriter = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000")!

    var version: KeepTalkingSideNoteVersion {
        KeepTalkingSideNoteVersion(counter: versionCounter, writer: versionWriter)
    }
}

// MARK: - DTO

/// The wire shape of a side note.
///
/// No row `id` and no `contextID`: identity on the wire is `(context, key)`,
/// and the context is already established by the envelope carrying it. The old
/// DTO shipped both, which is how a losing merge ended up deleting and
/// recreating the local row to adopt the sender's id.
///
/// `value` is nil for an archived note — a tombstone ships its key and version
/// but not its content.
public struct KeepTalkingSideNoteDTO: Codable, Sendable, Equatable {
    public let key: String
    public let value: String?
    public let isArchived: Bool
    public let versionCounter: Int
    public let versionWriter: UUID
    public let createdAt: Date?
    public let updatedAt: Date?

    public var version: KeepTalkingSideNoteVersion {
        KeepTalkingSideNoteVersion(counter: versionCounter, writer: versionWriter)
    }

    public init(
        key: String,
        value: String?,
        isArchived: Bool,
        versionCounter: Int,
        versionWriter: UUID,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.value = value
        self.isArchived = isArchived
        self.versionCounter = versionCounter
        self.versionWriter = versionWriter
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(_ model: KeepTalkingSideNote) {
        self.key = model.key
        self.value = model.isArchived ? nil : model.value
        self.isArchived = model.isArchived
        self.versionCounter = model.versionCounter
        self.versionWriter = model.versionWriter
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
    }
}
