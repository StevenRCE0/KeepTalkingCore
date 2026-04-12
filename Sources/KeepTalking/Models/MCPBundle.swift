import Foundation

public struct KeepTalkingMCPOAuthRegistration: Codable, Sendable, Hashable {
    public enum Flow: String, Codable, Sendable, Hashable {
        case authorizationCode
        case deviceCode
    }

    public var flow: Flow
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var resource: URL?
    public var clientID: String?
    public var scope: String?
    public var providerID: String?
    public var discoveredAt: Date
    public var lastAuthenticatedAt: Date?

    public init(
        flow: Flow,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        resource: URL? = nil,
        clientID: String? = nil,
        scope: String? = nil,
        providerID: String? = nil,
        discoveredAt: Date = .now,
        lastAuthenticatedAt: Date? = nil
    ) {
        self.flow = flow
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.resource = resource
        self.clientID = clientID
        self.scope = scope
        self.providerID = providerID
        self.discoveredAt = discoveredAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    public func markingAuthenticated(at date: Date = .now)
        -> KeepTalkingMCPOAuthRegistration
    {
        var updated = self
        updated.lastAuthenticatedAt = date
        return updated
    }
}

public struct KeepTalkingMCPBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var service: KeepTalkingMCPService
    public var oauthRegistration: KeepTalkingMCPOAuthRegistration?

    /// Per-tool permission requirements for this MCP server.
    ///
    /// When a remote node requests the tool list the grant mask is intersected
    /// with each tool's declared requirements: tools whose required bits are
    /// not all present in the grant mask are stripped from the response.
    /// Tools absent from this map default to `.read`.
    public var toolPermissions: [String: KeepTalkingActionPermissionMask]?

    public init(
        id: UUID = UUID(),
        name: String,
        indexDescription: String,
        service: KeepTalkingMCPService,
        oauthRegistration: KeepTalkingMCPOAuthRegistration? = nil,
        toolPermissions: [String: KeepTalkingActionPermissionMask]? = nil
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.service = service
        self.oauthRegistration = oauthRegistration
        self.toolPermissions = toolPermissions
    }
}

public enum KeepTalkingMCPService: Codable, Sendable, Hashable {
    case stdio(arguments: [String], environment: [String: String])
    case http(url: URL, payload: Data, headers: [String: String], scope: String?)

    private enum CodingKeys: String, CodingKey {
        case stdio
        case http
    }

    private enum StdioCodingKeys: String, CodingKey {
        case arguments
        case environment
    }

    private enum HTTPCodingKeys: String, CodingKey {
        case url
        case payload
        case headers
        case scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.stdio) {
            let stdio = try container.nestedContainer(
                keyedBy: StdioCodingKeys.self,
                forKey: .stdio
            )
            let arguments = try stdio.decode([String].self, forKey: .arguments)
            let environment =
                try stdio.decodeIfPresent(
                    [String: String].self,
                    forKey: .environment
                ) ?? [:]
            self = .stdio(arguments: arguments, environment: environment)
            return
        }

        if container.contains(.http) {
            let http = try container.nestedContainer(
                keyedBy: HTTPCodingKeys.self,
                forKey: .http
            )
            let url = try http.decode(URL.self, forKey: .url)
            let payload = try http.decode(Data.self, forKey: .payload)
            let headers = try http.decode(
                [String: String].self,
                forKey: .headers
            )
            let scope = try http.decodeIfPresent(String.self, forKey: .scope)
            self = .http(
                url: url,
                payload: payload,
                headers: headers,
                scope: scope
            )
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: container.codingPath,
                debugDescription: "Unsupported MCP service payload."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .stdio(let arguments, let environment):
                var stdio = container.nestedContainer(
                    keyedBy: StdioCodingKeys.self,
                    forKey: .stdio
                )
                try stdio.encode(arguments, forKey: .arguments)
                if !environment.isEmpty {
                    try stdio.encode(environment, forKey: .environment)
                }
            case .http(let url, let payload, let headers, let scope):
                var http = container.nestedContainer(
                    keyedBy: HTTPCodingKeys.self,
                    forKey: .http
                )
                try http.encode(url, forKey: .url)
                try http.encode(payload, forKey: .payload)
                try http.encode(headers, forKey: .headers)
                if let scope, !scope.isEmpty {
                    try http.encode(scope, forKey: .scope)
                }
        }
    }
}
