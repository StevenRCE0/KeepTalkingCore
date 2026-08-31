import Foundation

public struct KeepTalkingAliasResolution: Sendable, Hashable {

    public enum IDDisplayMode: Sendable, Hashable {
        case uppercase, lowercase, friendly, raw
        /// `amber-swift-koala` — the friendly name as a single hyphenated
        /// token. This is the form for anything an agent reads and types back:
        /// one word-shaped token with no spaces to lose, and exactly what
        /// `UUIDFriendlyName.resolve` matches on.
        case friendlyToken
    }

    public let alias: String?
    public let id: UUID?
    public let fallback: String?

    public init(alias: String?, id: UUID?, fallback: String? = nil) {
        self.alias = alias
        self.id = id
        self.fallback = fallback
    }

    /// True when no explicit alias was set — the displayed name is a fallback (friendly name or UUID).
    public var isFallback: Bool { alias == nil }

    public func idText(_ mode: IDDisplayMode = .friendly) -> String? {
        guard let id else { return nil }
        switch mode {
            case .uppercase: return id.uuidString.uppercased()
            case .lowercase: return id.uuidString.lowercased()
            case .friendly: return id.friendlyName
            case .friendlyToken: return id.friendlyNameToken
            case .raw: return id.uuidString
        }
    }

    public func primary(_ mode: IDDisplayMode = .friendly) -> String {
        alias ?? fallback ?? idText(mode) ?? "Unknown"
    }

    public func secondary(_ mode: IDDisplayMode = .friendly) -> String? {
        guard alias != nil else { return nil }
        return idText(mode)
    }

    public func combined(
        includeID: Bool = true,
        _ mode: IDDisplayMode = .friendly
    ) -> String {
        let primary = primary(mode)
        guard includeID, let idText = idText(mode), alias != nil else {
            return primary
        }
        return "\(primary) (\(idText))"
    }
}

public struct KeepTalkingAliasLookup: Sendable {
    /// Global aliases (`scope_context IS NULL`).
    private let aliases: [KeepTalkingMappingTarget: String]
    /// Context-scoped aliases, bucketed by scope context id. Scoped rows never
    /// enter the global map — callers opt in via `alias(for:in:)` or a
    /// `scoped(to:)` view.
    private let scopedAliases: [UUID: [KeepTalkingMappingTarget: String]]

    public init(mappings: [KeepTalkingMapping]) {
        var aliases: [KeepTalkingMappingTarget: String] = [:]
        var scopedAliases: [UUID: [KeepTalkingMappingTarget: String]] = [:]
        for mapping in mappings where mapping.kind == .alias && mapping.deletedAt == nil {
            guard let target = mapping.target else {
                continue
            }
            let alias = KeepTalkingMapping.normalizeStoredValue(mapping.value)
            guard !alias.isEmpty else {
                continue
            }
            if let scope = mapping.$scopeContext.id {
                scopedAliases[scope, default: [:]][target] = alias
            } else {
                aliases[target] = alias
            }
        }
        self.aliases = aliases
        self.scopedAliases = scopedAliases
    }

    private init(
        aliases: [KeepTalkingMappingTarget: String],
        scopedAliases: [UUID: [KeepTalkingMappingTarget: String]]
    ) {
        self.aliases = aliases
        self.scopedAliases = scopedAliases
    }

    /// A lookup whose plain accessors resolve as seen from the given context —
    /// that context's scoped aliases overlaid on the global map. Scope one
    /// lookup at construction instead of threading a context id through every
    /// downstream helper. `nil` (or an unknown scope) returns self, so the
    /// call is always safe.
    public func scoped(to scopeContextID: UUID?) -> KeepTalkingAliasLookup {
        guard
            let scopeContextID,
            let bucket = scopedAliases[scopeContextID],
            !bucket.isEmpty
        else {
            return self
        }
        return KeepTalkingAliasLookup(
            aliases: aliases.merging(bucket) { _, scoped in scoped },
            scopedAliases: scopedAliases
        )
    }

    public func alias(for target: KeepTalkingMappingTarget) -> String? {
        aliases[target]
    }

    /// Scoped-first resolution: the context's alias for the target if one
    /// exists, else the global alias.
    public func alias(
        for target: KeepTalkingMappingTarget,
        in scopeContextID: UUID?
    ) -> String? {
        if let scopeContextID, let scoped = scopedAliases[scopeContextID]?[target] {
            return scoped
        }
        return aliases[target]
    }

    public func resolve(
        _ target: KeepTalkingMappingTarget,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        resolve(target, in: nil, fallback: fallback)
    }

    public func resolve(
        _ target: KeepTalkingMappingTarget,
        in scopeContextID: UUID?,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        KeepTalkingAliasResolution(
            alias: alias(for: target, in: scopeContextID),
            id: target.id,
            fallback: fallback
        )
    }

    public func resolve(
        sender: KeepTalkingContextMessage.Sender,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        resolve(sender: sender, in: nil, fallback: fallback)
    }

    public func resolve(
        sender: KeepTalkingContextMessage.Sender,
        in scopeContextID: UUID?,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        switch sender {
            case .node(let node):
                return resolve(.node(node), in: scopeContextID, fallback: fallback)
            case .autonomous(let name, let node, _):
                let label: String
                if let node {
                    let nodeName = resolve(.node(node), in: scopeContextID).primary()
                    label = "\(name) · \(nodeName)"
                } else {
                    label = name
                }
                return KeepTalkingAliasResolution(
                    alias: label,
                    id: nil,
                    fallback: fallback
                )
        }
    }
}
