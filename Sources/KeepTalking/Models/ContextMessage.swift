import FluentKit
import Foundation

public final class KeepTalkingContextMessage: Model, Hashable, @unchecked Sendable {
    public static func == (lhs: KeepTalkingContextMessage, rhs: KeepTalkingContextMessage) -> Bool {
        guard lhs.id != nil, rhs.id != nil else {
            return false
        }
        return lhs.id == rhs.id
    }

    public static func deepEqual(lhs: KeepTalkingContextMessage, rhs: KeepTalkingContextMessage) -> Bool {
        lhs == rhs && lhs.$context.id == rhs.$context.id && lhs.sender == rhs.sender
            && lhs.content == rhs.content && lhs.timestamp == rhs.timestamp && lhs.type == rhs.type
            && lhs.agentTurnID == rhs.agentTurnID
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

    @OptionalField(key: "agent_turn_id")
    public var agentTurnID: UUID?

    public init() {}

    public init(
        id: UUID = UUID(),
        context: KeepTalkingContext,
        sender: Sender,
        content: String,
        timestamp: Date = Date(),
        type: MessageType = .message,
        agentTurnID: UUID? = nil
    ) {
        self.id = id
        self.$context.id = context.id!
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.type = type
        self.agentTurnID = agentTurnID
    }
}

extension KeepTalkingContextMessage {
    /// Who produced the message.
    ///
    /// - `node`: A peer node identified by UUID.
    /// - `autonomous`: An AI agent. `name` is the role label (e.g. "ai").
    ///   `nodeName` is the human-readable alias of the node that ran the agent (nil if unknown).
    ///   `model` is the OpenAI model string (e.g. "gpt-4o", nil if unknown).
    public enum Sender: Codable, Sendable, Hashable {
        case node(node: UUID)
        case autonomous(name: String, nodeName: String? = nil, model: String? = nil)
    }

    public enum MessageType: Codable, Sendable, Hashable {
        case message

        /// An in-progress tool-invocation hint surfaced during agent execution.
        ///
        /// - `hint`:         Human-readable label (e.g. "Inspecting").
        /// - `targetNodeID`: Raw UUID of the node that owns the action being called (nil for built-in tools).
        /// - `actionID`:     UUID of the action being called (nil for built-in tools).
        /// - `actionName`:   Display name of the action (not all peers have the action, so receivers
        ///                   may not be able to resolve it from `actionID` alone).
        /// - `parameters`:   Raw string-keyed arguments the agent passed to the tool.
        case intermediate(
            hint: String,
            targetNodeID: UUID? = nil,
            actionID: UUID? = nil,
            actionName: String? = nil,
            parameters: [String: String]? = nil
        )

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

        /// A suspended agent turn awaiting remote interaction.
        ///
        /// The agent persists this message when it hits a tool requiring
        /// `remote_authorisation` — then yields rather than blocking.
        ///
        /// - `toolCallID`:     The tool call being suspended.
        /// - `actionID`:       The action that triggered the suspension.
        /// - `targetNodeID`:   The node whose user must respond.
        /// - `kind`:           The continuation kind (e.g. "ask-for-file", "create-action").
        /// - `encryptedPayload`: Asym-encrypted request payload for the target node.
        /// - `state`:          Lifecycle state of this continuation.
        case agentTurnContinuation(
            toolCallID: String,
            actionID: UUID,
            targetNodeID: UUID,
            kind: String,
            encryptedPayload: Data,
            state: AgentTurnContinuationState = .pending
        )
    }

    /// Lifecycle state of an agent turn continuation.
    public enum AgentTurnContinuationState: String, Codable, Sendable, Hashable {
        /// Waiting for the remote user to respond.
        case pending
        /// The remote user responded; the agent turn can resume.
        case fulfilled
        /// The remote user rejected the request.
        case rejected
        /// The continuation expired or was cancelled.
        case cancelled
    }
}
