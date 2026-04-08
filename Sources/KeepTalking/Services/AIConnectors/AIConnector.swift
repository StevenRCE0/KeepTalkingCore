import Foundation
import OpenAI

// MARK: - AITurnResult

/// The result of a single AI turn: optional assistant text and/or tool-call requests.
public struct AITurnResult: Sendable {
    public let assistantText: String?
    public let toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]

    public init(
        assistantText: String?,
        toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]
    ) {
        self.assistantText = assistantText
        self.toolCalls = toolCalls
    }
}

// MARK: - AIConnectorCapabilities

/// Describes the feature set of an AI backend.
public struct AIConnectorCapabilities: Sendable {
    /// Whether the model natively supports tool calling (e.g. OpenAI's `tools` parameter).
    /// When `false`, the agent loop may use explicit XML prompting as a fallback.
    public let supportsNativeToolCalling: Bool

    public init(supportsNativeToolCalling: Bool) {
        self.supportsNativeToolCalling = supportsNativeToolCalling
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
/// Implementations may delegate to OpenAI, an on-device Apple Intelligence model,
/// or any other LLM provider that can translate the OpenAI message/tool format.
///
/// We might migrate the tool normalisation to the turn runner in the future.
public protocol AIConnector: Actor, Sendable {
    /// The API compatibility mode. Used to determine which input modalities are safe to send
    /// (e.g. native PDF file inputs are only supported in `.responses` mode).
    nonisolated var apiMode: OpenAIAPIMode { get }

    /// The feature set of this connector.
    nonisolated var capabilities: AIConnectorCapabilities { get }

    /// Perform one turn of the agent loop: given a message history and an optional tool set,
    /// return the model's response (text and/or tool calls).
    ///
    /// - Parameters:
    ///   - messages: The full conversation history in OpenAI chat-completion format.
    ///   - tools: The tools the model may choose to call.
    ///   - model: A hint at which model to use (implementations may ignore this).
    ///   - toolChoice: Whether/how the model should pick a tool.
    ///   - stage: The current orchestrator stage (planning/execution).
    ///   - toolExecutor: An optional executor for running tools natively during the turn (e.g. for Apple Intelligence native loops).
    func completeTurn(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        stage: AIStage,
        toolExecutor: (
            @Sendable ([ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]) async throws ->
                [ChatQuery.ChatCompletionMessageParam.ToolMessageParam]
        )?
    ) async throws -> AITurnResult
}
