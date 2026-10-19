import AIProxy
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    private let imageFitter = AIImageInputFitter()
    private let apiKey: String
    private let modelsURL: URL

    public nonisolated let capabilities: AIConnectorCapabilities = .init(
        supportsNativeToolCalling: true,
        supportsThinking: true
    )

    /// Default request timeout in seconds. Maps to `URLRequest.timeoutInterval`
    /// — an IDLE timer, reset by every received byte.
    private static let defaultTimeoutSeconds: UInt = 60

    /// Absolute per-request ceiling for one completion turn; see
    /// `awaitTurnRequest` for why the idle timer alone is not enough.
    private static let wallClockTimeoutSeconds: UInt = 480

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

    /// The Messages API has no mid-conversation system role.
    public nonisolated func systemRowPlacement(forModel model: String) -> AISystemRowPlacement {
        .wrappedInUserTurn
    }

    /// Every Messages endpoint, a proxy included, ends at Anthropic's limits.
    public nonisolated func imageInputPolicy(forModel model: String) -> AIImageInputPolicy {
        .anthropic
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
        let messages = imageFitter.fitted(messages, policy: imageInputPolicy(forModel: model))
        let (system, anthropicMessages) = Self.translateMessages(messages)
        var anthropicTools = tools.map(Self.translateTool(_:))
        if let toolsCacheControl = Self.cacheControl(for: configuration?.toolsCacheBoundary),
            case .customTool(let last)? = anthropicTools.last
        {
            anthropicTools[anthropicTools.count - 1] = .customTool(
                .init(
                    description: last.description,
                    inputSchema: last.inputSchema,
                    name: last.name,
                    cacheControl: toolsCacheControl
                )
            )
        }
        // Anthropic rejects `tool_choice` without `tools` (a tool-less model's
        // run still carries the orchestrator's `.auto`).
        let anthropicToolChoice =
            anthropicTools.isEmpty ? nil : toolChoice.map(Self.translateToolChoice(_:))

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

        // The request runs as a task-group child so parent cancellation
        // propagates to AIProxy's URLSession data task, and a wall-clock
        // watchdog bounds it — `secondsToWait` is only an idle timer, which a
        // slow-dripping response outlives forever (see `awaitTurnRequest`).
        let response = try await awaitTurnRequest(
            wallClockSeconds: Self.wallClockTimeoutSeconds
        ) { [service] in
            try await service.messageRequest(
                body: body,
                secondsToWait: Self.defaultTimeoutSeconds
            )
        }

        return Self.translateResponse(response)
    }

    // MARK: - private translation

    /// Splits a KT-native message history into:
    /// - the Anthropic top-level `system` field: every `system` row BEFORE the
    ///   first user/assistant row, one block each
    /// - the user/assistant message list (with tool results modelled as user-role
    ///   `tool_result` content blocks). A `system` row after the first
    ///   user/assistant row stays where it is, as a user turn wrapped in a
    ///   `<system>` tag — hoisting it would move per-turn text above the
    ///   cached prefix.
    ///
    /// `cacheBoundary` on a row becomes `cache_control` on that row's last
    /// block: `durable` → one hour, `rolling` → the default five minutes.
    static func translateMessages(
        _ messages: [AIMessage]
    ) -> (AnthropicSystemPrompt?, [AnthropicMessageParam]) {
        var systemBlocks: [AnthropicSystemTextBlockParam] = []
        var output: [AnthropicMessageParam] = []
        let firstDialogueIndex = messages.firstIndex { $0.role != .system } ?? messages.endIndex

        for (index, message) in messages.enumerated() {
            let cacheControl = cacheControl(for: message.cacheBoundary)
            switch message.role {
                case .system where index < firstDialogueIndex:
                    systemBlocks.append(
                        .init(text: message.content?.text ?? "", cacheControl: cacheControl)
                    )

                case .system:
                    output.append(
                        .init(
                            content: .blocks([
                                .textBlock(
                                    .init(
                                        text: AISystemRowPlacement.wrapped(message.content?.text ?? ""),
                                        cacheControl: cacheControl
                                    )
                                )
                            ]),
                            role: .user
                        )
                    )

                case .user:
                    output.append(
                        .init(
                            content: translateUserContent(message.content, cacheControl: cacheControl),
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
                    output.append(
                        .init(content: .blocks(withCacheControl(cacheControl, onLastOf: blocks)), role: .assistant)
                    )

                case .tool:
                    // Anthropic models tool results as user-role messages
                    // carrying a `tool_result` content block.
                    output.append(
                        .init(
                            content: .blocks([
                                .toolResultBlock(
                                    .init(
                                        toolUseId: message.toolCallID ?? "",
                                        cacheControl: cacheControl,
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
        } else if systemBlocks.allSatisfy({ $0.cacheControl == nil }) {
            // No breakpoints: the single string the connector always sent.
            system = .text(systemBlocks.map(\.text).joined(separator: "\n\n"))
        } else {
            system = .blocks(systemBlocks)
        }
        return (system, output)
    }

    static func cacheControl(for boundary: AICacheBoundary?) -> AnthropicCacheControlEphemeral? {
        switch boundary {
            case .none: return nil
            case .durable: return .init(ttl: .oneHour)
            case .rolling: return .init()
        }
    }

    /// `blocks` with `cacheControl` set on the last one that can carry it.
    private static func withCacheControl(
        _ cacheControl: AnthropicCacheControlEphemeral?,
        onLastOf blocks: [AnthropicContentBlockParam]
    ) -> [AnthropicContentBlockParam] {
        guard let cacheControl, let last = blocks.last else { return blocks }
        var blocks = blocks
        switch last {
            case .textBlock(let block):
                blocks[blocks.count - 1] = .textBlock(
                    .init(text: block.text, cacheControl: cacheControl, citations: block.citations)
                )
            case .toolUseBlock(let block):
                blocks[blocks.count - 1] = .toolUseBlock(
                    .init(id: block.id, input: block.input, name: block.name, cacheControl: cacheControl)
                )
            default:
                break
        }
        return blocks
    }

    /// Translates `AIMessage.Content` into Anthropic's user-message body. Image
    /// parts that arrive as `data:` URLs are decoded into base64 image sources;
    /// `https://` URLs become URL image sources. Anything else is collapsed to
    /// a text placeholder so we don't silently drop the part.
    private static func translateUserContent(
        _ content: AIMessage.Content?,
        cacheControl: AnthropicCacheControlEphemeral? = nil
    ) -> AnthropicMessageParamContent {
        switch content {
            case .none:
                return .text("")
            case .text(let s):
                guard let cacheControl else { return .text(s) }
                return .blocks([.textBlock(.init(text: s, cacheControl: cacheControl))])
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
                        case .inputAudio:
                            return .textBlock(
                                .init(text: "[audio input not supported by this provider]")
                            )
                    }
                }
                return .blocks(withCacheControl(cacheControl, onLastOf: blocks))
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

        // Anthropic counts uncached input apart from cache reads and writes;
        // `AITurnUsage.inputTokens` is the whole prompt.
        let usage = response.usage
        let cacheRead = usage.cacheReadInputTokens ?? 0
        let cacheWrite = usage.cacheCreationInputTokens ?? 0
        return AITurnResult(
            assistantText: assistantText,
            thinking: thinking,
            toolCalls: toolCalls,
            usage: AITurnUsage(
                inputTokens: usage.inputTokens + cacheRead + cacheWrite,
                outputTokens: usage.outputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                responseID: response.id
            )
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
