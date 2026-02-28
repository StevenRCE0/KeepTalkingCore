import Foundation

public struct KeepTalkingMCPBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var service: KeepTalkingMCPService

    public init(
        id: UUID = UUID(),
        name: String,
        indexDescription: String,
        service: KeepTalkingMCPService
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.service = service
    }
}

public enum KeepTalkingMCPService: Codable, Sendable, Hashable {
    case stdio(arguments: [String], environment: [String: String])
    case http(url: URL, payload: Data, headers: [String: String])

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
            self = .http(url: url, payload: payload, headers: headers)
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
            case .http(let url, let payload, let headers):
                var http = container.nestedContainer(
                    keyedBy: HTTPCodingKeys.self,
                    forKey: .http
                )
                try http.encode(url, forKey: .url)
                try http.encode(payload, forKey: .payload)
                try http.encode(headers, forKey: .headers)
        }
    }
}
