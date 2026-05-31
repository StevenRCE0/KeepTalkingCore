import Foundation

// MARK: - AITurnResult

/// Audio output from an AI turn — decoded PCM/WAV bytes, transcript, and
/// an opaque ID for multi-turn audio references.
public struct AIAudioOutput: Sendable {
    public let id: String?
    public let data: Data?
    public let transcript: String?
    public let expiresAt: Int?

    public init(id: String? = nil, data: Data? = nil, transcript: String? = nil, expiresAt: Int? = nil) {
        self.id = id
        self.data = data
        self.transcript = transcript
        self.expiresAt = expiresAt
    }
}

/// The result of a single AI turn: optional assistant text, optional reasoning
/// content, any tool-call requests, and optional audio output.
public struct AITurnResult: Sendable {
    public let assistantText: String?
    /// The model's reasoning / chain-of-thought, when the provider returns it
    /// (OpenRouter, DeepSeek, Anthropic extended thinking). Connectors that
    /// can't surface reasoning leave this `nil`. The orchestrator decides
    /// whether to publish it into the conversation context.
    public let thinking: String?
    public let toolCalls: [AIToolCall]
    /// Audio output from audio-capable models. Present when the turn was
    /// configured with `modalities: ["audio"]` and the model produced audio.
    public let audioOutput: AIAudioOutput?

    public init(
        assistantText: String?,
        thinking: String? = nil,
        toolCalls: [AIToolCall],
        audioOutput: AIAudioOutput? = nil
    ) {
        self.assistantText = assistantText
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.audioOutput = audioOutput
    }
}

// MARK: - AIConnectorCapabilities

/// Describes the feature set of an AI backend.
public struct AIConnectorCapabilities: Sendable {
    /// Whether the model natively supports tool calling (e.g. OpenAI's `tools` parameter).
    /// When `false`, the agent loop may use explicit XML prompting as a fallback.
    public let supportsNativeToolCalling: Bool

    /// Whether this connector can return reasoning content (`AITurnResult.thinking`).
    /// When `false`, callers should not expect thinking output even if a reasoning
    /// model is requested.
    public let supportsThinking: Bool

    public init(supportsNativeToolCalling: Bool, supportsThinking: Bool = false) {
        self.supportsNativeToolCalling = supportsNativeToolCalling
        self.supportsThinking = supportsThinking
    }
}

// MARK: - AIStage

/// The current stage of an AI turn in the orchestrator.
public enum AIStage: Sendable {
    /// The model should focus on choosing tools to perform actions or fetch context.
    case planning
    /// The model should provide a final natural-language answer to the user.
    case execution
}

// MARK: - AIConnector

/// A backend that can drive the KeepTalking AI agent loop.
///
/// Connectors speak KT-native types — `AIMessage`, `KeepTalkingActionToolDefinition`,
/// `AIToolCall`, `AIToolChoice` — and translate to their provider's wire format
/// internally. The SDK never builds vendor types at the call site; that means a
/// new provider plugs in by adding one connector and zero upstream changes.
///
/// Per-turn configuration flows through a single `AITurnConfiguration` value so
/// callers don't need to know about provider-specific knobs (effort enums,
/// thinking-token budgets, etc.). Connectors map the relevant fields to their
/// provider's wire format and ignore the rest.
public protocol AIConnector: Actor, Sendable {
    /// The feature set of this connector.
    nonisolated var capabilities: AIConnectorCapabilities { get }

    /// Perform one turn of the agent loop: given a message history and an optional
    /// tool set, return the model's response (text, reasoning, and/or tool calls).
    ///
    /// - Parameters:
    ///   - messages: The full conversation history in KT-native form.
    ///   - tools: The KT action/tool definitions the model may choose to call.
    ///            Each connector translates these to its vendor's tool shape.
    ///   - model: The model identifier the connector should target. Implementations
    ///            may map this onto provider-specific naming (e.g. OpenRouter's
    ///            `openai/gpt-4o-mini`).
    ///   - toolChoice: Whether/how the model should pick a tool.
    ///   - stage: The current orchestrator stage (planning/execution).
    ///   - configuration: Provider-agnostic per-turn configuration. `nil` means the
    ///                    connector picks its defaults.
    ///   - toolExecutor: An optional executor for running tools natively during the
    ///                   turn (e.g. for Apple Intelligence native loops). Returns
    ///                   the resulting `.tool` messages, one per call.
    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (
            @Sendable ([AIToolCall]) async throws -> [AIMessage]
        )?
    ) async throws -> AITurnResult
}

// MARK: - Convenience overload (no explicit configuration)

extension AIConnector {
    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        toolExecutor: (
            @Sendable ([AIToolCall]) async throws -> [AIMessage]
        )? = nil
    ) async throws -> AITurnResult {
        try await completeTurn(
            messages: messages,
            tools: tools,
            model: model,
            toolChoice: toolChoice,
            stage: stage,
            configuration: nil,
            toolExecutor: toolExecutor
        )
    }
}
