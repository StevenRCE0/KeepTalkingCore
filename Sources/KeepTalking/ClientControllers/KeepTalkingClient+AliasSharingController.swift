import FluentKit
import Foundation

/// A suggestion the user hasn't accepted or ignored yet.
public struct KeepTalkingPendingAliasSuggestion: Hashable, Sendable {
    public let target: KeepTalkingMappingTarget
    public let alias: KeepTalkingSharedAlias
}

extension KeepTalkingClient {
    // MARK: - Sharing the local node's alias

    /// The contexts the local node's alias is shared into.
    public static func aliasSharedContexts(
        localNodeID: UUID,
        on database: any Database
    ) async throws -> Set<UUID> {
        let row = try await queryMappings(for: .node(localNodeID), on: database)
            .filter(\.$kind, .equal, .alias)
            .first()
        return Set(row?.sharedInContexts ?? [])
    }

    /// Shares (or stops sharing) the local node's alias into `contextID`.
    /// Recorded on the node's own global alias row, created nameless when
    /// there is none.
    public static func setAliasShared(
        _ shared: Bool,
        in contextID: UUID,
        localNodeID: UUID,
        on database: any Database
    ) async throws {
        let target = KeepTalkingMappingTarget.node(localNodeID)
        let existing = try await queryMappings(for: target, includeDeleted: true, on: database)
            .filter(\.$kind, .equal, .alias)
            .all()
        let live = existing.first { $0.deletedAt == nil }
        var contexts = Set(live?.sharedInContexts ?? [])
        guard contexts.contains(contextID) != shared else { return }
        if shared {
            contexts.insert(contextID)
        } else {
            contexts.remove(contextID)
        }

        let row = revivedOrNewAliasRow(live: live, existing: existing, target: target, scopeContextID: nil)
        row.sharedInContexts = contexts.isEmpty ? nil : contexts.sorted { $0.uuidString < $1.uuidString }
        if row.isVacant {
            try await softDeleteMappings([row], on: database)
        } else {
            try await row.save(on: database)
        }
    }

    // MARK: - Suggestions from other nodes

    /// Stores what `nodeID` shared about itself, in the shared alias's scope.
    /// An older revision, or one saying the same thing, changes nothing; an
    /// empty one clears what was stored. A suggestion matching the user's own
    /// global alias arrives already reviewed. Returns whether anything changed.
    @discardableResult
    static func applySharedAlias(
        _ alias: KeepTalkingSharedAlias,
        from nodeID: UUID,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws -> Bool {
        let target = KeepTalkingMappingTarget.node(nodeID)
        let existing = try await queryMappings(
            for: target,
            scopeContextID: alias.contextID,
            includeDeleted: true,
            on: database
        )
        .filter(\.$kind, .equal, .alias)
        .all()
        let live = existing.first { $0.deletedAt == nil }

        if let current = live?.suggestion?.alias {
            guard alias.revision > current.revision, !current.hasSameContent(as: alias) else {
                return false
            }
        }

        var released = Set<String>()
        if alias.isEmpty {
            guard let live, let current = live.suggestion else { return false }
            released = current.alias.appearance?.blobIDs ?? []
            live.suggestion = nil
            if live.isVacant {
                released.formUnion(try await softDeleteMappings([live], on: database))
            } else {
                try await live.save(on: database)
            }
        } else {
            let row = revivedOrNewAliasRow(
                live: live,
                existing: existing,
                target: target,
                scopeContextID: alias.contextID
            )
            released = (row.suggestion?.alias.appearance?.blobIDs ?? [])
                .subtracting(alias.appearance?.blobIDs ?? [])
            let own = try await queryMappings(for: target, on: database)
                .filter(\.$kind, .equal, .alias)
                .first()
            let matchesOwn = own.map { Self.isAdopted(alias, by: $0) } ?? false
            row.suggestion = KeepTalkingAliasSuggestion(
                alias: alias,
                reviewedRevision: matchesOwn ? alias.revision : nil
            )
            try await row.save(on: database)
        }
        try await pruneReleasedBlobs(released, on: database, blobStore: blobStore)
        return true
    }

    /// Suggestions in exactly this scope (nil = global) the user hasn't
    /// accepted or ignored yet.
    public static func pendingAliasSuggestions(
        scopeContextID: UUID?,
        on database: any Database
    ) async throws -> [KeepTalkingPendingAliasSuggestion] {
        try await KeepTalkingMapping.query(on: database)
            .filter(\.$kind, .equal, .alias)
            .filter(\.$scopeContext.$id == scopeContextID)
            .filter(\.$deletedAt == nil)
            .filter(\.$suggestion != nil)
            .all()
            .compactMap { row in
                guard let target = row.target, let suggestion = row.suggestion, suggestion.isPending
                else { return nil }
                return KeepTalkingPendingAliasSuggestion(target: target, alias: suggestion.alias)
            }
    }

    /// Adopts the suggestion: its name and appearance become the user's own
    /// global alias for `target` — the user's from now on, so a later change
    /// arrives as a new suggestion.
    public static func acceptAliasSuggestion(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID?,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws {
        guard
            let alias = try await suggestionRow(for: target, scopeContextID: scopeContextID, on: database)?
                .suggestion?.alias
        else { return }
        if let name = alias.name {
            try await setAlias(name, for: target, on: database, blobStore: blobStore)
        }
        if let appearance = alias.appearance {
            try await setAppearance(appearance, for: target, on: database, blobStore: blobStore)
        }
        // Re-read: with a nil scope the row just written is the same row.
        try await markSuggestionReviewed(for: target, scopeContextID: scopeContextID, on: database)
    }

    /// Leaves the suggestion as it is — still shown as the target's own name —
    /// but stops it being pending.
    public static func ignoreAliasSuggestion(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID?,
        on database: any Database
    ) async throws {
        try await markSuggestionReviewed(for: target, scopeContextID: scopeContextID, on: database)
    }

    public static func acceptAllAliasSuggestions(
        scopeContextID: UUID?,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws {
        for pending in try await pendingAliasSuggestions(scopeContextID: scopeContextID, on: database) {
            try await acceptAliasSuggestion(
                for: pending.target,
                scopeContextID: scopeContextID,
                on: database,
                blobStore: blobStore
            )
        }
    }

    public static func ignoreAllAliasSuggestions(
        scopeContextID: UUID?,
        on database: any Database
    ) async throws {
        for pending in try await pendingAliasSuggestions(scopeContextID: scopeContextID, on: database) {
            try await ignoreAliasSuggestion(for: pending.target, scopeContextID: scopeContextID, on: database)
        }
    }

    // MARK: - Helpers

    private static func markSuggestionReviewed(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID?,
        on database: any Database
    ) async throws {
        guard let row = try await suggestionRow(for: target, scopeContextID: scopeContextID, on: database),
            var suggestion = row.suggestion, suggestion.isPending
        else { return }
        suggestion.reviewedRevision = suggestion.alias.revision
        row.suggestion = suggestion
        try await row.save(on: database)
    }

    private static func suggestionRow(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID?,
        on database: any Database
    ) async throws -> KeepTalkingMapping? {
        try await queryMappings(for: target, scopeContextID: scopeContextID, on: database)
            .filter(\.$kind, .equal, .alias)
            .filter(\.$suggestion != nil)
            .first()
    }

    /// Whether the user's own row already says what `alias` says.
    private static func isAdopted(_ alias: KeepTalkingSharedAlias, by own: KeepTalkingMapping) -> Bool {
        let nameMatches = alias.name.map { KeepTalkingMapping.normalizeLookupValue($0) == own.normalizedValue } ?? true
        let appearanceMatches = alias.appearance.map { $0 == own.appearance } ?? true
        return nameMatches && appearanceMatches
    }

    /// The live alias row, else a revived deleted one (nameless — its name was
    /// removed with it), else a new nameless row. Not saved.
    private static func revivedOrNewAliasRow(
        live: KeepTalkingMapping?,
        existing: [KeepTalkingMapping],
        target: KeepTalkingMappingTarget,
        scopeContextID: UUID?
    ) -> KeepTalkingMapping {
        if let live { return live }
        if let deleted = existing.first {
            deleted.value = ""
            deleted.normalizedValue = ""
            deleted.deletedAt = nil
            return deleted
        }
        return KeepTalkingMapping(target: target, scopeContext: scopeContextID, kind: .alias, value: "")
    }
}
