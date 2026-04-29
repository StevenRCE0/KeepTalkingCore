import Foundation

public enum OpenAIWebSearchToolError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case emptyResponse
    case apiError(Int, String)

    public var errorDescription: String? {
        switch self {
            case .missingAPIKey:
                return "OpenAI web search requires an API key."
            case .invalidEndpoint:
                return "OpenAI web search requires a valid endpoint URL."
            case .emptyResponse:
                return "OpenAI web search returned an empty response."
            case .apiError(let code, let message):
                return "OpenAI web search failed (\(code)): \(message)"
        }
    }
}

/// Server-side web search for OpenAI-compatible Chat Completions endpoints
/// that accept the xiaomimimo-style typed tool block:
///
/// ```json
/// "tools": [{
///   "type": "web_search",
///   "max_keyword": 3,
///   "force_search": true,
///   "limit": 1
/// }]
/// ```
///
/// Mirrors `OpenRouterWebSearchTool` — issues a one-shot chat completion with
/// the web_search tool attached and returns the assistant's text content.
public struct OpenAIWebSearchTool: KeepTalkingWebSearchTool {
    public init() {}

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Tool: Encodable {
            let type: String
            let max_keyword: Int
            let force_search: Bool
            let limit: Int
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
            ?? "gpt-4o-mini"

        return { query in
            guard let trimmedAPIKey, !trimmedAPIKey.isEmpty else {
                throw OpenAIWebSearchToolError.missingAPIKey
            }
            guard
                let trimmedEndpoint,
                !trimmedEndpoint.isEmpty,
                let baseURL = URL(string: trimmedEndpoint)
            else {
                throw OpenAIWebSearchToolError.invalidEndpoint
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
                            type: "web_search",
                            max_keyword: 3,
                            force_search: true,
                            limit: 1
                        )
                    ]
                )
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard statusCode == 200 else {
                let message =
                    (try? JSONDecoder().decode(APIErrorBody.self, from: data))
                    .map(\.error.message)
                    ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
                throw OpenAIWebSearchToolError.apiError(
                    statusCode,
                    message
                )
            }

            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            let content =
                decoded.choices.first?.message.content.map(\.textValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let content, !content.isEmpty else {
                throw OpenAIWebSearchToolError.emptyResponse
            }
            return content
        }
    }

    private static func chatCompletionsURL(from baseURL: URL) -> URL {
        var url = baseURL
        if url.path.hasSuffix("/chat/completions") {
            return url
        }
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")
        return url
    }
}
