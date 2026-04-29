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

    public init(
        reasoning: AIReasoning? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        stop: [String]? = nil,
        seed: Int? = nil,
        responseFormat: AIResponseFormat? = nil,
        promptCacheKey: String? = nil,
        endUserID: String? = nil
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
    }

    public static let `default` = AITurnConfiguration()
}
