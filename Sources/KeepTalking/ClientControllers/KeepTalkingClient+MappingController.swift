import FluentKit
import Foundation

extension KeepTalkingClient {
    public func mappings(
        for target: KeepTalkingMappingTarget,
        includeDeleted: Bool = false
    ) async throws -> [KeepTalkingMapping] {
        try await queryMappings(for: target, includeDeleted: includeDeleted)
            .sort(\.$value, .ascending)
            .all()
    }

    public func alias(for target: KeepTalkingMappingTarget) async throws -> String? {
        try await queryMappings(for: target)
            .filter(\.$kind, .equal, .alias)
            .first()?
            .value
    }

    public func tags(
        for target: KeepTalkingMappingTarget,
        namespace: String? = nil
    ) async throws -> [KeepTalkingMapping] {
        try await queryMappings(for: target)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == KeepTalkingMapping.normalizeOptional(namespace))
            .sort(\.$value, .ascending)
            .all()
    }

    public func setAlias(
        _ alias: String?,
        for target: KeepTalkingMappingTarget
    ) async throws {
        let value = KeepTalkingMapping.normalizeStoredValue(alias ?? "")
        let existing = try await queryMappings(for: target, includeDeleted: true)
            .filter(\.$kind, .equal, .alias)
            .all()

        if value.isEmpty {
            try await softDeleteMappings(existing.filter { $0.deletedAt == nil })
            return
        }

        let primary = existing.first ?? KeepTalkingMapping(
            target: target,
            kind: .alias,
            value: value
        )
        primary.namespace = nil
        primary.value = value
        primary.normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
        primary.deletedAt = nil
        try await primary.save(on: localStore.database)

        try await softDeleteMappings(Array(existing.dropFirst()))
    }

    public func addTag(
        _ value: String,
        namespace: String? = nil,
        to target: KeepTalkingMappingTarget
    ) async throws {
        let storedValue = KeepTalkingMapping.normalizeStoredValue(value)
        guard !storedValue.isEmpty else {
            throw KeepTalkingMappingError.emptyValue
        }

        let normalizedNamespace = KeepTalkingMapping.normalizeOptional(namespace)
        let normalizedValue = KeepTalkingMapping.normalizeLookupValue(storedValue)
        let existing = try await queryMappings(for: target, includeDeleted: true)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == normalizedNamespace)
            .filter(\.$normalizedValue == normalizedValue)
            .first()

        let mapping = existing ?? KeepTalkingMapping(
            target: target,
            kind: .tag,
            namespace: normalizedNamespace,
            value: storedValue
        )
        mapping.namespace = normalizedNamespace
        if existing == nil || mapping.deletedAt != nil {
            mapping.value = storedValue
            mapping.normalizedValue = normalizedValue
        }
        mapping.deletedAt = nil
        try await mapping.save(on: localStore.database)
    }

    public func removeTag(
        _ value: String,
        namespace: String? = nil,
        from target: KeepTalkingMappingTarget
    ) async throws {
        let normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
        guard !normalizedValue.isEmpty else {
            return
        }

        let normalizedNamespace = KeepTalkingMapping.normalizeOptional(namespace)
        let existing = try await queryMappings(for: target)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == normalizedNamespace)
            .filter(\.$normalizedValue == normalizedValue)
            .all()

        try await softDeleteMappings(existing)
    }

    private func queryMappings(
        for target: KeepTalkingMappingTarget,
        includeDeleted: Bool = false
    ) -> QueryBuilder<KeepTalkingMapping> {
        let query = KeepTalkingMapping.query(on: localStore.database)
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
            }

        guard !includeDeleted else {
            return scopedQuery
        }

        return scopedQuery.filter(\.$deletedAt == nil)
    }

    private func softDeleteMappings(_ mappings: [KeepTalkingMapping]) async throws {
        guard !mappings.isEmpty else {
            return
        }

        let deletedAt = Date()
        for mapping in mappings {
            mapping.deletedAt = deletedAt
            try await mapping.save(on: localStore.database)
        }
    }
}
