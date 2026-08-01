import FluentKit
import Foundation

extension KeepTalkingClient {
    public static func grantAliasPermission(
        aliasID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        grantScope: KeepTalkingActionScope? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        try await upsertAliasPermission(
            aliasID: aliasID,
            toNodeID: toNodeID,
            scope: scope,
            grantScope: grantScope,
            eligibility: eligibility,
            mergingScope: true,
            node: node,
            on: database
        )

        await callbackForBroadcasting?(
            "grant alias=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    public static func setAliasPermissionScope(
        aliasID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        try await database.transaction { database in
            try await upsertAliasPermission(
                aliasID: aliasID,
                toNodeID: toNodeID,
                scope: scope,
                grantScope: nil,
                eligibility: eligibility,
                mergingScope: false,
                node: node,
                on: database
            )
        }

        await callbackForBroadcasting?(
            "set alias scope=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    private static func upsertAliasPermission(
        aliasID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        grantScope: KeepTalkingActionScope?,
        eligibility: KeepTalkingRelationEligibility,
        mergingScope: Bool,
        node: KeepTalkingNode,
        on database: any Database
    ) async throws {
        let alias = try await requireActionTag(aliasID, on: database)
        let action = try await requireTaggedAction(alias, on: database)
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )
        let context = scope.context

        guard
            let hostNodeID = hostNode.id,
            let relation = try await preferredTrustedRelation(
                from: hostNodeID,
                to: toNodeID,
                allowing: context,
                eligibility: eligibility,
                on: database
            )
        else {
            throw KeepTalkingClientError.relationNotTrustedOrOwned(toNodeID)
        }

        let relationID = try relation.requireID()
        let relationIDs =
            if mergingScope {
                [relationID]
            } else {
                try await KeepTalkingNodeRelation.query(on: database)
                    .filter(\.$from.$id, .equal, hostNodeID)
                    .filter(\.$to.$id, .equal, toNodeID)
                    .all()
                    .compactMap(\.id)
            }
        let matchingGrants = try await aliasGrants(
            matching: alias,
            relationIDs: relationIDs,
            on: database
        )
        let targetGrant = matchingGrants.first {
            $0.$relation.id == relationID
        }
        let permission =
            mergingScope
            ? grantScope
            : consolidatedPermission(from: matchingGrants)

        if let grant = targetGrant {
            grant.approvingContext =
                mergingScope
                ? mergedApprovingContext(
                    current: grant.approvingContext,
                    requestedScope: scope
                )
                : scope.approvingContext
            if let permission {
                grant.permission = permission
            } else if !mergingScope {
                grant.permission = nil
            }
            try await grant.update(on: database)
        } else {
            let grant = try KeepTalkingNodeRelationAliasRelation(
                relation: relation,
                alias: alias,
                approvingContext: scope.approvingContext,
                permission: permission
            )
            try await grant.create(on: database)
        }

        if !mergingScope {
            for grant in matchingGrants where grant !== targetGrant {
                try await grant.delete(on: database)
            }
        }
    }

    /// Alias twin of `stageActionPermissionWithTrustInvitation`: grants a tag to
    /// a peer who isn't trusted in `contextID` yet, raising the pending
    /// invitation that makes the grant legible first.
    ///
    /// Without this, tag grants could only ever land on a peer some *other*
    /// grant had already pre-trusted — `.grantStaging` eligibility rejects a
    /// `.pending` relation — so tagging a fresh peer failed with
    /// `relationNotTrustedOrOwned`.
    public static func stageAliasPermissionWithTrustInvitation(
        contextID: UUID,
        aliasID: UUID,
        toNodeID: UUID,
        grantScope: KeepTalkingActionScope? = nil,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        let context = try await ensureContext(contextID, on: database)
        let alias = try await requireActionTag(aliasID, on: database)
        let action = try await requireTaggedAction(alias, on: database)
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )
        guard let hostNodeID = hostNode.id else {
            throw KeepTalkingClientError.missingNode
        }

        let alreadyTrusted =
            try await preferredTrustedRelation(
                from: hostNodeID,
                to: toNodeID,
                allowing: context,
                on: database
            ) != nil

        if !alreadyTrusted {
            try await upsertTrustInvitation(
                contextID: contextID,
                inviterNodeID: hostNodeID,
                recipientNodeID: toNodeID,
                direction: .outgoing,
                status: .pending,
                on: database
            )
        }

        try await grantAliasPermission(
            aliasID: aliasID,
            toNodeID: toNodeID,
            scope: .context(context),
            grantScope: grantScope,
            eligibility: .grantStaging,
            node: node,
            on: database,
            callbackForBroadcasting: callbackForBroadcasting
        )
    }

    public func stageAliasPermissionWithTrustInvitation(
        contextID: UUID,
        aliasID: UUID,
        toNodeID: UUID,
        grantScope: KeepTalkingActionScope? = nil
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.stageAliasPermissionWithTrustInvitation(
            contextID: contextID,
            aliasID: aliasID,
            toNodeID: toNodeID,
            grantScope: grantScope,
            node: selfNode,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        await invalidateActionToolCatalog(
            contextID: contextID,
            reason:
                "stage_alias_permission alias=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    public func grantAliasPermission(
        aliasID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        grantScope: KeepTalkingActionScope? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
    ) async throws {
        let node = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        try await Self.grantAliasPermission(
            aliasID: aliasID,
            toNodeID: toNodeID,
            scope: scope,
            grantScope: grantScope,
            eligibility: eligibility,
            node: node,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        await invalidateActionToolCatalog(
            contextID: scope.context?.id,
            reason:
                "grant_alias_permission alias=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    public func setAliasPermissionScope(
        aliasID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
    ) async throws {
        let node = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        try await Self.setAliasPermissionScope(
            aliasID: aliasID,
            toNodeID: toNodeID,
            scope: scope,
            eligibility: eligibility,
            node: node,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        await invalidateActionToolCatalog(
            contextID: scope.context?.id,
            reason:
                "set_alias_permission_scope alias=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    public static func revokeAliasPermission(
        aliasID: UUID,
        fromNodeID: UUID,
        context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        let alias = try await requireActionTag(aliasID, on: database)
        let action = try await requireTaggedAction(alias, on: database)
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )
        guard let hostNodeID = hostNode.id else {
            throw KeepTalkingClientError.missingNode
        }

        let relations = try await trustedRelations(
            from: hostNodeID,
            to: fromNodeID,
            allowing: context,
            eligibility: eligibility,
            on: database
        )
        let grants = try await aliasGrants(
            matching: alias,
            relationIDs: relations.compactMap(\.id),
            on: database
        )

        for grant in grants {
            try await revoke(grant, in: context, on: database)
        }

        try await reconcilePendingTrustInvitations(
            from: hostNodeID,
            to: fromNodeID,
            in: context,
            on: database
        )

        await callbackForBroadcasting?(
            "revoke alias=\(aliasID.uuidString.lowercased()) from=\(fromNodeID.uuidString.lowercased())"
        )
    }

    public func revokeAliasPermission(
        aliasID: UUID,
        fromNodeID: UUID,
        context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
    ) async throws {
        let node = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        try await Self.revokeAliasPermission(
            aliasID: aliasID,
            fromNodeID: fromNodeID,
            context: context,
            eligibility: eligibility,
            node: node,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        await invalidateActionToolCatalog(
            contextID: context?.id,
            reason:
                "revoke_alias_permission alias=\(aliasID.uuidString.lowercased()) from=\(fromNodeID.uuidString.lowercased())"
        )
    }

    public static func grantedNodeIDs(
        forAlias aliasID: UUID,
        context: KeepTalkingContext? = nil,
        node: KeepTalkingNode,
        on database: any Database
    ) async throws -> Set<UUID> {
        let scopes = try await grantedAliasScopes(
            forAlias: aliasID,
            node: node,
            on: database
        )
        return Set(
            scopes.compactMap { nodeID, scope in
                scope.applicable(in: context) ? nodeID : nil
            }
        )
    }

    public static func grantedAliasScopes(
        forAlias aliasID: UUID,
        node: KeepTalkingNode,
        on database: any Database
    ) async throws -> [UUID: KeepTalkingNodeRelationApprovingContext] {
        let alias = try await requireActionTag(aliasID, on: database)
        let action = try await requireTaggedAction(alias, on: database)
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )
        guard let hostNodeID = hostNode.id else { return [:] }

        let relations = try await KeepTalkingNodeRelation.query(on: database)
            .filter(\.$from.$id == hostNodeID)
            .all()
        let relationByID = Dictionary(
            uniqueKeysWithValues: relations.compactMap { relation in
                relation.id.map { ($0, relation) }
            }
        )
        let grants = try await aliasGrants(
            matching: alias,
            relationIDs: Array(relationByID.keys),
            on: database
        )

        var scopes: [UUID: KeepTalkingNodeRelationApprovingContext] = [:]
        for grant in grants {
            guard
                let relation = relationByID[grant.$relation.id],
                let effectiveScope = grant.approvingContext?.restricted(
                    to: relation.relationship
                )
            else {
                continue
            }
            scopes[relation.$to.id] = scopes[relation.$to.id]
                .merging(effectiveScope)
        }
        return scopes
    }

    static func aliasGrantPermissions(
        forActionID actionID: UUID,
        relationIDs: [UUID],
        context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> [KeepTalkingActionScope] {
        guard !relationIDs.isEmpty else { return [] }

        let actionTags = try await KeepTalkingMapping.query(on: database)
            .filter(\.$action.$id, .equal, actionID)
            .filter(\.$kind, .equal, .tag)
            .filter(\.$deletedAt == nil)
            .all()
        guard !actionTags.isEmpty else { return [] }

        return try await KeepTalkingNodeRelationAliasRelation.query(on: database)
            .filter(\.$relation.$id ~~ relationIDs)
            .with(\.$alias)
            .all()
            .filter { grant in
                grant.applicable(in: context)
                    && actionTags.contains { tag in
                        grant.alias.kind == tag.kind
                            && grant.alias.namespace == tag.namespace
                            && grant.alias.normalizedValue == tag.normalizedValue
                    }
            }
            .map { $0.permission ?? .all }
    }

    private static func requireActionTag(
        _ aliasID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingMapping {
        guard
            let alias = try await KeepTalkingMapping.find(aliasID, on: database),
            alias.kind == .tag,
            alias.target != nil
        else {
            throw KeepTalkingClientError.missingMapping(aliasID)
        }
        return alias
    }

    private static func requireTaggedAction(
        _ alias: KeepTalkingMapping,
        on database: any Database
    ) async throws -> KeepTalkingAction {
        guard
            case .action(let actionID)? = alias.target,
            let action = try await KeepTalkingAction.find(actionID, on: database)
        else {
            throw KeepTalkingClientError.missingAction
        }
        return action
    }

    private static func aliasGrants(
        matching alias: KeepTalkingMapping,
        relationIDs: [UUID],
        on database: any Database
    ) async throws -> [KeepTalkingNodeRelationAliasRelation] {
        guard !relationIDs.isEmpty else { return [] }

        return try await KeepTalkingNodeRelationAliasRelation.query(on: database)
            .filter(\.$relation.$id ~~ relationIDs)
            .with(\.$alias)
            .all()
            .filter {
                $0.alias.kind == alias.kind
                    && $0.alias.namespace == alias.namespace
                    && $0.alias.normalizedValue == alias.normalizedValue
            }
    }

    private static func revoke(
        _ grant: KeepTalkingNodeRelationAliasRelation,
        in context: KeepTalkingContext?,
        on database: any Database
    ) async throws {
        guard let context else {
            try await grant.delete(on: database)
            return
        }
        guard case .contexts(let contexts) = grant.approvingContext else {
            try await grant.delete(on: database)
            return
        }

        let remaining = contexts.filter { $0.id != context.id }
        if remaining.isEmpty {
            try await grant.delete(on: database)
        } else {
            grant.approvingContext = .contexts(remaining)
            try await grant.update(on: database)
        }
    }

    private static func consolidatedPermission(
        from grants: [KeepTalkingNodeRelationAliasRelation]
    ) -> KeepTalkingActionScope? {
        guard !grants.isEmpty else { return nil }
        let permission = KeepTalkingActionScope.union(
            grants.map { $0.permission ?? .all }
        )
        return permission.isUnrestricted ? nil : permission
    }
}

extension KeepTalkingActionPermissionScope {
    fileprivate var approvingContext: KeepTalkingNodeRelationApprovingContext {
        switch self {
            case .all:
                .all
            case .context(let context):
                .contexts([context])
        }
    }
}

extension Optional where Wrapped == KeepTalkingNodeRelationApprovingContext {
    fileprivate func merging(
        _ other: KeepTalkingNodeRelationApprovingContext
    ) -> KeepTalkingNodeRelationApprovingContext {
        guard let current = self else { return other }
        switch (current, other) {
            case (.all, _), (_, .all):
                return .all
            case (.contexts(let lhs), .contexts(let rhs)):
                return .contexts(Array(Set(lhs + rhs)))
        }
    }
}

extension KeepTalkingNodeRelationApprovingContext {
    fileprivate func restricted(
        to relationship: KeepTalkingRelationship
    ) -> KeepTalkingNodeRelationApprovingContext? {
        switch self {
            case .all:
                switch relationship {
                    case .owner, .trustedInAllContext:
                        return .all
                    case .trusted(let contexts):
                        return contexts.isEmpty ? nil : .contexts(contexts)
                    case .pending, .preTrusted:
                        return nil
                }
            case .contexts(let contexts):
                let allowed = contexts.filter {
                    relationship.allows(context: $0)
                }
                return allowed.isEmpty ? nil : .contexts(allowed)
        }
    }
}

extension KeepTalkingActionPermissionScope {
    fileprivate var context: KeepTalkingContext? {
        switch self {
            case .all: nil
            case .context(let context): context
        }
    }
}
