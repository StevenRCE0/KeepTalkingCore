import Foundation

public struct WebSearchToolConfiguration: Sendable {
    public let apiKey: String?
    public let endpoint: String?
    public let model: String?

    public init(
        apiKey: String?,
        endpoint: String?,
        model: String?
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }
}
