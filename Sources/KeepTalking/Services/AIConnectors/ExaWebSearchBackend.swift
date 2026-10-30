import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ExaWebSearchBackendError: LocalizedError {
    case apiError(Int, String)
    case emptyResults
    case fetchFailed(String, String)

    public var errorDescription: String? {
        switch self {
            case .apiError(let code, let message):
                return "Exa request failed (\(code)): \(message)"
            case .emptyResults:
                return "Exa search returned no results."
            case .fetchFailed(let url, let reason):
                return "Exa could not fetch \(url): \(reason)"
        }
    }
}

public struct ExaWebSearchBackend: StandaloneWebSearchBackend, StandaloneWebFetchBackend {
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

    private struct ContentsRequestBody: Encodable {
        struct Text: Encodable {
            let maxCharacters: Int
        }
        let urls: [String]
        let text: Text
        let livecrawlTimeout: Int
    }

    private struct ContentsResponseBody: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String
            let text: String?
        }
        struct Status: Decodable {
            struct Failure: Decodable {
                let tag: String?
                let httpStatusCode: Int?
            }
            let status: String
            let error: Failure?
        }
        let results: [Result]
        let statuses: [Status]?
    }

    public func search(query: String) async throws -> String {
        let data = try await post(
            path: "search",
            body: RequestBody(
                query: query,
                numResults: 5,
                useAutoprompt: true,
                contents: .init(text: true)
            ),
            timeout: 30
        )
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

    public func fetch(url: String) async throws -> String {
        let data = try await post(
            path: "contents",
            body: ContentsRequestBody(
                urls: [url],
                text: .init(maxCharacters: 60_000),
                livecrawlTimeout: 15_000
            ),
            timeout: 45
        )
        let decoded = try JSONDecoder().decode(ContentsResponseBody.self, from: data)
        if let failure = decoded.statuses?.first(where: { $0.status == "error" }) {
            let reason = [failure.error?.tag, failure.error?.httpStatusCode.map { "HTTP \($0)" }]
                .compactMap { $0 }
                .joined(separator: ", ")
            throw ExaWebSearchBackendError.fetchFailed(url, reason.isEmpty ? "unknown error" : reason)
        }
        guard let page = decoded.results.first,
            let text = page.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw ExaWebSearchBackendError.fetchFailed(url, "no readable content")
        }
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [title.isEmpty ? nil : "# \(title)", "URL: \(page.url)", "", text]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func post(path: String, body: some Encodable, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(
            url: URL(string: "https://api.exa.ai/\(path)")!,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = trimmedKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        request.httpBody = try JSONEncoder().encode(body)

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
        return data
    }
}
