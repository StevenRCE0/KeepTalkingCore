import Foundation
import OpenAI

public actor OpenAIConnector {
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
            organizationIdentifier: organizationID
        )
        self.client = OpenAI(configuration: configuration)
    }

    public func chat(prompt: String, model: String = "gpt-4o") async throws
        -> String
    {
        let query = ChatQuery(
            messages: [
                .user(.init(content: .string(prompt)))
            ],
            model: model
        )

        let result = try await client.chats(query: query)
        guard
            let reply = result.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !reply.isEmpty
        else {
            throw ConnectorError.emptyResponse
        }

        return reply
    }
}
