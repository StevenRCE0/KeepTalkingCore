import Foundation

public enum KeepTalkingKVServiceError: Error {
    case notImplemented
}

public final class KeepTalkingHTTPKVService: KeepTalkingKVService, @unchecked Sendable {
    public func storeNodeID(_ node: UUID) async throws {
        throw KeepTalkingKVServiceError.notImplemented
    }

    public func loadNodeIDs() async throws -> [UUID] {
        throw KeepTalkingKVServiceError.notImplemented
    }

    private struct StoreRequest: Codable {
        let userID: String
        let nodeID: String
    }

    private struct ListResponse: Codable {
        let nodeIDs: [String]
    }

    private let baseURL: URL
    private let nodesPath: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        nodesPath: String = "/nodes",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.nodesPath = nodesPath
        self.session = session
    }

    public func storeNodeID(_ nodeID: String, for userID: String) async throws {
        var request = URLRequest(url: makeURL(path: nodesPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(StoreRequest(userID: userID, nodeID: nodeID))

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, expected: [200, 201, 204])
    }

    public func loadNodeIDs(for userID: String) async throws -> [String] {
        let url = makeURL(path: "\(trimSlashes(nodesPath))/\(userID)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, expected: [200])

        if let wrapped = try? decoder.decode(ListResponse.self, from: data) {
            return wrapped.nodeIDs
        }
        return try decoder.decode([String].self, from: data)
    }

    private func makeURL(path: String) -> URL {
        baseURL.appendingPathComponent(trimSlashes(path), isDirectory: false)
    }

    private func trimSlashes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func validateHTTP(_ response: URLResponse, expected: [Int]) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard expected.contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
