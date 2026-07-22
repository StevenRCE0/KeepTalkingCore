import Foundation

/// The contexts in which a node-relation grant may be used.
///
/// Action and alias grants share this type so their scoping semantics cannot
/// drift as the trust model evolves.
public enum KeepTalkingNodeRelationApprovingContext: Codable, Sendable {
    case all
    case contexts([KeepTalkingContext])

    public func applicable(in context: KeepTalkingContext?) -> Bool {
        switch self {
            case .all:
                return true
            case .contexts(let contexts):
                guard let context else { return false }
                return contexts.contains(context)
        }
    }
}
