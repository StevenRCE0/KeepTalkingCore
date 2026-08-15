import FluentKit
import Foundation

public enum KeepTalkingThreadState: String, Codable, Sendable, CaseIterable {
    /// The live, active tail of the conversation. Always exactly one per context.
    case contextMain
    /// A frozen segment committed by marking a turning point.
    case stored
    /// A frozen segment that has been archived.
    case archived
}

/// A thread as it travels between nodes.
///
/// Thread rows are local and directly editable, and their UUIDs, chitter-chatter
/// flags and semantic digests are all local concerns — so what syncs is this
/// projection: where a thread starts, where it ends, and what it is called.
/// A `nil` `endMessageID` is what marks the live thread, which is why state is
/// not carried separately.
public struct KeepTalkingThreadDTO: Codable, Sendable, Hashable {
    public var startMessageID: UUID
    public var endMessageID: UUID?
    public var topicName: String?

    public init(
        startMessageID: UUID,
        endMessageID: UUID? = nil,
        topicName: String? = nil
    ) {
        self.startMessageID = startMessageID
        self.endMessageID = endMessageID
        self.topicName = topicName
    }
}

public final class KeepTalkingThread: Model, @unchecked Sendable {
    public static let schema = "kt_threads"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    /// First message of the range. Nil only when the context has no messages yet.
    @OptionalParent(key: "start_message")
    public var startMessage: KeepTalkingContextMessage?

    /// Last message of the range (inclusive). Nil on a contextMain thread,
    /// meaning it always extends to the latest message.
    @OptionalParent(key: "end_message")
    public var endMessage: KeepTalkingContextMessage?

    @Field(key: "state")
    public var state: KeepTalkingThreadState

    /// A short human-readable summary of the thread's content.
    @OptionalField(key: "summary")
    public var summary: String?

    /// Message IDs within this thread's range that are marked as chitter-chatter.
    @Field(key: "chitter_chatter")
    public var chitterChatter: [UUID]

    /// Digest of the exact semantic document most recently committed to the
    /// local index. Nil or a mismatch means this persisted thread needs repair.
    @OptionalField(key: "semantic_document_digest")
    public var semanticDocumentDigest: String?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    /// Execution workspaces (isolated scratch/output dirs) owned by this thread —
    /// one per thread today, reaped when the thread is archived or deleted.
    @Children(for: \.$thread)
    public var workspaces: [KeepTalkingThreadWorkspace]

    public init() {}

    public init(
        id: UUID = UUID.v7(),
        context: KeepTalkingContext,
        startMessage: KeepTalkingContextMessage?,
        endMessage: KeepTalkingContextMessage?,
        state: KeepTalkingThreadState,
        chitterChatter: [UUID] = [],
        semanticDocumentDigest: String? = nil
    ) {
        self.id = id
        self.$context.id = context.id!
        self.$startMessage.id = startMessage?.id
        self.$endMessage.id = endMessage?.id
        self.state = state
        self.chitterChatter = chitterChatter
        self.semanticDocumentDigest = semanticDocumentDigest
    }
}
