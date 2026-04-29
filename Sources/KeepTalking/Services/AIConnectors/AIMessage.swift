import Foundation

// MARK: - AIMessage
//
// KT-native message type used by `AIConnector`. The orchestrator and skill
// loops build histories of `AIMessage` and pass them to the connector; each
// connector translates to its vendor's wire shape internally. The SDK never
// constructs vendor types at the call site — adding a provider means adding
// one connector and zero upstream changes.

public struct AIMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        /// System instructions / persona / rules. Connectors targeting providers
        /// without a system role (Anthropic) hoist these into a top-level field.
        case system
        /// End-user input.
        case user
        /// Model output (text and/or tool-call requests).
        case assistant
        /// Result of executing a tool the assistant requested. `toolCallID` is
        /// required so the provider can match it back to the original call.
        case tool
    }

    public let role: Role

    /// Message body. `nil` is allowed for assistant turns that consist entirely
    /// of tool calls.
    public let content: Content?

    /// Tool calls emitted by the assistant on this turn. Empty for non-assistant
    /// roles. Each call carries its own ID so subsequent `tool` results can
    /// reference it.
    public let toolCalls: [AIToolCall]

    /// For `role == .tool`, identifies which assistant tool call this message
    /// is the result of. Required for tool turns; ignored otherwise.
    public let toolCallID: String?

    /// Optional participant name. Some providers expose this for multi-agent
    /// transcripts; most ignore it. Connectors are free to drop it.
    public let name: String?

    public init(
        role: Role,
        content: Content?,
        toolCalls: [AIToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }
}

// MARK: - Content

extension AIMessage {
    /// Message body. Plain text is the common case; `parts` is used when a
    /// single message mixes text with images or other modalities (currently
    /// only image URLs are modelled — extend `Part` when audio/files are added).
    public enum Content: Sendable, Equatable {
        case text(String)
        case parts([Part])

        /// The plain-text projection of the content, suitable for providers
        /// that only accept a string body (most). Image parts are dropped;
        /// callers that need vision must handle `.parts` explicitly.
        public var text: String {
            switch self {
                case .text(let s): return s
                case .parts(let parts):
                    return parts.compactMap { part -> String? in
                        if case .text(let s) = part { return s }
                        return nil
                    }.joined(separator: "\n")
            }
        }
    }

    public enum Part: Sendable, Equatable {
        case text(String)
        /// An image, expressed as a URL. Data: URLs (base64-encoded image
        /// bytes) are valid here — that's how attachments are typically
        /// inlined for vision models.
        case imageURL(URL)
    }
}

// MARK: - Convenience constructors

extension AIMessage {
    public static func system(_ text: String, name: String? = nil) -> AIMessage {
        .init(role: .system, content: .text(text), name: name)
    }

    public static func user(_ text: String, name: String? = nil) -> AIMessage {
        .init(role: .user, content: .text(text), name: name)
    }

    public static func user(parts: [Part], name: String? = nil) -> AIMessage {
        .init(role: .user, content: .parts(parts), name: name)
    }

    /// Assistant turn that produced text only (no tool calls).
    public static func assistant(_ text: String?, name: String? = nil) -> AIMessage {
        .init(
            role: .assistant,
            content: text.map { .text($0) },
            toolCalls: [],
            name: name
        )
    }

    /// Assistant turn that produced one or more tool calls (and possibly text).
    public static func assistantToolCalls(
        _ toolCalls: [AIToolCall],
        text: String? = nil,
        name: String? = nil
    ) -> AIMessage {
        .init(
            role: .assistant,
            content: text.map { .text($0) },
            toolCalls: toolCalls,
            name: name
        )
    }

    /// Tool-result message. `toolCallID` must match the assistant call's ID.
    public static func tool(
        _ text: String,
        toolCallID: String,
        name: String? = nil
    ) -> AIMessage {
        .init(
            role: .tool,
            content: .text(text),
            toolCallID: toolCallID,
            name: name
        )
    }
}

// MARK: - AIToolCall

/// One function call emitted by the model. KT-native — each connector translates
/// to its vendor's tool-call shape on the way out, and back into this on the way in.
public struct AIToolCall: Sendable, Equatable, Hashable {
    /// Provider-issued call ID. Echoed back verbatim in the matching tool result.
    public let id: String

    /// Function name the model wants invoked.
    public let name: String

    /// Raw JSON-encoded argument blob, exactly as the provider returned it.
    /// Tool dispatchers parse this on demand.
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

// MARK: - AIToolChoice

/// KT-native tool-choice setting. Connectors translate to their provider's enum.
public enum AIToolChoice: Sendable, Equatable {
    /// Model decides whether to call a tool.
    case auto
    /// Model must not call any tool.
    case none
    /// Model must call _some_ tool (provider's choice).
    case required
    /// Model must call this specific function.
    case specific(name: String)
}
