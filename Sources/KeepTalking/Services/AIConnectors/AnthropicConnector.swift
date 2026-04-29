import AIProxy
import Foundation

/// Backend selection for the Anthropic connector. Mirrors `OpenAIConnectorBackend`:
/// each case is an Anthropic-shaped Messages endpoint, differing only in base URL.
public enum AnthropicConnectorBackend: Sendable {
    /// Anthropic's hosted Messages API.
    /// Default base URL: `https://api.anthropic.com`.
    case anthropic
    /// A custom base URL serving the Anthropic Messages API shape (e.g. a proxy).
    case custom(baseURL: String)
}

/// `AIConnector` implementation backed by the Anthropic Messages API.
///
/// Takes KT-native `AIMessage` / `KeepTalkingActionToolDefinition` / `AIToolChoice`
/// inputs and translates them straight into the Anthropic Messages wire shape —
/// no OpenAI intermediate hop. Reasoning is surfaced via `AITurnResult.thinking`.
///
/// What's _not_ modelled yet (silently dropped to keep the wire body lean):
/// - `name` on user/assistant/system messages
/// - `responseFormat` (Anthropic doesn't have a JSON-mode toggle; structured
///   output is handled at the prompt level by the orchestrator)
public actor AnthropicConnector: AIConnector {
    public enum ConnectorError: Error, LocalizedError {
        case missingAPIKey
        case invalidEndpoint(String)
        case emptyResponse
        case unsupportedToolKind

        public var errorDescription: String? {
            switch self {
                case .missingAPIKey:
                    return "No API key provided. Set ANTHROPIC_API_KEY or pass apiKey explicitly."
                case .invalidEndpoint(let raw):
                    return "Invalid Anthropic endpoint URL: \(raw)"
                case .emptyResponse:
                    return "No content blocks in Anthropic response."
                case .unsupportedToolKind:
                    return "Anthropic connector only supports function-shaped custom tools."
            }
        }
    }

    private let service: AnthropicService
    private let apiKey: String
    private let modelsURL: URL

    public nonisolated let capabilities: AIConnectorCapabilities = .init(
        supportsNativeToolCalling: true,
        supportsThinking: true
    )

    /// Default request timeout in seconds.
    private static let defaultTimeoutSeconds: UInt = 60

    /// Anthropic requires `max_tokens`; this is the floor we send if the caller
    /// doesn't specify one in `AITurnConfiguration.maxOutputTokens`.
    private static let defaultMaxTokens: Int = 8192

    public init(
        apiKey: String? = nil,
        endpoint: String? = nil,
        backend: AnthropicConnectorBackend = .anthropic
    ) throws {
        guard
            let key = apiKey
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
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
        self.service = AIProxy.anthropicDirectService(
            unprotectedAPIKey: key,
            baseURL: endpointURL.absoluteString
        )
        self.modelsURL = endpointURL.appendingPathComponent("v1/models")
    }

    // MARK: - listModels

    /// Lists models available to the configured API key.
    /// Anthropic's `/v1/models` endpoint requires the same `x-api-key` and
    /// `anthropic-version` headers as Messages does.
    public func listModels() async throws -> [String] {
        struct ModelItem: Decodable { let id: String }
        struct ModelList: Decodable { let data: [ModelItem] }
        struct APIErrorDetail: Decodable { let message: String }
        struct APIErrorWrapper: Decodable { let error: APIErrorDetail }

        var request = URLRequest(url: modelsURL, timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

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
        let (system, anthropicMessages) = Self.translateMessages(messages)
        let anthropicTools = tools.map(Self.translateTool(_:))
        let anthropicToolChoice = toolChoice.map(Self.translateToolChoice(_:))

        let body = AnthropicMessageRequestBody(
            maxTokens: configuration?.maxOutputTokens ?? Self.defaultMaxTokens,
            messages: anthropicMessages,
            model: model,
            stopSequences: configuration?.stop,
            system: system,
            temperature: configuration?.temperature,
            thinking: Self.translateThinking(configuration?.reasoning),
            toolChoice: anthropicToolChoice,
            tools: anthropicTools.isEmpty ? nil : anthropicTools,
            topP: configuration?.topP
        )

        let response = try await service.messageRequest(
            body: body,
            secondsToWait: Self.defaultTimeoutSeconds
        )

        return Self.translateResponse(response)
    }

    // MARK: - private translation

    /// Splits a KT-native message history into:
    /// - the Anthropic top-level `system` field (concatenated from `system` messages)
    /// - the user/assistant message list (with tool results modelled as user-role
    ///   `tool_result` content blocks)
    private static func translateMessages(
        _ messages: [AIMessage]
    ) -> (AnthropicSystemPrompt?, [AnthropicMessageParam]) {
        var systemBlocks: [String] = []
        var output: [AnthropicMessageParam] = []

        for message in messages {
            switch message.role {
                case .system:
                    systemBlocks.append(message.content?.text ?? "")

                case .user:
                    output.append(
                        .init(
                            content: translateUserContent(message.content),
                            role: .user
                        )
                    )

                case .assistant:
                    var blocks: [AnthropicContentBlockParam] = []
                    let text = message.content?.text ?? ""
                    if !text.isEmpty {
                        blocks.append(.textBlock(.init(text: text)))
                    }
                    for call in message.toolCalls {
                        blocks.append(
                            .toolUseBlock(
                                .init(
                                    id: call.id,
                                    input: parseToolArguments(call.argumentsJSON),
                                    name: call.name
                                )
                            )
                        )
                    }
                    if blocks.isEmpty {
                        // Anthropic rejects empty assistant turns; emit a placeholder.
                        blocks.append(.textBlock(.init(text: "")))
                    }
                    output.append(.init(content: .blocks(blocks), role: .assistant))

                case .tool:
                    // Anthropic models tool results as user-role messages
                    // carrying a `tool_result` content block.
                    output.append(
                        .init(
                            content: .blocks([
                                .toolResultBlock(
                                    .init(
                                        toolUseId: message.toolCallID ?? "",
                                        content: .text(message.content?.text ?? "")
                                    )
                                )
                            ]),
                            role: .user
                        )
                    )
            }
        }

        let system: AnthropicSystemPrompt?
        if systemBlocks.isEmpty {
            system = nil
        } else {
            system = .text(systemBlocks.joined(separator: "\n\n"))
        }
        return (system, output)
    }

    /// Translates `AIMessage.Content` into Anthropic's user-message body. Image
    /// parts that arrive as `data:` URLs are decoded into base64 image sources;
    /// `https://` URLs become URL image sources. Anything else is collapsed to
    /// a text placeholder so we don't silently drop the part.
    private static func translateUserContent(
        _ content: AIMessage.Content?
    ) -> AnthropicMessageParamContent {
        switch content {
            case .none:
                return .text("")
            case .text(let s):
                return .text(s)
            case .parts(let parts):
                let blocks: [AnthropicContentBlockParam] = parts.compactMap { part in
                    switch part {
                        case .text(let s):
                            return .textBlock(.init(text: s))
                        case .imageURL(let url):
                            if let block = imageBlock(from: url) {
                                return .imageBlock(block)
                            }
                            return .textBlock(
                                .init(text: "[unsupported image URL: \(url.absoluteString)]")
                            )
                    }
                }
                return .blocks(blocks)
        }
    }

    /// Best-effort `URL` → `AnthropicImageBlockParam`. Handles `data:` URLs by
    /// extracting base64 + media type; falls back to URL-source for `http(s)`.
    private static func imageBlock(from url: URL) -> AnthropicImageBlockParam? {
        let raw = url.absoluteString
        if raw.hasPrefix("data:") {
            // data:[<mediatype>][;base64],<data>
            guard
                let comma = raw.firstIndex(of: ","),
                let semicolon = raw.range(of: ";base64", range: raw.startIndex..<comma)
            else {
                return nil
            }
            let mediaTypeRaw = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<semicolon.lowerBound])
            let base64 = String(raw[raw.index(after: comma)...])
            guard let mediaType = AnthropicImageMediaType(rawValue: mediaTypeRaw) else {
                return nil
            }
            return .init(source: .base64(data: base64, mediaType: mediaType))
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return .init(source: .url(raw))
        }
        return nil
    }

    private static func parseToolArguments(_ raw: String) -> [String: AIProxyJSONValue] {
        guard
            !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: AIProxyJSONValue].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func translateTool(
        _ tool: KeepTalkingActionToolDefinition
    ) -> AnthropicToolUnion {
        .customTool(
            .init(
                description: tool.description,
                inputSchema: tool.parameters,
                name: tool.functionName
            )
        )
    }

    private static func translateToolChoice(
        _ choice: AIToolChoice
    ) -> AnthropicToolChoice {
        switch choice {
            case .none: return .none
            case .auto: return .auto()
            case .required: return .any()
            case .specific(let name): return .tool(name: name)
        }
    }

    private static func translateThinking(
        _ reasoning: AIReasoning?
    ) -> AnthropicThinkingConfigParam? {
        // We only opt into Anthropic's extended thinking when the caller
        // explicitly asked for it; otherwise leave Anthropic to its default
        // (which is no extended thinking).
        guard let reasoning else { return nil }
        switch reasoning.effort {
            case .none, .noReasoning: return nil
            case .minimal, .low: return .enabled(budgetTokens: 1024)
            case .medium: return .enabled(budgetTokens: 4096)
            case .high: return .enabled(budgetTokens: 8192)
            case .xhigh: return .enabled(budgetTokens: 16384)
        }
    }

    private static func translateResponse(
        _ response: AnthropicMessage
    ) -> AITurnResult {
        var assistantText: String? = nil
        var thinking: String? = nil
        var toolCalls: [AIToolCall] = []

        for block in response.content {
            switch block {
                case .textBlock(let b):
                    assistantText = (assistantText.map { "\($0)\n" } ?? "") + b.text
                case .thinkingBlock(let b):
                    thinking = (thinking.map { "\($0)\n" } ?? "") + b.thinking
                case .toolUseBlock(let b):
                    toolCalls.append(
                        AIToolCall(
                            id: b.id,
                            name: b.name,
                            argumentsJSON: serializeToolInput(b.input)
                        )
                    )
                case .redactedThinkingBlock,
                    .serverToolUseBlock,
                    .webSearchToolResultBlock,
                    .futureProof:
                    continue
            }
        }

        return AITurnResult(
            assistantText: assistantText,
            thinking: thinking,
            toolCalls: toolCalls
        )
    }

    /// Anthropic's `toolUseBlock.input` decodes as `[String: any Sendable]`.
    /// We re-encode it as a JSON string so it round-trips through `AIToolCall`
    /// (whose `argumentsJSON` is the raw JSON blob the model emitted).
    private static func serializeToolInput(_ input: [String: any Sendable]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys]
            ),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }

    private static func envEndpoint(for backend: AnthropicConnectorBackend) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch backend {
            case .anthropic:
                return env["KT_ANTHROPIC_ENDPOINT"]
                    ?? env["ANTHROPIC_BASE_URL"]
            case .custom:
                return env["KT_ANTHROPIC_ENDPOINT"]
                    ?? env["ANTHROPIC_BASE_URL"]
        }
    }
}

extension AnthropicConnectorBackend {
    fileprivate var defaultBaseURL: String {
        switch self {
            case .anthropic: return "https://api.anthropic.com"
            case .custom(let baseURL): return baseURL
        }
    }
}
