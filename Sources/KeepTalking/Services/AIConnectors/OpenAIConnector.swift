import AIProxy
import Foundation

/// Backend selection for the connector. Each case is an OpenAI-compatible
/// `/v1/chat/completions` endpoint — they differ only in the base URL and any
/// vendor-specific defaults the connector applies.
public enum OpenAIConnectorBackend: Sendable {
    /// OpenRouter's OpenAI-compatible endpoint.
    /// Default base URL: `https://openrouter.ai/api`.
    case openRouter
    /// OpenAI directly.
    /// Default base URL: `https://api.openai.com`.
    case openAI
    /// A custom base URL serving the OpenAI Chat Completions shape.
    /// `baseURL` is the host root (e.g. `https://api.example.com`); the connector
    /// appends `/v1/chat/completions`.
    case custom(baseURL: String)
}

public actor OpenAIConnector: AIConnector {
    public static func keepTalkingSystemPrompt(
        ktRunActionToolFunctionName: String,
        ktSkillMetainfoToolFunctionName: String,
        attachmentListingToolFunctionName: String,
        attachmentReaderToolFunctionName: String,
        searchThreadsToolFunctionName: String,
        markTurningPointToolFunctionName: String,
        markChitterChatterToolFunctionName: String,
        currentPromptIncludesAttachments: Bool,
        currentPromptShouldAvoidAutomaticToolUse: Bool,
        contextTranscript: String,
        currentDate: String,
        platform: String
    ) -> String {
        AIPromptPresets.systemPrompt(
            ktRunActionToolFunctionName: ktRunActionToolFunctionName,
            ktSkillMetainfoToolFunctionName: ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName: attachmentListingToolFunctionName,
            attachmentReaderToolFunctionName: attachmentReaderToolFunctionName,
            searchThreadsToolFunctionName: searchThreadsToolFunctionName,
            markTurningPointToolFunctionName: markTurningPointToolFunctionName,
            markChitterChatterToolFunctionName: markChitterChatterToolFunctionName,
            currentPromptIncludesAttachments: currentPromptIncludesAttachments,
            currentPromptShouldAvoidAutomaticToolUse: currentPromptShouldAvoidAutomaticToolUse,
            contextTranscript: contextTranscript,
            currentDate: currentDate,
            platform: platform
        )
    }

    public enum ConnectorError: Error, LocalizedError {
        case missingAPIKey
        case invalidEndpoint(String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
                case .missingAPIKey:
                    return "No API key provided. Set OPENROUTER_API_KEY (or OPENAI_API_KEY) or pass apiKey explicitly."
                case .invalidEndpoint(let raw):
                    return "Invalid endpoint URL: \(raw)"
                case .emptyResponse:
                    return "No response choices received from the model."
            }
        }
    }

    private let service: OpenAIService
    private let apiKey: String
    private let modelsURL: URL
    public nonisolated let capabilities: AIConnectorCapabilities = .init(
        supportsNativeToolCalling: true,
        supportsThinking: true
    )

    /// Default request timeout in seconds.
    private static let defaultTimeoutSeconds: UInt = 60

    /// Construct a connector for the given backend.
    ///
    /// - Parameters:
    ///   - apiKey: A BYOK API key. If `nil`, the connector reads
    ///             `OPENROUTER_API_KEY`, falling back to `OPENAI_API_KEY`.
    ///   - endpoint: Optional override for the host root. If `nil`, falls back to
    ///               environment variables and finally the backend's default URL.
    ///   - backend: Which provider/endpoint shape to target. Defaults to OpenRouter.
    public init(
        apiKey: String? = nil,
        endpoint: String? = nil,
        backend: OpenAIConnectorBackend = .openRouter
    ) throws {
        guard
            let key = apiKey
                ?? ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !key.isEmpty
        else {
            throw ConnectorError.missingAPIKey
        }

        let resolvedEndpointString: String
        if let endpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedEndpointString = endpoint
        } else if let envEndpoint = Self.envEndpoint(for: backend) {
            resolvedEndpointString = envEndpoint
        } else {
            resolvedEndpointString = backend.defaultBaseURL
        }

        guard
            let endpointURL = URL(string: resolvedEndpointString),
            endpointURL.host != nil
        else {
            throw ConnectorError.invalidEndpoint(resolvedEndpointString)
        }

        self.apiKey = key
        self.service = AIProxy.openAIDirectService(
            unprotectedAPIKey: key,
            baseURL: endpointURL.absoluteString
        )
        self.modelsURL = endpointURL.appendingPathComponent("v1/models")
    }

    // MARK: - listModels

    public func listModels() async throws -> [String] {
        struct ModelItem: Decodable { let id: String }
        struct ModelList: Decodable { let data: [ModelItem] }
        struct APIErrorDetail: Decodable { let message: String }
        struct APIErrorWrapper: Decodable { let error: APIErrorDetail }

        var request = URLRequest(url: modelsURL, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard statusCode == 200 else {
            let message =
                (try? JSONDecoder().decode(APIErrorWrapper.self, from: data))
                .map(\.error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw AIProxyError.unsuccessfulRequest(
                statusCode: statusCode,
                responseBody: message
            )
        }
        let result = try JSONDecoder().decode(ModelList.self, from: data)
        return result.data.map(\.id).sorted()
    }

    // MARK: - completeTurn

    public func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice? = nil,
        stage: AIStage,
        configuration: AITurnConfiguration? = nil,
        toolExecutor: (
            @Sendable ([AIToolCall]) async throws -> [AIMessage]
        )? = nil
    ) async throws -> AITurnResult {
        let openAIMessages = messages.map(Self.translateMessage(_:))
        let openAITools = tools.map(Self.translateTool(_:))
        let resolvedToolChoice: OpenAIChatCompletionRequestBody.ToolChoice? = {
            if openAITools.isEmpty { return nil }
            if let toolChoice { return Self.translateToolChoice(toolChoice) }
            return .auto
        }()

        let body = OpenAIChatCompletionRequestBody(
            model: model,
            messages: openAIMessages,
            maxCompletionTokens: configuration?.maxOutputTokens,
            promptCacheKey: configuration?.promptCacheKey,
            reasoningEffort: configuration?.reasoning?.openAIEffort,
            responseFormat: configuration?.responseFormat?.openAIResponseFormat,
            seed: configuration?.seed,
            stop: configuration?.stop,
            temperature: configuration?.temperature,
            tools: openAITools.isEmpty ? nil : openAITools,
            toolChoice: resolvedToolChoice,
            topP: configuration?.topP,
            user: configuration?.endUserID
        )

        // Run the HTTP call in a child task so cancellation can be propagated
        // to AIProxy's URLSession data task on parent cancel — without this,
        // `entry.task.cancel()` only sets a flag and the request keeps
        // streaming until its 60s timeout.
        let request = Task<OpenAIChatCompletionResponseBody, Error> {
            try await service.chatCompletionRequest(
                body: body,
                secondsToWait: Self.defaultTimeoutSeconds
            )
        }
        let response: OpenAIChatCompletionResponseBody
        do {
            response = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
        } catch is CancellationError {
            request.cancel()
            throw CancellationError()
        }

        var turnText: String? = nil
        var turnThinking: String? = nil
        var turnToolCalls: [AIToolCall] = []

        for choice in response.choices {
            let text = choice.message.content
            if let text, !text.isEmpty {
                turnText = turnText.map { "\($0)\n\(text)" } ?? text
            }
            if let reasoning = choice.message.reasoning, !reasoning.isEmpty {
                turnThinking = turnThinking.map { "\($0)\n\(reasoning)" } ?? reasoning
            }
            if let calls = choice.message.toolCalls {
                turnToolCalls.append(
                    contentsOf: calls.map { call in
                        AIToolCall(
                            id: call.id,
                            name: call.function.name,
                            argumentsJSON: call.function.argumentsRaw ?? "{}"
                        )
                    })
            }
        }

        if turnText == nil, turnThinking == nil, turnToolCalls.isEmpty {
            throw ConnectorError.emptyResponse
        }

        return AITurnResult(
            assistantText: turnText,
            thinking: turnThinking,
            toolCalls: turnToolCalls
        )
    }

    // MARK: - private translation

    private static func translateMessage(
        _ message: AIMessage
    ) -> OpenAIChatCompletionRequestBody.Message {
        switch message.role {
            case .system:
                return .system(
                    content: .text(message.content?.text ?? ""),
                    name: message.name
                )
            case .user:
                return .user(
                    content: translateUserContent(message.content),
                    name: message.name
                )
            case .assistant:
                let toolCalls: [OpenAIChatCompletionRequestBody.Message.ToolCall]? =
                    message.toolCalls.isEmpty
                    ? nil
                    : message.toolCalls.map { call in
                        .init(
                            id: call.id,
                            function: .init(
                                name: call.name,
                                arguments: call.argumentsJSON
                            )
                        )
                    }
                // Assistant messages don't take multimodal content; collapse to text.
                let content: OpenAIChatCompletionRequestBody.Message.MessageContent<String, [String]>? =
                    message.content.map { .text($0.text) }
                return .assistant(
                    content: content,
                    name: message.name,
                    refusal: nil,
                    toolCalls: toolCalls
                )
            case .tool:
                return .tool(
                    content: .text(message.content?.text ?? ""),
                    toolCallID: message.toolCallID ?? ""
                )
        }
    }

    /// Translates `AIMessage.Content` into the user-message content shape that
    /// supports OpenAI's vision parts.
    private static func translateUserContent(
        _ content: AIMessage.Content?
    )
        -> OpenAIChatCompletionRequestBody.Message.MessageContent<
            String,
            [OpenAIChatCompletionRequestBody.Message.ContentPart]
        >
    {
        switch content {
            case .none:
                return .text("")
            case .text(let s):
                return .text(s)
            case .parts(let parts):
                let translated = parts.map { part -> OpenAIChatCompletionRequestBody.Message.ContentPart in
                    switch part {
                        case .text(let s): return .text(s)
                        case .imageURL(let url): return .imageURL(url, detail: nil)
                    }
                }
                return .parts(translated)
        }
    }

    private static func translateTool(
        _ tool: KeepTalkingActionToolDefinition
    ) -> OpenAIChatCompletionRequestBody.Tool {
        .function(
            name: tool.functionName,
            description: tool.description,
            parameters: tool.parameters,
            strict: false
        )
    }

    private static func translateToolChoice(
        _ choice: AIToolChoice
    ) -> OpenAIChatCompletionRequestBody.ToolChoice {
        switch choice {
            case .auto: return .auto
            case .none: return .none
            case .required: return .required
            case .specific(let name): return .specific(functionName: name)
        }
    }

    // MARK: - private helpers

    private static func envEndpoint(for backend: OpenAIConnectorBackend) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch backend {
            case .openRouter:
                return env["KT_OPENROUTER_ENDPOINT"]
                    ?? env["OPENROUTER_BASE_URL"]
                    ?? env["OPENAI_ENDPOINT"]
                    ?? env["OPENAI_BASE_URL"]
            case .openAI:
                return env["KT_OPENAI_ENDPOINT"]
                    ?? env["OPENAI_ENDPOINT"]
                    ?? env["OPENAI_BASE_URL"]
            case .custom:
                return env["KT_OPENAI_ENDPOINT"]
                    ?? env["OPENAI_ENDPOINT"]
                    ?? env["OPENAI_BASE_URL"]
        }
    }
}

extension OpenAIConnectorBackend {
    fileprivate var defaultBaseURL: String {
        switch self {
            case .openRouter: return "https://openrouter.ai/api"
            case .openAI: return "https://api.openai.com"
            case .custom(let baseURL): return baseURL
        }
    }
}
