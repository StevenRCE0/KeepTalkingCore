import Foundation

public struct KeepTalkingAliasResolution: Sendable, Hashable {
    public let alias: String?
    public let id: UUID?
    public let fallback: String?

    public init(alias: String?, id: UUID?, fallback: String? = nil) {
        self.alias = alias
        self.id = id
        self.fallback = fallback
    }

    public func idText(uppercase: Bool = true) -> String? {
        guard let id else {
            return nil
        }
        return uppercase ? id.uuidString.uppercased() : id.uuidString.lowercased()
    }

    public func primary(uppercaseID: Bool = true) -> String {
        alias ?? fallback ?? idText(uppercase: uppercaseID) ?? "Unknown"
    }

    public func secondary(uppercaseID: Bool = true) -> String? {
        guard alias != nil else {
            return nil
        }
        return idText(uppercase: uppercaseID)
    }

    public func combined(
        includeID: Bool = true,
        uppercaseID: Bool = false
    ) -> String {
        let primary = primary(uppercaseID: uppercaseID)
        guard includeID, let idText = idText(uppercase: uppercaseID), alias != nil
        else {
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

    public func resolve(_ target: KeepTalkingMappingTarget, fallback: String? = nil) -> KeepTalkingAliasResolution {
        KeepTalkingAliasResolution(
            alias: alias(for: target),
            id: target.id,
            fallback: fallback
        )
    }

    public func resolve(sender: KeepTalkingContextMessage.Sender, fallback: String? = nil)
        -> KeepTalkingAliasResolution
    {
        switch sender {
            case .node(let node):
                return resolve(.node(node), fallback: fallback)
            case .autonomous(let name):
                return KeepTalkingAliasResolution(
                    alias: nil,
                    id: nil,
                    fallback: fallback ?? name
                )
        }
    }
}
