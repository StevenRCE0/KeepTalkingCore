import Foundation

public struct KeepTalkingAliasResolution: Sendable, Hashable {

    public enum IDDisplayMode: Sendable, Hashable {
        case uppercase, lowercase, friendly, raw
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
    private let aliases: [KeepTalkingMappingTarget: String]

    public init(mappings: [KeepTalkingMapping]) {
        var aliases: [KeepTalkingMappingTarget: String] = [:]
        for mapping in mappings where mapping.kind == .alias && mapping.deletedAt == nil {
            guard let target = mapping.target else {
                continue
            }
            let alias = KeepTalkingMapping.normalizeStoredValue(mapping.value)
            guard !alias.isEmpty else {
                continue
            }
            aliases[target] = alias
        }
        self.aliases = aliases
    }

    public func alias(for target: KeepTalkingMappingTarget) -> String? {
        aliases[target]
    }

    public func resolve(
        _ target: KeepTalkingMappingTarget,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        KeepTalkingAliasResolution(
            alias: alias(for: target),
            id: target.id,
            fallback: fallback
        )
    }

    public func resolve(
        sender: KeepTalkingContextMessage.Sender,
        fallback: String? = nil
    ) -> KeepTalkingAliasResolution {
        switch sender {
            case .node(let node):
                return resolve(.node(node), fallback: fallback)
            case .autonomous(let name, let nodeName, let model):
                // Build a descriptive fallback: "roleName · Node Alias · model" when available.
                var components: [String] = [name]
                if let nodeName, !nodeName.isEmpty {
                    components.append(nodeName)
                }
                if let model, !model.isEmpty {
                    components.append(model)
                }

                return KeepTalkingAliasResolution(
                    alias: nil,
                    id: nil,
                    fallback: fallback ?? components.joined(separator: " · ")
                )
        }
    }
}
