import FluentKit
import Foundation

/// A suggestion the user hasn't accepted or ignored yet.
public struct KeepTalkingPendingAliasSuggestion: Hashable, Sendable {
    public let target: KeepTalkingMappingTarget
    public let alias: KeepTalkingSharedAlias
}

extension KeepTalkingClient {
    // MARK: - Sharing the local node's alias

    /// The local node's sharing decisions in `contextID`, one per alias row
    /// it has: its global alias and its alias scoped to the context.
    public static func aliasSharing(
        in contextID: UUID,
        localNodeID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingContextAliasSharing {
        let target = KeepTalkingMappingTarget.node(localNodeID)
        let global = try await liveAliasRow(for: target, scopeContextID: nil, on: database)
        let scoped = try await liveAliasRow(for: target, scopeContextID: contextID, on: database)
        let rowIDs = [global?.id, scoped?.id].compactMap { $0 }
        let decisions = try await KeepTalkingContextWiseAliasRelation.query(on: database)
            .filter(\.$context.$id == contextID)
            .filter(\.$alias.$id ~~ rowIDs)
            .all()
        func decision(for row: KeepTalkingMapping?) -> Bool? {
            guard let id = row?.id else { return nil }
            return decisions.first { $0.$alias.id == id }?.isShared
        }
        return KeepTalkingContextAliasSharing(
            hasGlobal: global.map { !$0.isVacant } ?? false,
            hasScoped: scoped.map { !$0.isVacant } ?? false,
            global: decision(for: global),
            scoped: decision(for: scoped)
        )
    }

    /// Records whether the local node's global or scoped alias is shown in
    /// `contextID`. The alias must exist — create it first.
    public static func setAliasShared(
        _ shared: Bool,
        _ layer: KeepTalkingAliasLayer,
        in contextID: UUID,
        localNodeID: UUID,
        on database: any Database
    ) async throws {
        guard
            let row = try await liveAliasRow(
                for: .node(localNodeID),
                scopeContextID: layer == .global ? nil : contextID,
                on: database
            ),
            let aliasID = row.id
        else {
            throw KeepTalkingMappingError.missingAlias
        }
        if let existing = try await KeepTalkingContextWiseAliasRelation.query(on: database)
            .filter(\.$context.$id == contextID)
            .filter(\.$alias.$id == aliasID)
            .first()
        {
            guard existing.isShared != shared else { return }
            existing.isShared = shared
            try await existing.save(on: database)
        } else {
            try await KeepTalkingContextWiseAliasRelation(
                contextID: contextID,
                aliasID: aliasID,
                isShared: shared
            )
            .create(on: database)
        }
    }

    // MARK: - What goes out

    /// The local node's scoped alias as it goes out in `contextID`, stamped
    /// `revision`. Scoped aliases are per context, so not sharing one here is
    /// said too: with an empty alias, which clears what members kept.
    static func outgoingScopedAlias(
        in contextID: UUID,
        localNodeID: UUID,
        revision: UInt64,
        on database: any Database
    ) async throws -> KeepTalkingSharedAlias {
        let sharing = try await aliasSharing(in: contextID, localNodeID: localNodeID, on: database)
        guard sharing.sharesScoped,
            let row = try await liveAliasRow(for: .node(localNodeID), scopeContextID: contextID, on: database)
        else {
            return KeepTalkingSharedAlias(contextID: contextID, name: nil, appearance: nil, revision: revision)
        }
        return KeepTalkingSharedAlias(
            contextID: contextID, name: row.value, appearance: row.appearance, revision: revision)
    }

    /// The local node's global alias as it goes out from `contextID`, stamped
    /// `revision` — for trusted recipients only; the caller checks.
    ///
    /// The global alias is one for everywhere, so a context that doesn't
    /// share it has nothing to say (nil): another context may share it. Only
    /// once it no longer exists does an empty one go out, clearing it.
    static func outgoingGlobalAlias(
        in contextID: UUID,
        localNodeID: UUID,
        revision: UInt64,
        on database: any Database
    ) async throws -> KeepTalkingSharedAlias? {
        let sharing = try await aliasSharing(in: contextID, localNodeID: localNodeID, on: database)
        guard sharing.hasGlobal else {
            return KeepTalkingSharedAlias(contextID: nil, name: nil, appearance: nil, revision: revision)
        }
        guard sharing.sharesGlobal,
            let row = try await liveAliasRow(for: .node(localNodeID), scopeContextID: nil, on: database)
        else { return nil }
        return KeepTalkingSharedAlias(contextID: nil, name: row.value, appearance: row.appearance, revision: revision)
    }

    /// This client's scoped alias for its context, as it goes out now.
    func ownScopedAlias() async throws -> KeepTalkingSharedAlias {
        try await Self.outgoingScopedAlias(
            in: config.contextID,
            localNodeID: config.node,
            revision: KeepTalkingNodeStatus.nextRevision(),
            on: localStore.database
        )
    }

    func ownAliasPush() async throws -> KeepTalkingContextSyncAliasPush {
        KeepTalkingContextSyncAliasPush(
            context: config.contextID,
            origin: config.node,
            alias: try await ownScopedAlias()
        )
    }

    /// Shares the local node's aliases in this client's context as they are
    /// now: the scoped one pushed to the room, the global one in a fresh node
    /// status to the members trusted here. Call after the user changes either
    /// alias or what this context shares; the heartbeat sync and the node
    /// status sent on every connect catch up whoever misses it.
    public func publishOwnAliases() async {
        do {
            try sendEnvelope(KeepTalkingContextSyncEnvelope.aliasPush(try await ownAliasPush()))
            try await broadcastCurrentNodeStatus(
                in: try await requireContext(config.contextID)
            )
        } catch {
            debug("alias publish failed error=\(error.localizedDescription)")
        }
    }

    /// Re-sends this node's status in its context, so peers pick up an edit
    /// to what it advertises — its actions' appearance, say — without waiting
    /// for the next heartbeat.
    public func republishNodeStatus() async {
        do {
            try await broadcastCurrentNodeStatus(
                in: try await requireContext(config.contextID)
            )
        } catch {
            debug("node status republish failed error=\(error.localizedDescription)")
        }
    }

    // MARK: - What comes in

    /// Keeps what `nodeID` shared about itself in this client's context —
    /// for this context whatever the alias claims — and fetches its avatar.
    func receiveScopedAlias(_ alias: KeepTalkingSharedAlias, from nodeID: UUID) async throws {
        var alias = alias
        alias.contextID = config.contextID
        try await receiveSharedAlias(alias, from: nodeID)
    }

    /// Keeps the global alias `nodeID` sent in its node status, if the user
    /// trusts it: the global alias only ever travels on trust, and is dropped
    /// when that trust goes (`dropGlobalAliasSuggestion`).
    func receiveGlobalAlias(_ alias: KeepTalkingSharedAlias, from nodeID: UUID) async throws {
        let trusted = try await KeepTalkingNodeRelation.query(on: localStore.database)
            .filter(\.$from.$id == config.node)
            .filter(\.$to.$id == nodeID)
            .all()
            .contains { $0.relationship.isTrustedOrOwner }
        guard trusted else { return }
        var alias = alias
        alias.contextID = nil
        try await receiveSharedAlias(alias, from: nodeID)
    }

    private func receiveSharedAlias(_ alias: KeepTalkingSharedAlias, from nodeID: UUID) async throws {
        guard nodeID != config.node else { return }
        try await KeepTalkingNode.findOrCreate(nodeID, on: localStore.database)
        if let contextID = alias.contextID {
            _ = try await requireContext(contextID)
        }
        guard
            try await Self.applySharedAlias(
                alias,
                from: nodeID,
                on: localStore.database,
                blobStore: blobStore
            )
        else { return }
        signals.mappingChanges.send(())
        if let blobIDs = alias.appearance?.blobIDs, !blobIDs.isEmpty {
            await requestBlobsIfMissing(blobIDs, in: config.contextID)
        }
    }

    /// The avatars of suggestions kept here — shared in this context, or
    /// globally — whose blobs haven't arrived.
    func missingSuggestionAvatarBlobIDs() async throws -> Set<String> {
        let rows = try await KeepTalkingMapping.query(on: localStore.database)
            .filter(\.$kind, .equal, .alias)
            .filter(\.$deletedAt == nil)
            .filter(\.$suggestion != nil)
            .group(.or) { group in
                group.filter(\.$scopeContext.$id == config.contextID)
                group.filter(\.$scopeContext.$id == nil)
            }
            .all()
        var missing = Set<String>()
        for blobID in Set(rows.flatMap { $0.suggestion?.alias.appearance?.blobIDs ?? [] }) {
            if try await !isBlobReady(blobID: blobID) { missing.insert(blobID) }
        }
        return missing
    }

    private static func liveAliasRow(
        for target: KeepTalkingMappingTarget,
        scopeContextID: UUID?,
        on database: any Database
    ) async throws -> KeepTalkingMapping? {
        try await queryMappings(for: target, scopeContextID: scopeContextID, on: database)
            .filter(\.$kind, .equal, .alias)
            .first()
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
            // Already the user's own, in this scope or globally: nothing to
            // review.
            let global = try await queryMappings(for: target, on: database)
                .filter(\.$kind, .equal, .alias)
                .first()
            let matchesOwn = [row, global].compactMap { $0 }.contains { Self.isAdopted(alias, by: $0) }
            row.suggestion = KeepTalkingAliasSuggestion(
                alias: alias,
                reviewedRevision: matchesOwn ? alias.revision : nil
            )
            try await row.save(on: database)
        }
        try await pruneReleasedBlobs(released, on: database, blobStore: blobStore)
        // The user's own devices name themselves: what they share is taken
        // as it comes, never left pending.
        if !alias.isEmpty, try await isOwnDevice(nodeID, on: database) {
            try await acceptAliasSuggestion(
                for: target,
                scopeContextID: alias.contextID,
                on: database,
                blobStore: blobStore
            )
        }
        return true
    }

    /// Drops what `nodeID` shared globally — for when the user stops trusting
    /// it, since the global alias only ever came because of that trust. What
    /// it shared in contexts stays: that came as a context member.
    public static func dropGlobalAliasSuggestion(
        from nodeID: UUID,
        on database: any Database,
        blobStore: KeepTalkingBlobStore? = nil
    ) async throws {
        guard
            let row = try await suggestionRow(for: .node(nodeID), scopeContextID: nil, on: database),
            let suggestion = row.suggestion
        else { return }
        var released = suggestion.alias.appearance?.blobIDs ?? []
        row.suggestion = nil
        if row.isVacant {
            released.formUnion(try await softDeleteMappings([row], on: database))
        } else {
            try await row.save(on: database)
        }
        try await pruneReleasedBlobs(released, on: database, blobStore: blobStore)
    }

    /// Whether `nodeID` is one of the user's own devices — an owner relation
    /// either way.
    private static func isOwnDevice(_ nodeID: UUID, on database: any Database) async throws -> Bool {
        try await KeepTalkingNodeRelation.query(on: database)
            .group(.or) { group in
                group.filter(\.$to.$id == nodeID)
                group.filter(\.$from.$id == nodeID)
            }
            .all()
            .contains { $0.relationship == .owner }
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

    /// Adopts the suggestion into the user's own alias in the same scope: a
    /// global suggestion becomes the user's global alias for `target`, one
    /// shared in a context the user's alias for it there. The user's from now
    /// on, so a later change arrives as a new suggestion.
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
            try await setAlias(
                name,
                for: target,
                scopeContextID: scopeContextID,
                on: database,
                blobStore: blobStore
            )
        }
        if let appearance = alias.appearance {
            try await setAppearance(
                appearance,
                for: target,
                scopeContextID: scopeContextID,
                on: database,
                blobStore: blobStore
            )
        }
        // Re-read: the row just written is the suggestion's own row.
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
