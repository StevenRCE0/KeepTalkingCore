import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ExaWebSearchBackendError: LocalizedError {
    case apiError(Int, String)
    case emptyResults

    public var errorDescription: String? {
        switch self {
            case .apiError(let code, let message):
                return "Exa search failed (\(code)): \(message)"
            case .emptyResults:
                return "Exa search returned no results."
        }
    }
}

public struct ExaWebSearchBackend: StandaloneWebSearchBackend {
    private let configuration: StandaloneWebSearchConfiguration

    public init(configuration: StandaloneWebSearchConfiguration) {
        self.configuration = configuration
    }

    private struct RequestBody: Encodable {
        struct Contents: Encodable {
            let text: Bool
        }
        let query: String
        let numResults: Int
        let useAutoprompt: Bool
        let contents: Contents
    }

    private struct ResponseBody: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String
            let text: String?
            let score: Double?
        }
        let results: [Result]
    }

    private struct APIErrorBody: Decodable {
        let message: String?
        let error: String?

        var resolvedMessage: String {
            message ?? error ?? "unknown error"
        }
    }

    public func search(query: String) async throws -> String {
        let url = URL(string: "https://api.exa.ai/search")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = trimmedKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                query: query,
                numResults: 5,
                useAutoprompt: true,
                contents: .init(text: true)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200

        guard statusCode == 200 else {
            let message =
                (try? JSONDecoder().decode(APIErrorBody.self, from: data))
                .map(\.resolvedMessage)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw ExaWebSearchBackendError.apiError(statusCode, message)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard !decoded.results.isEmpty else {
            throw ExaWebSearchBackendError.emptyResults
        }

        var lines: [String] = ["Web search results for: \(query)", ""]
        for (index, result) in decoded.results.enumerated() {
            let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? result.url
            lines.append("\(index + 1). \(title)")
            lines.append("   URL: \(result.url)")
            if let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                let snippet = text.count > 500 ? String(text.prefix(500)) + "…" : text
                lines.append("   \(snippet)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
