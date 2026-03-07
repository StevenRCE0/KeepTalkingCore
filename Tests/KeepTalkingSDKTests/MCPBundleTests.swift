import Foundation
import Testing

@testable import KeepTalkingSDK

struct MCPBundleTests {
    @Test("HTTP bundle preserves custom headers when encoded and decoded")
    func httpBundleRoundTripHeaders() throws {
        let url = try #require(URL(string: "https://mcp.linear.app"))
        let bundle = KeepTalkingMCPBundle(
            name: "linear",
            indexDescription: "Linear MCP",
            service: .http(
                url: url,
                payload: Data(),
                headers: [
                    "Authorization": "Bearer token",
                    "X-Workspace": "keep-talking",
                ],
                scope: "repo"
            )
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(KeepTalkingMCPBundle.self, from: data)
        #expect(decoded == bundle)
    }

    @Test("HTTP bundle supports empty headers")
    func httpBundleRoundTripNoHeaders() throws {
        let url = try #require(URL(string: "https://example.com/mcp"))
        let bundle = KeepTalkingMCPBundle(
            name: "plain-http",
            indexDescription: "Plain HTTP MCP",
            service: .http(
                url: url,
                payload: Data(),
                headers: [:],
                scope: nil
            )
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(KeepTalkingMCPBundle.self, from: data)
        #expect(decoded == bundle)
    }
}
