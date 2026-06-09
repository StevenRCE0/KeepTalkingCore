import Foundation

/// What a node was *granted* on an action — kept deliberately distinct from
/// `KeepTalkingActionVerb` (what an action is *capable* of) so the two never
/// blur. Default-deny: a `.verbs` scope permits only the structural verbs it
/// lists and the resources its `.named` tokens name; everything else is denied.
/// `.all` is the only wildcard and lives here, never in the verb enum.
///
/// Persisted as the single JSON `scope` column on the grant relation row, and
/// returned by grant resolution. Replaces the old `KeepTalkingGrantPermission`
/// (`.filesystem(mask)` / `.mcp(allowedTools:)` / `.primitive(allowedScopeKeys:)`)
/// and `KeepTalkingActionPermissionMask`.
public enum KeepTalkingActionScope: Codable, Sendable, Hashable {
    /// Unrestricted — the owner default and the seed for "no narrowing".
    case all
    /// An explicit allow-set. `.verbs([])` denies everything.
    case verbs(Set<KeepTalkingActionVerb>)

    /// The unrestricted owner default.
    public static var unrestricted: KeepTalkingActionScope { .all }

    /// Whether this scope grants the structural operation class `verb`. `.named`
    /// tokens are not operation classes and never satisfy this.
    public func allows(_ verb: KeepTalkingActionVerb) -> Bool {
        switch self {
            case .all: return true
            case .verbs(let set): return set.contains(verb)
        }
    }

    /// Whether a named resource is permitted. A non-nil `classWildcard` (e.g.
    /// `.callTool` for MCP = "all tools") grants the whole class when present.
    public func permitsNamed(
        _ name: String,
        classWildcard: KeepTalkingActionVerb? = nil
    ) -> Bool {
        switch self {
            case .all:
                return true
            case .verbs(let set):
                if let classWildcard, set.contains(classWildcard) { return true }
                return set.contains(.named(name))
        }
    }

    /// The named-resource allowlist for executors that gate by `[String]?`
    /// (MCP tools, primitive scope keys): `nil` = all permitted (either `.all`
    /// or the class wildcard is present), otherwise the explicit names (possibly
    /// empty = none). Pass the payload's class wildcard — `.callTool` for MCP,
    /// `nil` for primitives (whose only "all" is `.all`).
    public func allowedNames(
        classWildcard: KeepTalkingActionVerb? = nil
    ) -> [String]? {
        switch self {
            case .all:
                return nil
            case .verbs(let set):
                if let classWildcard, set.contains(classWildcard) { return nil }
                return set.compactMap { verb in
                    if case .named(let name) = verb { return name }
                    return nil
                }
        }
    }

    /// True when the scope grants nothing — an empty `.verbs` set. The uniform
    /// "denied" gate across all payloads.
    public var isDenied: Bool {
        if case .verbs(let set) = self { return set.isEmpty }
        return false
    }

    /// True when the scope imposes no narrowing (`.all`). Callers store `nil`
    /// rather than a grant row in this case (a missing row resolves to `.all`).
    public var isUnrestricted: Bool {
        if case .all = self { return true }
        return false
    }

    /// Folds applicable grants into one: any `.all` member dominates; otherwise
    /// the union of the verb sets. Plain union widens correctly because the
    /// class wildcards (e.g. `.callTool`) survive — `.verbs({.callTool})` ∪
    /// `.verbs({.named("search")})` still allows all tools. An empty input list
    /// yields `.verbs([])` (deny).
    public static func union(
        _ scopes: [KeepTalkingActionScope]
    ) -> KeepTalkingActionScope {
        var merged: Set<KeepTalkingActionVerb> = []
        for scope in scopes {
            switch scope {
                case .all: return .all
                case .verbs(let set): merged.formUnion(set)
            }
        }
        return .verbs(merged)
    }
}
