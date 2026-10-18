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
    /// When the sender sent it, on its node-status clock (wall-clock
    /// milliseconds that never step back): newer wins, and a newer one saying
    /// the same thing changes nothing — so re-sending as-is costs nothing.
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

/// Which of the local node's aliases a sharing decision is about.
public enum KeepTalkingAliasLayer: String, Codable, Hashable, Sendable {
    /// The global alias — shared with trusted nodes.
    case global
    /// The alias scoped to one context — shared with its members.
    case scoped
}

/// The local node's sharing in one context: which alias rows it has there,
/// and the user's decision for each. A nil decision is undecided, which
/// shares by default.
public struct KeepTalkingContextAliasSharing: Hashable, Sendable {
    /// Whether a global alias with something in it exists.
    public let hasGlobal: Bool
    /// Whether an alias scoped to this context with something in it exists.
    public let hasScoped: Bool
    public let global: Bool?
    public let scoped: Bool?

    public init(hasGlobal: Bool, hasScoped: Bool, global: Bool?, scoped: Bool?) {
        self.hasGlobal = hasGlobal
        self.hasScoped = hasScoped
        self.global = global
        self.scoped = scoped
    }

    /// Whether the user has decided anything for this context.
    public var isDecided: Bool {
        global != nil || scoped != nil
    }

    /// What actually goes out: each alias that exists, unless the user
    /// turned it off here.
    public var sharesGlobal: Bool { hasGlobal && (global ?? true) }
    public var sharesScoped: Bool { hasScoped && (scoped ?? true) }
}
