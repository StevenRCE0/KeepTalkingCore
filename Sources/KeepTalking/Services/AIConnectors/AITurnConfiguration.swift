import AIProxy
import Foundation

// MARK: - AIReasoning

/// KT-owned reasoning configuration. Connector implementations translate this into
/// whatever shape their provider expects (OpenAI's `reasoning_effort`, OpenRouter's
/// `reasoning: { effort, max_tokens, exclude }`, Anthropic's `thinking.budget_tokens`,
/// Apple Intelligence's local-model knobs, etc.).
public struct AIReasoning: Sendable {
    public enum Effort: String, Sendable, Codable {
        case noReasoning
        case minimal
        case low
        case medium
        case high
        case xhigh
    }

    /// OpenAI-style reasoning effort. `nil` means "let the connector pick".
    public var effort: Effort?

    /// Hard cap on tokens spent on reasoning. Honoured by OpenRouter and
    /// Anthropic-via-router; ignored by direct OpenAI Chat Completions.
    public var maxTokens: Int?

    /// When `true`, ask the provider to omit reasoning text from the response.
    /// Defaults to `false` — KT generally wants thinking surfaced into the context.
    public var exclude: Bool

    public init(effort: Effort? = nil, maxTokens: Int? = nil, exclude: Bool = false) {
        self.effort = effort
        self.maxTokens = maxTokens
        self.exclude = exclude
    }

    /// Maps to AIProxy's `OpenAIChatCompletionRequestBody.ReasoningEffort` for
    /// connectors talking to the OpenAI Chat Completions shape.
    public var openAIEffort: OpenAIChatCompletionRequestBody.ReasoningEffort? {
        switch effort {
            case .none: return nil
            case .noReasoning: return .noReasoning
            case .minimal: return .minimal
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            case .xhigh: return .xhigh
        }
    }
}

// MARK: - AIResponseFormat

/// KT-owned response format. Connectors translate to provider shapes.
public enum AIResponseFormat: Sendable {
    case text
    case jsonObject
    case jsonSchema(
        name: String, description: String? = nil, schema: [String: AIProxyJSONValue]? = nil, strict: Bool? = nil)

    /// Maps to AIProxy's OpenAI-compatible response format.
    public var openAIResponseFormat: OpenAIChatCompletionRequestBody.ResponseFormat {
        switch self {
            case .text:
                return .text
            case .jsonObject:
                return .jsonObject
            case .jsonSchema(let name, let description, let schema, let strict):
                return .jsonSchema(name: name, description: description, schema: schema, strict: strict)
        }
    }
}

// MARK: - AITurnConfiguration

/// Holistic per-turn configuration that the orchestrator passes to every
/// `AIConnector.completeTurn` call. Connector implementations destructure this and
/// map each field to whatever their backend expects.
///
/// This is **KT-owned** rather than re-using AIProxy types directly because AIProxy
/// does not expose a unified protocol across providers — each provider has its own
/// request body shape. Sealing the config here keeps the protocol stable while the
/// fork tracks upstream changes.
/// Audio output configuration for turns targeting audio-capable models.
public struct AIAudioOutputConfig: Sendable {
    public var voice: String
    public var format: String

    public init(voice: String, format: String = "pcm16") {
        self.voice = voice
        self.format = format
    }
}

/// Boxed callback for streaming audio deltas. Wraps a `@Sendable` closure
/// in a reference type so `AITurnConfiguration` stays a value-type `Sendable`.
/// Connectors that support streaming audio call `emit(_:)` with each decoded
/// PCM chunk as it arrives from the SSE stream.
public final class AIStreamingAudioHandler: Sendable {
    private let handler: @Sendable (Data) async -> Void
    public init(_ handler: @escaping @Sendable (Data) async -> Void) {
        self.handler = handler
    }
    public func emit(_ chunk: Data) async {
        await handler(chunk)
    }
}

public struct AITurnConfiguration: Sendable {
    public var reasoning: AIReasoning?
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var stop: [String]?
    public var seed: Int?
    public var responseFormat: AIResponseFormat?
    public var promptCacheKey: String?
    public var endUserID: String?

    /// Output modalities requested for this turn (e.g. `["text", "audio"]`).
    /// When `nil`, the connector uses its default (text only).
    public var modalities: [String]?

    /// Audio output configuration. Requires `modalities` to include `"audio"`.
    public var audioOutput: AIAudioOutputConfig?

    /// When set, the connector emits decoded audio chunks in real time as
    /// they arrive from the SSE stream, rather than accumulating them.
    /// The final `AITurnResult.audioOutput` still contains the full audio.
    public var streamingAudioHandler: AIStreamingAudioHandler?

    public init(
        reasoning: AIReasoning? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        stop: [String]? = nil,
        seed: Int? = nil,
        responseFormat: AIResponseFormat? = nil,
        promptCacheKey: String? = nil,
        endUserID: String? = nil,
        modalities: [String]? = nil,
        audioOutput: AIAudioOutputConfig? = nil,
        streamingAudioHandler: AIStreamingAudioHandler? = nil
    ) {
        self.reasoning = reasoning
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.stop = stop
        self.seed = seed
        self.responseFormat = responseFormat
        self.promptCacheKey = promptCacheKey
        self.endUserID = endUserID
        self.modalities = modalities
        self.audioOutput = audioOutput
        self.streamingAudioHandler = streamingAudioHandler
    }

    public static let `default` = AITurnConfiguration()
}
