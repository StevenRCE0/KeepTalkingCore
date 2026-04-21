import FluentKit
import Foundation

extension KeepTalkingClient {
    public func aliasLookup() async throws -> KeepTalkingAliasLookup {
        KeepTalkingClient.aliasLookup(
            mappings: try await KeepTalkingMapping.query(on: localStore.database)
                .all()
        )
    }

    public static func aliasLookup(mappings: [KeepTalkingMapping])
        -> KeepTalkingAliasLookup
    {
        KeepTalkingAliasLookup(mappings: mappings)
    }

    public static func mappings(
        for target: KeepTalkingMappingTarget,
        includeDeleted: Bool = false,
        on database: any Database
    ) async throws -> [KeepTalkingMapping] {
        try await queryMappings(
            for: target,
            includeDeleted: includeDeleted,
            on: database
        )
        .sort(\.$value, .ascending)
        .all()
    }

    public func mappings(
        for target: KeepTalkingMappingTarget,
        includeDeleted: Bool = false
    ) async throws -> [KeepTalkingMapping] {
        try await Self.mappings(
            for: target,
            includeDeleted: includeDeleted,
            on: localStore.database
        )
    }

    public static func alias(
        for target: KeepTalkingMappingTarget,
        on database: any Database
    ) async throws -> String? {
        try await queryMappings(for: target, on: database)
            .filter(\.$kind, .equal, .alias)
            .first()?
            .value
    }

    public func alias(for target: KeepTalkingMappingTarget) async throws -> String? {
        try await Self.alias(for: target, on: localStore.database)
    }

    public static func tags(
        for target: KeepTalkingMappingTarget,
        namespace: String? = nil,
        on database: any Database
    ) async throws -> [KeepTalkingMapping] {
        try await queryMappings(
            for: target,
            on: database
        )
        .filter(\.$kind, .equal, .tag)
        .filter(\.$namespace == KeepTalkingMapping.normalizeOptional(namespace))
        .sort(\.$value, .ascending)
        .all()
    }

    public func tags(
        for target: KeepTalkingMappingTarget,
        namespace: String? = nil
    ) async throws -> [KeepTalkingMapping] {
        try await Self.tags(
            for: target,
            namespace: namespace,
            on: localStore.database
        )
    }

    public static func setAlias(
        _ alias: String?,
        for target: KeepTalkingMappingTarget,
        on database: any Database
    ) async throws {
        let value = KeepTalkingMapping.normalizeStoredValue(alias ?? "")
        let existing = try await queryMappings(for: target, includeDeleted: true, on: database)
            .filter(\.$kind, .equal, .alias)
            .all()

        if value.isEmpty {
            try await softDeleteMappings(
                existing.filter { $0.deletedAt == nil },
                on: database)
            return
        }

        let primary =
            existing.first
            ?? KeepTalkingMapping(
                target: target,
                kind: .alias,
                value: value
            )
        primary.namespace = nil
        primary.value = value
        primary.normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
        primary.deletedAt = nil
        try await primary.save(on: database)

        try await softDeleteMappings(Array(existing.dropFirst()), on: database)
    }

    public func setAlias(
        _ alias: String?,
        for target: KeepTalkingMappingTarget
    ) async throws {
        try await Self.setAlias(
            alias,
            for: target,
            on: localStore.database
        )
    }

    public static func addTag(
        _ value: String,
        namespace: String? = nil,
        to target: KeepTalkingMappingTarget,
        on database: any Database
    ) async throws {
        let storedValue = KeepTalkingMapping.normalizeStoredValue(value)
        guard !storedValue.isEmpty else {
            throw KeepTalkingMappingError.emptyValue
        }

        let normalizedNamespace = KeepTalkingMapping.normalizeOptional(namespace)
        let normalizedValue = KeepTalkingMapping.normalizeLookupValue(storedValue)
        let existing = try await queryMappings(
            for: target,
            includeDeleted: true,
            on: database
        )
        .filter(\.$kind, .equal, .tag)
        .filter(\.$namespace == normalizedNamespace)
        .filter(\.$normalizedValue == normalizedValue)
        .first()
        let colorHex = try await tagColorHex(
            namespace: normalizedNamespace,
            normalizedValue: normalizedValue,
            on: database
        )

        let mapping =
            existing
            ?? KeepTalkingMapping(
                target: target,
                kind: .tag,
                namespace: normalizedNamespace,
                value: storedValue,
                colorHex: colorHex
            )
        mapping.namespace = normalizedNamespace
        if existing == nil || mapping.deletedAt != nil {
            mapping.value = storedValue
            mapping.normalizedValue = normalizedValue
        }
        mapping.colorHex = KeepTalkingMapping.normalizeOptional(
            mapping.colorHex ?? colorHex
        )
        mapping.deletedAt = nil
        try await mapping.save(on: database)
    }

    public func addTag(
        _ value: String,
        namespace: String? = nil,
        to target: KeepTalkingMappingTarget,
    ) async throws {
        try await Self.addTag(
            value,
            namespace: namespace,
            to: target,
            on: localStore.database
        )
    }

    public static func removeTag(
        _ value: String,
        namespace: String? = nil,
        from target: KeepTalkingMappingTarget,
        on database: any Database
    ) async throws {
        let normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
        guard !normalizedValue.isEmpty else {
            return
        }

        let normalizedNamespace = KeepTalkingMapping.normalizeOptional(namespace)
        let existing = try await queryMappings(for: target, on: database)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == normalizedNamespace)
            .filter(\.$normalizedValue == normalizedValue)
            .all()

        try await softDeleteMappings(existing, on: database)
    }

    public func removeTag(
        _ value: String,
        namespace: String? = nil,
        from target: KeepTalkingMappingTarget
    ) async throws {
        try await Self.removeTag(
            value,
            namespace: namespace,
            from: target,
            on: localStore.database
        )
    }

    private static func queryMappings(
        for target: KeepTalkingMappingTarget,
        includeDeleted: Bool = false,
        on database: any Database
    ) -> QueryBuilder<KeepTalkingMapping> {
        let query = KeepTalkingMapping.query(on: database)
        let scopedQuery =
            switch target {
                case .node(let node):
                    query
                        .filter(\.$node.$id == node)
                        .filter(\.$context.$id == nil)
                case .context(let context):
                    query
                        .filter(\.$context.$id == context)
                        .filter(\.$node.$id == nil)
                case .thread(let thread):
                    query
                        .filter(\.$thread == thread)
                        .filter(\.$node.$id == nil)
                        .filter(\.$context.$id == nil)
            }

        guard !includeDeleted else {
            return scopedQuery
        }

        return scopedQuery.filter(\.$deletedAt == nil)
    }

    private static func softDeleteMappings(
        _ mappings: [KeepTalkingMapping],
        on database: any Database
    ) async throws {
        guard !mappings.isEmpty else {
            return
        }

        let deletedAt = Date()
        for mapping in mappings {
            mapping.deletedAt = deletedAt
            try await mapping.save(on: database)
        }
    }

    private static func tagColorHex(
        namespace: String?,
        normalizedValue: String,
        on database: any Database
    ) async throws -> String {
        try await KeepTalkingMapping.query(on: database)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == namespace)
            .filter(\.$normalizedValue == normalizedValue)
            .sort(\.$createdAt, .ascending)
            .first()?
            .colorHex
            ?? KeepTalkingMapping.randomColorHex()
    }
}
