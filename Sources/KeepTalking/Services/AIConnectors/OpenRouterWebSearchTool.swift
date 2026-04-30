import Foundation

public enum OpenRouterWebSearchToolError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case unsupportedEndpointHost(String?)
    case emptyResponse
    case apiError(Int, String)

    public var errorDescription: String? {
        switch self {
            case .missingAPIKey:
                return "OpenRouter web search requires an API key."
            case .invalidEndpoint:
                return "OpenRouter web search requires a valid endpoint URL."
            case .unsupportedEndpointHost(let host):
                let renderedHost = host ?? "unknown"
                return
                    "OpenRouter web search requires an OpenRouter endpoint. Current host: \(renderedHost)."
            case .emptyResponse:
                return "OpenRouter web search returned an empty response."
            case .apiError(let code, let message):
                return "OpenRouter web search failed (\(code)): \(message)"
        }
    }
}

public struct OpenRouterWebSearchTool: KeepTalkingWebSearchTool {
    public init() {}

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Tool: Encodable {
            struct Parameters: Encodable {
                let engine: String?
                let max_results: Int?
            }
            let type: String
            let parameters: Parameters?
        }

        let model: String
        let messages: [Message]
        let tools: [Tool]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: MessageContent?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct APIErrorBody: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

    private enum MessageContent: Decodable {
        struct Part: Decodable {
            let text: String?
        }

        case string(String)
        case parts([Part])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
                return
            }
            self = .parts(try container.decode([Part].self))
        }

        var textValue: String {
            switch self {
                case .string(let value):
                    return value
                case .parts(let parts):
                    return parts.compactMap(\.text).joined(separator: "\n")
            }
        }
    }

    public func makeProvider(
        configuration: WebSearchToolConfiguration
    ) -> KeepTalkingClient.WebSearchProvider {
        let trimmedAPIKey = configuration.apiKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedEndpoint = configuration.endpoint?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolvedModel = configuration.model?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let selectedModel =
            (resolvedModel?.isEmpty == false ? resolvedModel : nil)
            ?? "openrouter/auto"

        return { query in
            guard let trimmedAPIKey, !trimmedAPIKey.isEmpty else {
                throw OpenRouterWebSearchToolError.missingAPIKey
            }
            guard
                let trimmedEndpoint,
                !trimmedEndpoint.isEmpty,
                let baseURL = URL(string: trimmedEndpoint)
            else {
                throw OpenRouterWebSearchToolError.invalidEndpoint
            }
            guard baseURL.host?.contains("openrouter.ai") == true else {
                throw OpenRouterWebSearchToolError.unsupportedEndpointHost(
                    baseURL.host
                )
            }

            let requestURL = Self.chatCompletionsURL(from: baseURL)
            var request = URLRequest(url: requestURL, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue(
                "Bearer \(trimmedAPIKey)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONEncoder().encode(
                RequestBody(
                    model: selectedModel,
                    messages: [
                        .init(
                            role: "system",
                            content:
                                "Use the available web search tool to answer the user's query with current information. Return a concise summary and include source links in markdown."
                        ),
                        .init(role: "user", content: query),
                    ],
                    tools: [
                        .init(
                            type: "openrouter:web_search",
                            parameters: .init(engine: "exa", max_results: 5)
                        )
                    ]
                )
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard statusCode == 200 else {
                let parsed =
                    (try? JSONDecoder().decode(APIErrorBody.self, from: data))
                    .map(\.error.message)
                let raw = String(data: data, encoding: .utf8)
                let message =
                    parsed
                    ?? raw
                    ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                throw OpenRouterWebSearchToolError.apiError(
                    statusCode,
                    message
                )
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            let content =
                decoded.choices.first?.message.content.map(\.textValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let content, !content.isEmpty else {
                throw OpenRouterWebSearchToolError.emptyResponse
            }
            return content
        }
    }

    /// The connector treats the configured endpoint as the host root (e.g.
    /// `https://openrouter.ai/api`) and lets AIProxy append
    /// `/v1/chat/completions`. Match that contract here so we share the same
    /// endpoint string the main connector uses, instead of inventing our own.
    private static func chatCompletionsURL(from baseURL: URL) -> URL {
        var url = baseURL
        if url.path.hasSuffix("/chat/completions") {
            return url
        }
        if !url.path.contains("/v1") {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")
        return url
    }
}
