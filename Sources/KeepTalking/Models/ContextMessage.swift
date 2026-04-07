import FluentKit
import Foundation

public final class KeepTalkingContextMessage: Model, Hashable, @unchecked Sendable {
    public static func == (lhs: KeepTalkingContextMessage, rhs: KeepTalkingContextMessage) -> Bool {
        guard lhs.id != nil, rhs.id != nil else {
            return false
        }
        return lhs.id == rhs.id && lhs.$context.id == rhs.$context.id && lhs.sender == rhs.sender
            && lhs.content == rhs.content && lhs.timestamp == rhs.timestamp && lhs.type == rhs.type
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine($context.id)
        hasher.combine(sender)
        hasher.combine(type)
        hasher.combine(content)
    }

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
        /// Stored by an AI agent to label the current live thread or to signal
        /// a topic shift. `previousTopicName` names the thread that just ended.
        /// `currentTopicName` names the live thread that starts at `messageID`.
        case markTurningPoint(
            messageID: UUID,
            previousTopicName: String?,
            currentTopicName: String
        )
        /// Stored by an AI agent to flag a message as noise. Consumed locally
        /// to set chitter-chatter on the referenced message.
        case markChitterChatter(messageID: UUID)

        private struct CodingKeys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }

            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }

            static let message = Self(stringValue: "message")!
            static let intermediate = Self(stringValue: "intermediate")!
            static let markTurningPoint = Self(stringValue: "markTurningPoint")!
            static let markChitterChatter = Self(
                stringValue: "markChitterChatter"
            )!
            static let hint = Self(stringValue: "hint")!
            static let messageID = Self(stringValue: "messageID")!
            static let previousTopicName = Self(
                stringValue: "previousTopicName"
            )!
            static let currentTopicName = Self(
                stringValue: "currentTopicName"
            )!
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.message) {
                self = .message
                return
            }

            if container.contains(.intermediate) {
                let nested = try container.nestedContainer(
                    keyedBy: CodingKeys.self,
                    forKey: .intermediate
                )
                self = .intermediate(
                    hint: try nested.decode(String.self, forKey: .hint)
                )
                return
            }

            if container.contains(.markTurningPoint) {
                let nested = try container.nestedContainer(
                    keyedBy: CodingKeys.self,
                    forKey: .markTurningPoint
                )
                let messageID = try nested.decode(
                    UUID.self,
                    forKey: .messageID
                )
                let previousTopicName = try nested.decodeIfPresent(
                    String.self,
                    forKey: .previousTopicName
                )
                let currentTopicName =
                    try nested.decodeIfPresent(
                        String.self,
                        forKey: .currentTopicName
                    )
                    ?? previousTopicName
                    ?? ""
                self = .markTurningPoint(
                    messageID: messageID,
                    previousTopicName: previousTopicName,
                    currentTopicName: currentTopicName
                )
                return
            }

            if container.contains(.markChitterChatter) {
                let nested = try container.nestedContainer(
                    keyedBy: CodingKeys.self,
                    forKey: .markChitterChatter
                )
                self = .markChitterChatter(
                    messageID: try nested.decode(
                        UUID.self,
                        forKey: .messageID
                    )
                )
                return
            }

            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown KeepTalkingContextMessage.MessageType"
                )
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
                case .message:
                    _ = container.nestedContainer(
                        keyedBy: CodingKeys.self,
                        forKey: .message
                    )
                case .intermediate(let hint):
                    var nested = container.nestedContainer(
                        keyedBy: CodingKeys.self,
                        forKey: .intermediate
                    )
                    try nested.encode(hint, forKey: .hint)
                case .markTurningPoint(
                    let messageID,
                    let previousTopicName,
                    let currentTopicName
                ):
                    var nested = container.nestedContainer(
                        keyedBy: CodingKeys.self,
                        forKey: .markTurningPoint
                    )
                    try nested.encode(messageID, forKey: .messageID)
                    try nested.encodeIfPresent(
                        previousTopicName,
                        forKey: .previousTopicName
                    )
                    try nested.encode(
                        currentTopicName,
                        forKey: .currentTopicName
                    )
                case .markChitterChatter(let messageID):
                    var nested = container.nestedContainer(
                        keyedBy: CodingKeys.self,
                        forKey: .markChitterChatter
                    )
                    try nested.encode(messageID, forKey: .messageID)
            }
        }
    }
}

public typealias KeepTalkingConversationMessage = KeepTalkingContextMessage
