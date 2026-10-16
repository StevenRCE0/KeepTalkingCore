import Foundation

/// The alias a node publishes about itself: a name and an appearance, either
/// for one context or (nil `contextID`) for everywhere.
///
/// A context-scoped one goes to every member of that context; the global one
/// only to trusted nodes. On the receiving side it is stored as the target's
/// ``KeepTalkingAliasSuggestion`` — what the node calls itself, never what the
/// user calls it.
public struct KeepTalkingSharedAlias: Codable, Hashable, Sendable {
    /// The context this alias applies in; nil for the global alias.
    public var contextID: UUID?
    public var name: String?
    public var appearance: KeepTalkingMappingAppearance?
    /// Grows each time the sender changes this alias; newer wins.
    public var revision: UInt64

    public init(
        contextID: UUID?,
        name: String?,
        appearance: KeepTalkingMappingAppearance?,
        revision: UInt64
    ) {
        self.contextID = contextID
        self.name = KeepTalkingMapping.normalizeOptional(name)
        self.appearance = KeepTalkingMapping.normalizeAppearance(appearance)
        self.revision = revision
    }

    /// No name and no appearance: the sender shares nothing here. Receiving
    /// one clears what was stored.
    public var isEmpty: Bool {
        name == nil && appearance == nil
    }

    /// Whether `other` says the same thing, whatever its revision.
    func hasSameContent(as other: Self) -> Bool {
        name == other.name && appearance == other.appearance
    }
}

/// A shared alias as the receiver keeps it, with how far the user has looked
/// at it.
public struct KeepTalkingAliasSuggestion: Codable, Hashable, Sendable {
    public var alias: KeepTalkingSharedAlias
    /// The revision the user last accepted or ignored.
    public var reviewedRevision: UInt64?

    public init(alias: KeepTalkingSharedAlias, reviewedRevision: UInt64? = nil) {
        self.alias = alias
        self.reviewedRevision = reviewedRevision
    }

    /// A revision the user hasn't accepted or ignored yet.
    public var isPending: Bool {
        alias.revision > (reviewedRevision ?? 0)
    }
}
