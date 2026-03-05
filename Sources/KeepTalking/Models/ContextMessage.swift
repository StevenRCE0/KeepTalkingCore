import FluentKit
import Foundation

public final class KeepTalkingContextMessage: Model, @unchecked Sendable {
    public static let schema = "kt_context_messages"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Field(key: "sender")
    public var sender: Sender

    @Field(key: "content")
    public var content: String

    @Field(key: "timestamp")
    public var timestamp: Date

    @Field(key: "message_type")
    public var type: MessageType

    public init() {}

    public init(
        id: UUID = UUID(),
        context: KeepTalkingContext,
        sender: Sender,
        content: String,
        timestamp: Date = Date(),
        type: MessageType = .message
    ) {
        self.id = id
        self.$context.id = context.id!
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.type = type
    }
}

extension KeepTalkingContextMessage {
    public enum Sender: Codable, Sendable, Hashable {
        case node(node: UUID)
        case autonomous(name: String)
    }

    public enum MessageType: Codable, Sendable, Hashable {
        case message
        case intermediate(hint: String)
    }
}

public typealias KeepTalkingConversationMessage = KeepTalkingContextMessage
