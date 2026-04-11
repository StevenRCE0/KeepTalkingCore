import Foundation

public protocol KeepTalkingWebSearchTool: Sendable {
    func makeProvider(
        configuration: WebSearchToolConfiguration
    ) -> KeepTalkingClient.WebSearchProvider
}
