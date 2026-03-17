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

    @Test("HTTP bundle preserves OAuth registration metadata")
    func httpBundleRoundTripOAuthRegistration() throws {
        let url = try #require(URL(string: "https://mcp.example.com"))
        let authorizationEndpoint = try #require(
            URL(string: "https://auth.example.com/authorize")
        )
        let tokenEndpoint = try #require(
            URL(string: "https://auth.example.com/token")
        )
        let registrationEndpoint = try #require(
            URL(string: "https://auth.example.com/register")
        )
        let resource = try #require(URL(string: "https://mcp.example.com/resource"))
        let discoveredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let authenticatedAt = Date(timeIntervalSince1970: 1_700_000_120)

        let bundle = KeepTalkingMCPBundle(
            name: "oauth-http",
            indexDescription: "OAuth HTTP MCP",
            service: .http(
                url: url,
                payload: Data(),
                headers: ["Authorization": "Bearer token"],
                scope: "repo read:org"
            ),
            oauthRegistration: KeepTalkingMCPOAuthRegistration(
                flow: .authorizationCode,
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: registrationEndpoint,
                resource: resource,
                clientID: "keep-talking-client",
                scope: "repo read:org",
                providerID: "GITHUB",
                discoveredAt: discoveredAt,
                lastAuthenticatedAt: authenticatedAt
            )
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(KeepTalkingMCPBundle.self, from: data)
        #expect(decoded == bundle)
    }

    @Test("OAuth registration updates last authenticated timestamp immutably")
    func oauthRegistrationMarksAuthenticated() throws {
        let registration = KeepTalkingMCPOAuthRegistration(
            flow: .deviceCode,
            authorizationEndpoint: try #require(
                URL(string: "https://auth.example.com/authorize")
            ),
            tokenEndpoint: try #require(
                URL(string: "https://auth.example.com/token")
            )
        )
        let authenticatedAt = Date(timeIntervalSince1970: 1_700_000_500)

        let updated = registration.markingAuthenticated(at: authenticatedAt)

        #expect(registration.lastAuthenticatedAt == nil)
        #expect(updated.lastAuthenticatedAt == authenticatedAt)
    }
}
