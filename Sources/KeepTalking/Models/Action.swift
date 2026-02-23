import Foundation

public enum KeepTalkingAction: Identifiable, Codable, Sendable, Hashable {
    case mcpBundle(KeepTalkingMCPBundle)

    public var id: UUID {
        switch self {
        case let .mcpBundle(bundle):
            return bundle.id
        }
    }
}
