import Foundation
import OpenAI

public actor OpenAIConnector {
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
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OPENAI_API_KEY environment variable is not set."
            case .emptyResponse:
                return "No response choices received."
            }
        }
    }

    private let client: OpenAI

    public init(apiKey: String? = nil, organizationID: String? = nil) {
        guard
            let key = apiKey
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !key.isEmpty
        else {
            fatalError(ConnectorError.missingAPIKey.localizedDescription)
        }

        let configuration = OpenAI.Configuration(
            token: key,
            organizationIdentifier: organizationID,
            timeoutInterval: 30
        )
        self.client = OpenAI(configuration: configuration)
    }

    public func chat(prompt: String, model: String = "gpt-4o") async throws
        -> String
    {
        let result = try await completeTurn(
            messages: [
                .user(.init(content: .string(prompt)))
            ],
            tools: [],
            model: model
        )
        guard
            let reply = result.assistantText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !reply.isEmpty
        else {
            throw ConnectorError.emptyResponse
        }

        return reply
    }

    public func planTools(
        prompt: String,
        tools: [ChatQuery.ChatCompletionToolParam],
        model: String = .gpt4
    ) async throws -> ToolPlanningResult {
        try await completeTurn(
            messages: [
                .user(.init(content: .string(prompt)))
            ],
            tools: tools,
            model: model
        )
    }

    public func completeTurn(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam],
        model: String = .gpt4,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil
    ) async throws -> ToolPlanningResult {
        let resolvedTools = tools.isEmpty ? nil : tools
        let resolvedToolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? =
            resolvedTools == nil ? nil : (toolChoice ?? .auto)

        let query = ChatQuery(
            messages: messages,
            model: model,
            toolChoice: resolvedToolChoice,
            tools: resolvedTools
        )

        let result = try await client.chats(query: query)
        let assistantText = result.choices.first?.message.content
        let toolCalls = result.choices.first?.message.toolCalls ?? []
        return ToolPlanningResult(
            assistantText: assistantText,
            toolCalls: toolCalls
        )
    }
}
