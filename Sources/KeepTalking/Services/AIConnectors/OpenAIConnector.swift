import Foundation
import OpenAI

public actor OpenAIConnector {
    public static func keepTalkingSystemPrompt(
        listingToolFunctionName: String,
        contextTranscript: String
    ) -> String {
        """
        You are a KeepTalking participant in a group chat.
        Use the provided conversation context when deciding whether to call tools and when writing your response.
        Use tools only when they are relevant to the user's request.
        If no applicable tool/action exists for this context, and the user is not asking for tool execution, reply naturally in chat without calling tools.
        Do not fabricate tool outputs.
        Call \(listingToolFunctionName) before deciding any tool plan.

        Skill execution policy (mandatory):
        1) If you will use any tool where listing output shows source=skill and route_kind=action_proxy, first call the matching source=skill route_kind=skill_metadata tool for that same action_id.
        2) Then call the matching source=skill route_kind=skill_file tool at least once for that same action_id to inspect concrete file content.
        3) Only after a successful skill_file read may you call the skill action_proxy tool for that action_id.
        4) Never skip the skill_file step for skill actions, even if metadata looks sufficient.
        5) If skill_file fails, explain the failure and do not continue with that skill action_proxy call.

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
            timeoutInterval: 30
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
