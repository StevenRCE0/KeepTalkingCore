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
        scopeContextID: UUID? = nil,
        includeDeleted: Bool = false,
        on database: any Database
    ) async throws -> [KeepTalkingMapping] {
        try await queryMappings(
            for: target,
            scopeContextID: scopeContextID,
            includeDeleted: includeDeleted,
            on: database
        )
        .sort(\.$value, .ascending)
        .all()
    }

    public func mappings(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        includeDeleted: Bool = false
    ) async throws -> [KeepTalkingMapping] {
        try await Self.mappings(
            for: target,
            scopeContextID: scopeContextID,
            includeDeleted: includeDeleted,
            on: localStore.database
        )
    }

    public static func alias(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        on database: any Database
    ) async throws -> String? {
        try await queryMappings(
            for: target,
            scopeContextID: scopeContextID,
            on: database
        )
        .filter(\.$kind, .equal, .alias)
        .first()
        // A nameless row (appearance only) is no alias.
        .flatMap { KeepTalkingMapping.normalizeOptional($0.value) }
    }

    public func alias(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil
    ) async throws -> String? {
        try await Self.alias(
            for: target,
            scopeContextID: scopeContextID,
            on: localStore.database
        )
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

    /// Names `target`. A nil or blank alias removes the name — but a row that
    /// still holds something else (an appearance, a suggestion, sharing)
    /// stays, nameless.
    ///
    /// Pass `blobStore` to delete avatar blobs a removed duplicate row leaves
    /// unreferenced; without one they wait for the next stray-blob sweep.
    public static func setAlias(
        _ alias: String?,
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws {
        let value = KeepTalkingMapping.normalizeStoredValue(alias ?? "")
        let existing = try await queryMappings(
            for: target,
            scopeContextID: scopeContextID,
            includeDeleted: true,
            on: database
        )
        .filter(\.$kind, .equal, .alias)
        .all()
        let live = existing.filter { $0.deletedAt == nil }

        let released: Set<String>
        if value.isEmpty {
            for row in live {
                row.value = ""
                row.normalizedValue = ""
            }
            let keeper = live.first { !$0.isVacant }
            try await keeper?.save(on: database)
            released = try await softDeleteMappings(
                live.filter { $0 !== keeper },
                on: database
            )
        } else {
            // A live row first: reviving a deleted one would soft-delete the
            // live row and its appearance with it.
            let primary =
                live.first
                ?? existing.first
                ?? KeepTalkingMapping(
                    target: target,
                    scopeContext: scopeContextID,
                    kind: .alias,
                    value: value
                )
            primary.namespace = nil
            primary.value = value
            primary.normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
            primary.deletedAt = nil
            try await primary.save(on: database)

            released = try await softDeleteMappings(
                existing.filter { $0 !== primary && $0.deletedAt == nil },
                on: database
            )
        }
        try await pruneReleasedBlobs(released, on: database, blobStore: blobStore)
    }

    public func setAlias(
        _ alias: String?,
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil
    ) async throws {
        try await Self.setAlias(
            alias,
            for: target,
            scopeContextID: scopeContextID,
            on: localStore.database,
            blobStore: blobStore
        )
    }

    // MARK: - Appearance

    /// The appearance on `target`'s alias row in exactly this scope — no
    /// scoped-to-global fallback (the alias lookup does that).
    public static func appearance(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        on database: any Database
    ) async throws -> KeepTalkingMappingAppearance? {
        try await queryMappings(
            for: target,
            scopeContextID: scopeContextID,
            on: database
        )
        .filter(\.$kind, .equal, .alias)
        .first()?
        .appearance
    }

    public func appearance(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil
    ) async throws -> KeepTalkingMappingAppearance? {
        try await Self.appearance(
            for: target,
            scopeContextID: scopeContextID,
            on: localStore.database
        )
    }

    /// Sets the appearance on `target`'s alias row, creating a nameless row
    /// when there is no alias yet. Nil or empty clears it, and a row left
    /// holding nothing is removed.
    ///
    /// Pass `blobStore` to delete an avatar blob the change leaves
    /// unreferenced; without one it waits for the next stray-blob sweep.
    public static func setAppearance(
        _ appearance: KeepTalkingMappingAppearance?,
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws {
        let appearance = KeepTalkingMapping.normalizeAppearance(appearance)
        let existing = try await queryMappings(
            for: target,
            scopeContextID: scopeContextID,
            includeDeleted: true,
            on: database
        )
        .filter(\.$kind, .equal, .alias)
        .all()
        let live = existing.first { $0.deletedAt == nil }

        var released = Set<String>()
        if let appearance {
            let primary =
                live
                ?? existing.first
                ?? KeepTalkingMapping(
                    target: target,
                    scopeContext: scopeContextID,
                    kind: .alias,
                    value: ""
                )
            if primary.deletedAt != nil {
                // The name was removed when the row was; only the face returns.
                primary.value = ""
                primary.normalizedValue = ""
                primary.deletedAt = nil
            }
            released = (primary.appearance?.blobIDs ?? []).subtracting(appearance.blobIDs)
            primary.appearance = appearance
            try await primary.save(on: database)
        } else if let live, let current = live.appearance {
            released = current.blobIDs
            live.appearance = nil
            if live.isVacant {
                released.formUnion(try await softDeleteMappings([live], on: database))
            } else {
                try await live.save(on: database)
            }
        }
        try await pruneReleasedBlobs(released, on: database, blobStore: blobStore)
    }

    /// Sets the appearance on `target`'s alias row; see the static form.
    /// Emits `mappingChanges`.
    public func setAppearance(
        _ appearance: KeepTalkingMappingAppearance?,
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil
    ) async throws {
        try await Self.setAppearance(
            appearance,
            for: target,
            scopeContextID: scopeContextID,
            on: localStore.database,
            blobStore: blobStore
        )
        signals.mappingChanges.send(())
    }

    /// Blobs a live mapping references — its avatar or a suggested one —
    /// among `candidates`.
    static func appearanceBlobIDs(
        among candidates: Set<String>,
        on database: any Database
    ) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        return try await mappingBlobIDs(
            KeepTalkingMapping.query(on: database).filter(\.$deletedAt == nil)
        ).intersection(candidates)
    }

    /// Every blob the rows `query` matches reference, avatars and suggested
    /// avatars alike.
    static func mappingBlobIDs(
        _ query: QueryBuilder<KeepTalkingMapping>
    ) async throws -> Set<String> {
        try await query
            .group(.or) { group in
                group.filter(\.$appearance != nil)
                group.filter(\.$suggestion != nil)
            }
            .all()
            .reduce(into: Set<String>()) { $0.formUnion($1.blobIDs) }
    }

    static func pruneReleasedBlobs(
        _ blobIDs: Set<String>,
        on database: any Database,
        blobStore: KeepTalkingBlobStore?
    ) async throws {
        guard let blobStore, !blobIDs.isEmpty else { return }
        try await pruneStrayBlobs(among: blobIDs, on: database, blobStore: blobStore)
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

    /// Repaints every mapping row that carries the given tag — colour is a
    /// property of the tag itself, not of any one target, so all rows (including
    /// soft-deleted ones, which `addTag` revives in place) move together.
    public static func setTagColor(
        _ colorHex: String?,
        forTag value: String,
        namespace: String? = nil,
        on database: any Database
    ) async throws {
        let normalizedValue = KeepTalkingMapping.normalizeLookupValue(value)
        guard !normalizedValue.isEmpty else {
            return
        }

        let normalizedNamespace = KeepTalkingMapping.normalizeOptional(namespace)
        let color = KeepTalkingMapping.normalizeOptional(colorHex)
        let mappings = try await KeepTalkingMapping.query(on: database)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$namespace == normalizedNamespace)
            .filter(\.$normalizedValue == normalizedValue)
            .all()

        for mapping in mappings where mapping.colorHex != color {
            mapping.colorHex = color
            try await mapping.save(on: database)
        }
    }

    public func setTagColor(
        _ colorHex: String?,
        forTag value: String,
        namespace: String? = nil
    ) async throws {
        try await Self.setTagColor(
            colorHex,
            forTag: value,
            namespace: namespace,
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

    /// `scopeContextID` partitions every read and write: nil addresses only
    /// global rows (`scope_context IS NULL`), a context id only that context's
    /// rows — so global and scoped mappings never collide in upserts or
    /// soft-deletes.
    static func queryMappings(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID? = nil,
        includeDeleted: Bool = false,
        on database: any Database
    ) -> QueryBuilder<KeepTalkingMapping> {
        let query = KeepTalkingMapping.query(on: database)
            .filter(\.$scopeContext.$id == scopeContextID)
        let scopedQuery =
            switch target {
                case .node(let node):
                    query
                        .filter(\.$node.$id == node)
                        .filter(\.$context.$id == nil)
                        .filter(\.$thread == nil)
                        .filter(\.$action.$id == nil)
                case .context(let context):
                    query
                        .filter(\.$context.$id == context)
                        .filter(\.$node.$id == nil)
                        .filter(\.$thread == nil)
                        .filter(\.$action.$id == nil)
                case .thread(let thread):
                    query
                        .filter(\.$thread == thread)
                        .filter(\.$node.$id == nil)
                        .filter(\.$context.$id == nil)
                        .filter(\.$action.$id == nil)
                case .action(let action):
                    query
                        .filter(\.$action.$id == action)
                        .filter(\.$node.$id == nil)
                        .filter(\.$context.$id == nil)
                        .filter(\.$thread == nil)
            }

        guard !includeDeleted else {
            return scopedQuery
        }

        return scopedQuery.filter(\.$deletedAt == nil)
    }

    /// Soft-deletes `mappings`, dropping everything but the name: a deleted
    /// row references no blob, and a revived one never points at bytes swept
    /// in between. Returns the avatar blobs that were released.
    @discardableResult
    static func softDeleteMappings(
        _ mappings: [KeepTalkingMapping],
        on database: any Database
    ) async throws -> Set<String> {
        guard !mappings.isEmpty else {
            return []
        }

        let deletedAt = Date()
        var released = Set<String>()
        for mapping in mappings {
            released.formUnion(mapping.blobIDs)
            mapping.appearance = nil
            mapping.suggestion = nil
            mapping.sharedInContexts = nil
            mapping.deletedAt = deletedAt
            try await mapping.save(on: database)
        }
        return released
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
