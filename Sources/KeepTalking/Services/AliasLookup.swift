import Foundation

public struct KeepTalkingAliasResolution: Sendable, Hashable {

    public enum IDDisplayMode: Sendable, Hashable {
        case uppercase, lowercase, friendly, raw
        case friendlyToken
    }

    public let alias: String?
    public let id: UUID?
    public let fallback: String?
    public let appearance: KeepTalkingMappingAppearance?
    public let suggestion: Suggestion?

    public struct Suggestion: Sendable, Hashable {
        public let name: String?
        public let appearance: KeepTalkingMappingAppearance?

        public init(name: String?, appearance: KeepTalkingMappingAppearance?) {
            self.name = name
            self.appearance = appearance
        }

        func overlaying(_ base: Self?) -> Self {
            guard let base else { return self }
            return Self(
                name: name ?? base.name,
                appearance: appearance.map { $0.overlaying(base.appearance) } ?? base.appearance
            )
        }
    }

    public init(
        alias: String?,
        id: UUID?,
        fallback: String? = nil,
        appearance: KeepTalkingMappingAppearance? = nil,
        suggestion: Suggestion? = nil
    ) {
        self.alias = alias
        self.id = id
        self.fallback = fallback
        self.appearance = appearance
        self.suggestion = suggestion
    }

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
    /// What one alias row says, the parts it leaves unset nil.
    private struct Entry: Sendable {
        var alias: String?
        var appearance: KeepTalkingMappingAppearance?
        var suggestion: KeepTalkingAliasResolution.Suggestion?

        /// `self` over `base`, property by property.
        func overlaying(_ base: Entry?) -> Entry {
            guard let base else { return self }
            return Entry(
                alias: alias ?? base.alias,
                appearance: appearance.map { $0.overlaying(base.appearance) } ?? base.appearance,
                suggestion: suggestion.map { $0.overlaying(base.suggestion) } ?? base.suggestion
            )
        }
    }

    /// Global alias rows (`scope_context IS NULL`).
    private let entries: [KeepTalkingMappingTarget: Entry]
    /// Context-scoped alias rows
    private let scopedEntries: [UUID: [KeepTalkingMappingTarget: Entry]]

    public init(mappings: [KeepTalkingMapping]) {
        var entries: [KeepTalkingMappingTarget: Entry] = [:]
        var scopedEntries: [UUID: [KeepTalkingMappingTarget: Entry]] = [:]
        for mapping in mappings where mapping.kind == .alias && mapping.deletedAt == nil {
            guard let target = mapping.target else {
                continue
            }
            let entry = Entry(
                alias: KeepTalkingMapping.normalizeOptional(mapping.value),
                appearance: mapping.appearance,
                suggestion: mapping.suggestion.map {
                    .init(name: $0.alias.name, appearance: $0.alias.appearance)
                }
            )
            guard entry.alias != nil || entry.appearance != nil || entry.suggestion != nil else {
                continue
            }
            if let scope = mapping.$scopeContext.id {
                scopedEntries[scope, default: [:]][target] = entry
            } else {
                entries[target] = entry
            }
        }
        self.entries = entries
        self.scopedEntries = scopedEntries
    }

    private init(
        entries: [KeepTalkingMappingTarget: Entry],
        scopedEntries: [UUID: [KeepTalkingMappingTarget: Entry]]
    ) {
        self.entries = entries
        self.scopedEntries = scopedEntries
    }

    /// A lookup whose plain accessors resolve as seen from the given context —
    /// that context's scoped rows overlaid on the global map. Scope one
    /// lookup at construction instead of threading a context id through every
    /// downstream helper. `nil` (or an unknown scope) returns self, so the
    /// call is always safe.
    public func scoped(to scopeContextID: UUID?) -> KeepTalkingAliasLookup {
        guard
            let scopeContextID,
            let bucket = scopedEntries[scopeContextID],
            !bucket.isEmpty
        else {
            return self
        }
        return KeepTalkingAliasLookup(
            entries: entries.merging(bucket) { global, scoped in scoped.overlaying(global) },
            scopedEntries: scopedEntries
        )
    }

    /// The target's row as seen from `scopeContextID`: the scoped row over the
    /// global one, property by property.
    private func entry(
        for target: KeepTalkingMappingTarget,
        in scopeContextID: UUID?
    ) -> Entry? {
        guard let scopeContextID, let scoped = scopedEntries[scopeContextID]?[target] else {
            return entries[target]
        }
        return scoped.overlaying(entries[target])
    }

    public func alias(for target: KeepTalkingMappingTarget) -> String? {
        entries[target]?.alias
    }

    /// Scoped-first resolution: the context's alias for the target if one
    /// exists, else the global alias.
    public func alias(
        for target: KeepTalkingMappingTarget,
        in scopeContextID: UUID?
    ) -> String? {
        entry(for: target, in: scopeContextID)?.alias
    }

    public func appearance(for target: KeepTalkingMappingTarget) -> KeepTalkingMappingAppearance? {
        entries[target]?.appearance
    }

    /// Scoped-first per property: what the context's alias row sets, with
    /// every property it leaves unset taken from the global row.
    public func appearance(
        for target: KeepTalkingMappingTarget,
        in scopeContextID: UUID?
    ) -> KeepTalkingMappingAppearance? {
        entry(for: target, in: scopeContextID)?.appearance
    }

    /// What the target shared about itself, as seen from `scopeContextID`:
    /// the context's shared alias over the global one, property by property.
    public func suggestion(
        for target: KeepTalkingMappingTarget,
        in scopeContextID: UUID? = nil
    ) -> KeepTalkingAliasResolution.Suggestion? {
        entry(for: target, in: scopeContextID)?.suggestion
    }

    /// Every context-scoped alias the target carries, keyed by scope context
    /// id, with no global fallback — what a per-context name editor lists.
    public func contextAliases(
        for target: KeepTalkingMappingTarget
    ) -> [UUID: String] {
        scopedEntries.compactMapValues { $0[target]?.alias }
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
        let entry = entry(for: target, in: scopeContextID)
        return KeepTalkingAliasResolution(
            alias: entry?.alias,
            id: target.id,
            fallback: fallback,
            appearance: entry?.appearance,
            suggestion: entry?.suggestion
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
