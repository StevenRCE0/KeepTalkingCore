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

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(),
        context: KeepTalkingContext,
        startMessage: KeepTalkingContextMessage?,
        endMessage: KeepTalkingContextMessage?,
        state: KeepTalkingThreadState,
        chitterChatter: [UUID] = []
    ) {
        self.id = id
        self.$context.id = context.id!
        self.$startMessage.id = startMessage?.id
        self.$endMessage.id = endMessage?.id
        self.state = state
        self.chitterChatter = chitterChatter
    }
}
