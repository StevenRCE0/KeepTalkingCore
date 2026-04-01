import FluentKit
import Foundation

public final class KeepTalkingOperatorContext: Model, @unchecked Sendable {
    public static let schema = "kt_operator_context"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "operator")
    public var `operator`: KeepTalkingNode

    @Parent(key: "context")
    public var context: KeepTalkingContext

    public init() {}

    public init(
        id: UUID? = UUID(),
        `operator`: KeepTalkingNode,
        context: KeepTalkingContext
    ) {
        self.id = id
        self.operator = `operator`
        self.context = context
    }
}

public final class KeepTalkingContext: Model, Equatable, Hashable,
    @unchecked Sendable
{
    public static func == (lhs: KeepTalkingContext, rhs: KeepTalkingContext)
        -> Bool
    {
        if lhs.id == nil && rhs.id == nil {
            return false
        }
        return lhs.id == rhs.id
    }

    public static let schema = "kt_contexts"

    @ID(key: .id)
    public var id: UUID?

    @Siblings(
        through: KeepTalkingOperatorContext.self,
        from: \.$context,
        to: \.$operator
    )
    public var operators: [KeepTalkingNode]

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @OptionalField(key: "sync_metadata")
    public var syncMetadata: KeepTalkingContextSyncMetadata?

    /// IDs of mark messages (type markTurningPoint / markChitterChatter) that
    /// this node has already consumed. Local-only — not propagated by sync.
    @OptionalField(key: "consumed_marks")
    public var consumedMarks: [UUID]?

    @Children(for: \.$context)
    public var messages: [KeepTalkingContextMessage]

    @Children(for: \.$context)
    public var attachments: [KeepTalkingContextAttachment]

    @Children(for: \.$context)
    public var threads: [KeepTalkingThread]

    public init() {}

    public init(
        id: UUID = UUID(),
        updatedAt: Date = Date(),
        messages: [KeepTalkingContextMessage] = [],
        attachments: [KeepTalkingContextAttachment] = []
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.syncMetadata = nil
        self.$messages.value = messages
        self.$attachments.value = attachments
    }

    /// The Hasher protocol is merely satisfied by the ID, no message comparison logic.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension KeepTalkingContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case updatedAt
        case messages
        case attachments
    }

    public convenience init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let updatedAt =
            try container.decodeIfPresent(
                Date.self,
                forKey: .updatedAt
            ) ?? Date()
        self.init(
            id: id,
            updatedAt: updatedAt
        )
        self.$messages.value =
            try container.decodeIfPresent(
                [KeepTalkingContextMessage].self,
                forKey: .messages
            ) ?? []
        self.$attachments.value =
            try container.decodeIfPresent(
                [KeepTalkingContextAttachment].self,
                forKey: .attachments
            ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode($messages.value ?? [], forKey: .messages)
        try container.encode($attachments.value ?? [], forKey: .attachments)
    }
}

public typealias KeepTalkingConversationContext = KeepTalkingContext
