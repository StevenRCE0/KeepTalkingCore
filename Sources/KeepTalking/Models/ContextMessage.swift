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

    @Children(for: \.$parentMessage)
    public var attachments: [KeepTalkingContextAttachment]

    public init() {}

    public init(
        id: UUID = UUID.v7(),
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
    ///   `node` is the UUID of the node that ran the agent (nil if unknown).
    ///   `model` is the OpenAI model string (e.g. "gpt-4o", nil if unknown).
    public enum Sender: Codable, Sendable, Hashable {
        case node(node: UUID)
        case autonomous(name: String, node: UUID? = nil, model: String? = nil)

        public var nodeID: UUID? {
            if case .node(let id) = self { return id }
            return nil
        }
    }

    public enum MessageType: Codable, Sendable, Hashable {
        case message

        /// Reasoning / chain-of-thought emitted by the model on this turn. Stored
        /// alongside the assistant message so the UI can display the model's
        /// thinking, but excluded from agent-to-agent context replay.
        case thinking

        /// An in-progress tool-invocation hint surfaced during agent execution.
        ///
        /// - `hint`:         Human-readable label (e.g. "Inspecting").
        /// - `targetNodeID`: Raw UUID of the node that owns the action being called (nil for built-in tools).
        /// - `actionID`:     UUID of the action being called (nil for built-in tools).
        /// - `actionName`:   Display name of the action (not all peers have the action, so receivers
        ///                   may not be able to resolve it from `actionID` alone).
        /// - `sealedParameters`: The arguments the agent passed to the tool, sealed to the two ends
        ///                   of the call. This row replicates to every member of the context, but a
        ///                   command line or a file path is the caller's and the executor's business
        ///                   alone — so the hint stays legible to everyone while the arguments open
        ///                   only for those two. Seal with `KeepTalkingClient.sealCallParameters`,
        ///                   read with `openSealedCallParameters` (nil for anyone else).
        case intermediate(
            hint: String,
            targetNodeID: UUID? = nil,
            actionID: UUID? = nil,
            actionName: String? = nil,
            sealedParameters: Data? = nil
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

        /// Voice transcript produced by on-device speech recognition or a
        /// realtime API.  Content is the transcribed text.  The source
        /// distinguishes local ML (always-on passive transcription) from
        /// realtime API (wake-word-activated, higher fidelity).
        ///
        /// - `source`: How the transcript was produced.
        case transcript(source: TranscriptSource)

        /// User-visible status marker emitted when an agent run terminates
        /// abnormally — e.g. a connector error or a user-initiated cancel.
        /// Body text is a short generic string; the detailed error is shown
        /// on the failed queue entry in the composer, not in this message.
        case haywire(reason: HaywireReason)

        /// The sealed-call context entry — one low-volume chat entry per voice
        /// call, carrying the call's `sessionID`. The full transcript lives in
        /// `kt_voice_calls` / `kt_voice_transcript_lines` (read on demand); this
        /// is just the durable, syncable pointer + a summary in `content`. Like
        /// `.transcript` it's a deliberate chat surfacing: out of agent
        /// working-context (the `.message`-only filter) and skips wake. The
        /// message id is derived deterministically from the session id, so
        /// concurrent sealers across nodes converge on one entry.
        case voiceCallSeal(sessionID: UUID)
    }

    public enum TranscriptSource: String, Codable, Sendable, Hashable {
        /// On-device speech recognition (SFSpeechRecognizer).
        case local
        /// Server-side transcription from a realtime voice API.
        case realtime
    }

    public enum HaywireReason: String, Codable, Sendable, Hashable {
        case failed
        case cancelled
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

/// Size bounds on a single message.
public enum KeepTalkingMessageLimits {
    /// Ceiling on a message's content, enforced when the message is created.
    ///
    /// Transport no longer fragments envelopes, so an envelope that exceeds
    /// `PacketTransportCrypto.maxOutboundPayloadBytes` (1 MiB) simply cannot be
    /// sent — and, because a sync page carries whole items, cannot be
    /// replicated either. Refusing at creation is what keeps that from becoming
    /// a permanent condition: the alternative is a persisted row that retries
    /// forever in the outbox and stalls its own sync stream.
    ///
    /// Set to half the envelope ceiling because the check is on plaintext while
    /// the ceiling applies after sealing and base64/JSON framing, which inflate
    /// by roughly a third. The headroom also covers the rest of the envelope.
    public static let maximumContentBytes = 512 * 1024
}
