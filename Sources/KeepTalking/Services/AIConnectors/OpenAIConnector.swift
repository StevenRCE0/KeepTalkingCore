import Foundation
import OpenAI

public enum OpenAIAPIMode: String, Codable, Sendable, CaseIterable {
    case responses
    case chatCompletions

    public var displayName: String {
        switch self {
            case .responses: return "Responses API"
            case .chatCompletions: return "Chat Completions API"
        }
    }
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
        case apiError(Int, String)

        public var errorDescription: String? {
            switch self {
                case .missingAPIKey:
                    return "OPENAI_API_KEY environment variable is not set."
                case .invalidEndpoint(let raw):
                    return "Invalid OpenAI endpoint URL: \(raw)"
                case .emptyResponse:
                    return "No response choices received."
                case .apiError(let code, let message):
                    return "API error \(code): \(message)"
            }
        }
    }

    private let client: OpenAI
    private let apiKey: String
    private let baseURL: URL
    public nonisolated let apiMode: OpenAIAPIMode
    public nonisolated let capabilities: AIConnectorCapabilities = .init(supportsNativeToolCalling: true)

    private static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    public init(
        apiKey: String? = nil,
        organizationID: String? = nil,
        endpoint: String? = nil,
        apiMode: OpenAIAPIMode = .responses
    ) throws {
        guard
            let key = apiKey
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !key.isEmpty
        else {
            fatalError(ConnectorError.missingAPIKey.localizedDescription)
        }

        let endpointURL = try Self.endpointURL(
            from: endpoint
                ?? ProcessInfo.processInfo.environment["OPENAI_ENDPOINT"]
                ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
        )

        let configuration = OpenAI.Configuration(
            token: key,
            organizationIdentifier: organizationID,
            host: endpointURL?.host ?? "api.openai.com",
            port: endpointURL?.port ?? 443,
            scheme: endpointURL?.scheme ?? "https",
            basePath: endpointURL?.path.isEmpty == false ? endpointURL!.path : "/v1",
            timeoutInterval: 60,
            parsingOptions: .relaxed
        )
        self.client = OpenAI(configuration: configuration)
        self.apiKey = key
        self.baseURL = endpointURL ?? Self.defaultBaseURL
        self.apiMode = apiMode
    }

    private static func endpointURL(from raw: String?) throws -> URL? {
        guard
            let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        guard let url = URL(string: raw), url.host != nil else {
            throw ConnectorError.invalidEndpoint(raw)
        }
        return url
    }

    public func listModels() async throws -> [String] {
        struct ModelItem: Decodable {
            let id: String
        }
        struct ModelList: Decodable {
            let data: [ModelItem]
        }
        struct APIErrorDetail: Decodable {
            let message: String
        }
        struct APIErrorWrapper: Decodable {
            let error: APIErrorDetail
        }

        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard statusCode == 200 else {
            let message =
                (try? JSONDecoder().decode(APIErrorWrapper.self, from: data))
                .map(\.error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw ConnectorError.apiError(statusCode, message)
        }
        let result = try JSONDecoder().decode(ModelList.self, from: data)
        return result.data.map(\.id).sorted()
    }

    public func completeTurn(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil,
        stage: AIStage,
        toolExecutor: (
            @Sendable ([ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]) async throws ->
                [ChatQuery.ChatCompletionMessageParam.ToolMessageParam]
        )? = nil
    ) async throws -> AITurnResult {
        switch apiMode {
            case .responses:
                return try await completeTurnViaResponses(
                    messages: messages, tools: tools, model: model,
                    toolChoice: toolChoice,
                    stage: stage
                )
            case .chatCompletions:
                return try await completeTurnViaChatCompletions(
                    messages: messages, tools: tools, model: model,
                    toolChoice: toolChoice,
                    stage: stage
                )
        }
    }

    // MARK: - Responses API

    private func completeTurnViaResponses(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        stage: AIStage
    ) async throws -> AITurnResult {
        let responseInput = toResponseInput(messages: messages)
        let resolvedToolChoice = toResponseToolChoice(
            toolChoice ?? (tools.isEmpty ? .none : .auto)
        )

        let query = CreateModelResponseQuery(
            input: .inputItemList(responseInput),
            model: model,
            reasoning: .init(effort: .medium),  // TODO: expose the reasoning settings
            toolChoice: resolvedToolChoice,
            tools: tools.isEmpty ? nil : tools
        )

        let result = try await client.responses.createResponse(query: query)
        let assistantText = extractAssistantText(from: result)
        let toolCalls = extractToolCalls(from: result)

        if assistantText == nil, toolCalls.isEmpty {
            throw ConnectorError.emptyResponse
        }

        return AITurnResult(
            assistantText: assistantText,
            toolCalls: toolCalls
        )
    }

    // MARK: - Chat Completions API

    private func completeTurnViaChatCompletions(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        stage: AIStage
    ) async throws -> AITurnResult {
        let chatTools = tools.compactMap(Self.toChatCompletionTool)
        let resolvedToolChoice = toolChoice ?? (chatTools.isEmpty ? .none : .auto)

        let query = ChatQuery(
            messages: messages,
            model: model,
            reasoningEffort: .medium,  // TODO: expose the reasoning settings
            toolChoice: chatTools.isEmpty ? nil : resolvedToolChoice,
            tools: chatTools.isEmpty ? nil : chatTools
        )

        let result = try await client.chats(query: query)
        var turnText: String? = nil
        var turnToolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam] = []

        for choice in result.choices {
            if let assistantText = choice.message.content {
                turnText = turnText == nil ? assistantText : turnText! + "\n" + assistantText
            }
            if let toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam] =
                choice.message.toolCalls
            {
                turnToolCalls.append(contentsOf: toolCalls)
            }

        }

        return .init(assistantText: turnText, toolCalls: turnToolCalls)
    }

    /// Convert a Responses API `Tool` to a Chat Completions `ChatCompletionToolParam`.
    /// Non-function tools (web search, MCP, etc.) are Responses-only and return `nil`.
    private static func toChatCompletionTool(
        _ tool: OpenAITool
    ) -> ChatQuery.ChatCompletionToolParam? {
        switch tool {
            case .functionTool(let fn):
                return .init(
                    function: .init(
                        name: fn.name,
                        description: fn.description,
                        parameters: fn.parameters,
                        strict: fn.strict
                    ))
            default:
                return nil
        }
    }

    private func toResponseInput(
        messages: [ChatQuery.ChatCompletionMessageParam]
    ) -> [InputItem] {
        var input: [InputItem] = []
        input.reserveCapacity(messages.count)

        for message in messages {
            switch message {
                case .developer(let payload):
                    if let text = text(from: payload.content) {
                        input.append(
                            .inputMessage(
                                .init(role: .developer, content: .textInput(text))
                            )
                        )
                    }
                case .system(let payload):
                    if let text = text(from: payload.content) {
                        input.append(
                            .inputMessage(
                                .init(role: .system, content: .textInput(text))
                            )
                        )
                    }
                case .user(let payload):
                    if let content = userContent(from: payload.content) {
                        input.append(
                            .inputMessage(
                                .init(role: .user, content: content)
                            )
                        )
                    }
                case .assistant(let payload):
                    if let content = payload.content,
                        let text = text(from: content)
                    {
                        input.append(
                            .inputMessage(
                                .init(role: .assistant, content: .textInput(text))
                            )
                        )
                    }
                    for toolCall in payload.toolCalls ?? [] {
                        input.append(
                            .item(
                                .functionToolCall(
                                    .init(
                                        id: nil,
                                        _type: .functionCall,
                                        callId: toolCall.id,
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments,
                                        status: .completed
                                    )
                                )
                            )
                        )
                    }
                case .tool(let payload):
                    if let output = text(from: payload.content) {
                        input.append(
                            .item(
                                .functionCallOutputItemParam(
                                    .init(
                                        callId: payload.toolCallId,
                                        _type: .functionCallOutput,
                                        output: output
                                    )
                                )
                            )
                        )
                    }
            }
        }

        return input
    }

    static func toResponseTool(
        tool: ChatQuery.ChatCompletionToolParam
    ) -> Tool {
        .functionTool(
            .init(
                name: tool.function.name,
                description: tool.function.description,
                parameters: tool.function.parameters
                    ?? JSONSchema(
                        .type(.object),
                        .properties([:]),
                        .additionalProperties(.boolean(true))
                    ),
                strict: tool.function.strict ?? false
            )
        )
    }

    static func toResponseTools(
        tools: [ChatQuery.ChatCompletionToolParam]
    ) -> [Tool] {
        tools.map(toResponseTool)
    }

    private func toResponseToolChoice(
        _ choice: ChatQuery.ChatCompletionFunctionCallOptionParam
    ) -> CreateModelResponseQuery.ResponseProperties.ToolChoicePayload {
        switch choice {
            case .none:
                return .ToolChoiceOptions(.none)
            case .auto:
                return .ToolChoiceOptions(.auto)
            case .required:
                return .ToolChoiceOptions(.required)
            case .function(let name):
                return .ToolChoiceFunction(
                    .init(_type: .function, name: name)
                )
        }
    }

    private func extractAssistantText(from response: ResponseObject) -> String? {
        let chunks = response.output.compactMap { output -> String? in
            guard case .outputMessage(let message) = output else {
                return nil
            }
            let textParts = message.content.compactMap { content -> String? in
                if case .OutputTextContent(let textContent) = content {
                    return textContent.text
                }
                return nil
            }
            guard !textParts.isEmpty else {
                return nil
            }
            return textParts.joined()
        }

        guard !chunks.isEmpty else {
            return nil
        }
        return chunks.joined(separator: "\n")
    }

    private func extractToolCalls(from response: ResponseObject) -> [ChatQuery.ChatCompletionMessageParam
        .AssistantMessageParam.ToolCallParam]
    {
        response.output.compactMap {
            output -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam? in
            guard case .functionToolCall(let call) = output else {
                return nil
            }
            // Responses tool outputs must reference function call `call_id`.
            // `id` is the output-item identifier and is not accepted as toolCallId.
            let identifier = call.callId
            return .init(
                id: identifier,
                function: .init(
                    arguments: call.arguments,
                    name: call.name
                )
            )
        }
    }

    private func text(
        from content: ChatQuery.ChatCompletionMessageParam.TextContent
    ) -> String? {
        switch content {
            case .textContent(let text):
                return text
            case .contentParts(let parts):
                let joined = parts.map(\.text).joined()
                return joined.isEmpty ? nil : joined
        }
    }

    private func text(
        from content: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent
    ) -> String? {
        switch content {
            case .textContent(let text):
                return text
            case .contentParts(let parts):
                let joined = parts.compactMap { part -> String? in
                    switch part {
                        case .text(let textPart):
                            return textPart.text
                        case .refusal(let refusal):
                            return refusal.refusal
                    }
                }.joined()
                return joined.isEmpty ? nil : joined
        }
    }

    private func userContent(
        from content: ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content
    ) -> EasyInputMessage.ContentPayload? {
        switch content {
            case .string(let text):
                guard !text.isEmpty else {
                    return nil
                }
                return .textInput(text)
            case .contentParts(let parts):
                let inputParts = parts.compactMap(inputContent(from:))
                guard !inputParts.isEmpty else {
                    return nil
                }
                return .inputItemContentList(inputParts)
        }
    }

    private func inputContent(
        from part: ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content
            .ContentPart
    ) -> InputContent? {
        switch part {
            case .text(let textPart):
                guard !textPart.text.isEmpty else {
                    return nil
                }
                return .inputText(
                    .init(
                        _type: .inputText,
                        text: textPart.text
                    )
                )
            case .image(let imagePart):
                return .inputImage(
                    .init(
                        _type: .inputImage,
                        imageUrl: imagePart.imageUrl.url,
                        detail: inputImageDetail(from: imagePart.imageUrl.detail)
                    )
                )
            case .file(let filePart):
                guard
                    filePart.file.fileData != nil || filePart.file.fileId != nil
                else {
                    return nil
                }
                return .inputFile(
                    .init(
                        _type: .inputFile,
                        fileId: filePart.file.fileId.map {
                            .init(value1: $0)
                        },
                        filename: filePart.file.filename,
                        fileData: filePart.file.fileData
                    )
                )
            case .audio:
                return nil
        }
    }

    private func inputImageDetail(
        from detail: ChatQuery.ChatCompletionMessageParam
            .ContentPartImageParam.ImageURL.Detail?
    ) -> InputImage.DetailPayload {
        switch detail {
            case .high:
                return .high
            case .low:
                return .low
            case .auto, .none:
                return .auto
        }
    }
}
