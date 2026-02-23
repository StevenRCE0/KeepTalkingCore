import Foundation

public enum KeepTalkingMCPService: Codable, Sendable, Hashable {
    case stdio(arguments: [String])
    case http(url: URL, payload: Data, headers: [String: String])
}

public struct KeepTalkingMCPBundle: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var indexDescription: String
    public var service: KeepTalkingMCPService

    public init(
        id: UUID = UUID(),
        indexDescription: String,
        service: KeepTalkingMCPService
    ) {
        self.id = id
        self.indexDescription = indexDescription
        self.service = service
    }
}
