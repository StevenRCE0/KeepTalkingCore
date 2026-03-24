import Foundation
import OpenAI

public actor OpenAIConnector {
    public static func keepTalkingSystemPrompt(
        listingToolFunctionName: String,
        attachmentListingToolFunctionName: String,
        attachmentReaderToolFunctionName: String,
        currentPromptIncludesAttachments: Bool,
        currentPromptShouldAvoidAutomaticToolUse: Bool,
        contextTranscript: String
    ) -> String {
        let currentPromptGuidance: String
        if currentPromptIncludesAttachments {
            currentPromptGuidance = currentPromptShouldAvoidAutomaticToolUse
                ? """
                The current user turn already includes its newly attached files natively.
                Do not call attachment tools, the action listing tool, or any other tool just to inspect those current attachments.
                Only call a tool if the user explicitly asks for tool/action use, web lookup, or inspection of a different context file that is not already included in the current turn.
                """
                : """
                The current user turn already includes its newly attached files natively.
                Do not call attachment tools just to inspect those current attachments.
                """
        } else {
            currentPromptGuidance = ""
        }

        return """
        You are a KeepTalking participant in a group chat.
        Use the provided conversation context when deciding whether to call tools and when writing your response.
        Use tools only when they are relevant to the user's request.
        If no applicable tool/action exists for this context, and the user is not asking for tool execution, reply naturally in chat without calling tools.
        Do not fabricate tool outputs.
        Call \(listingToolFunctionName) before deciding any KeepTalking action plan, but notice that you might also have built-in tools
        like web search and context attachment access outside of the listed action tool output.
        You do not have general filesystem access. Attachment tools expose only files that are already attached to the active context.
        If the user asks about a file already attached to this context, call \(attachmentListingToolFunctionName) to inspect the available attachments.
        Prefer \(attachmentReaderToolFunctionName) with mode=metadata or mode=preview_text first, and use mode=native only when you need the actual file or image content added to the next model turn.
        \(currentPromptGuidance)

        Skill execution policy (mandatory):
        1) If you will use any tool where listing output shows source=skill and route_kind=action_proxy, first call the matching source=skill route_kind=skill_metadata tool for that same action_id.
        2) Then call the matching source=skill route_kind=skill_file tool at least once for that same action_id to inspect concrete file content.
        3) Only after a successful skill_file read may you call the skill action_proxy tool for that action_id.
        4) Never skip the skill_file step for skill actions, even if metadata looks sufficient.
        5) If skill_file fails, explain the failure and do not continue with that skill action_proxy call.

        Tool-result response policy:
        1) When tool output contains user-relevant findings, include a concise assistant text summary after processing the tool output.
        2) If the tool output has nothing meaningful for the user, keep the assistant text brief and explicit about that.
        3) Do not just stop at tool calls when the user would benefit from a short natural-language update.

        Conversation context:
        \(contextTranscript)
        """
    }

    public struct ToolPlanningResult: Sendable {
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

    public enum ConnectorError: Error, LocalizedError {
        case missingAPIKey
        case invalidEndpoint(String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
                case .missingAPIKey:
                    return "OPENAI_API_KEY environment variable is not set."
                case .invalidEndpoint(let raw):
                    return "Invalid OpenAI endpoint URL: \(raw)"
                case .emptyResponse:
                    return "No response choices received."
            }
        }
    }

    private let client: OpenAI

    public init(
        apiKey: String? = nil,
        organizationID: String? = nil,
        endpoint: String? = nil
    ) throws {
        guard
            let key = apiKey
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !key.isEmpty
        else {
            fatalError(ConnectorError.missingAPIKey.localizedDescription)
        }

        let endpointConfig = try Self.endpointConfiguration(
            from: endpoint
                ?? ProcessInfo.processInfo.environment["OPENAI_ENDPOINT"]
                ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
        )

        let configuration = OpenAI.Configuration(
            token: key,
            organizationIdentifier: organizationID,
            host: endpointConfig?.host ?? "api.openai.com",
            port: endpointConfig?.port ?? 443,
            scheme: endpointConfig?.scheme ?? "https",
            basePath: endpointConfig?.basePath ?? "/v1",
            timeoutInterval: 60
        )
        self.client = OpenAI(configuration: configuration)
    }

    private struct EndpointConfiguration {
        let host: String
        let port: Int
        let scheme: String
        let basePath: String
    }

    private static func endpointConfiguration(from raw: String?) throws
        -> EndpointConfiguration?
    {
        guard
            let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        guard
            let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !host.isEmpty
        else {
            throw ConnectorError.invalidEndpoint(raw)
        }

        let port =
            components.port
            ?? (scheme == "http" ? 80 : 443)

        let trimmedPath = components.path.trimmingCharacters(
            in: CharacterSet(
                charactersIn: "/"
            ))
        let basePath =
            trimmedPath.isEmpty
            ? "/v1"
            : "/" + trimmedPath

        return EndpointConfiguration(
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath
        )
    }

    public func completeTurn(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil
    ) async throws -> ToolPlanningResult {
        let responseInput = toResponseInput(messages: messages)
        let resolvedToolChoice = toResponseToolChoice(
            toolChoice ?? (tools.isEmpty ? .none : .auto)
        )

        let query = CreateModelResponseQuery(
            input: .inputItemList(responseInput),
            model: model,
            toolChoice: resolvedToolChoice,
            tools: tools.isEmpty ? nil : tools
        )

        let result = try await client.responses.createResponse(query: query)
        let assistantText = extractAssistantText(from: result)
        let toolCalls = extractToolCalls(from: result)

        if assistantText == nil, toolCalls.isEmpty {
            throw ConnectorError.emptyResponse
        }

        return ToolPlanningResult(
            assistantText: assistantText,
            toolCalls: toolCalls
        )
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
                                        status: nil
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
