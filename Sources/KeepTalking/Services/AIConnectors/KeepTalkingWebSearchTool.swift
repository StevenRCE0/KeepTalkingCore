import Foundation

public protocol KeepTalkingWebSearchTool: Sendable {
    func makeProvider(
        configuration: WebSearchToolConfiguration
    ) -> KeepTalkingClient.WebSearchProvider
}

public protocol KeepTalkingWebFetchTool: Sendable {
    func makeFetchProvider(
        configuration: WebSearchToolConfiguration
    ) -> KeepTalkingClient.WebFetchProvider
}
