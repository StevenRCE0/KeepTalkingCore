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

    public init() {}

    public init(
        id: UUID = UUID(),
        context: KeepTalkingContext,
        sender: Sender,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.$context.id = context.id!
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
    }
}

public extension KeepTalkingContextMessage {
    enum Sender: Codable, Sendable, Hashable {
        case node(node: UUID)
        case autonomous(name: String)
    }
}

public typealias KeepTalkingConversationMessage = KeepTalkingContextMessage
