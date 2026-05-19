import Foundation

public protocol StandaloneWebSearchBackend: Sendable {
    func search(query: String) async throws -> String
}

public struct StandaloneWebSearchConfiguration: Sendable {
    public enum Kind: String, Sendable, Codable {
        case exa
    }

    public let kind: Kind
    public let apiKey: String?

    public init(kind: Kind, apiKey: String?) {
        self.kind = kind
        self.apiKey = apiKey
    }
}
