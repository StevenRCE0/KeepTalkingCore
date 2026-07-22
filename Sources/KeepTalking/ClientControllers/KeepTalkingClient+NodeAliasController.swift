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

        let matchingGrants = try await aliasGrants(
            matching: alias,
            relationIDs: [try relation.requireID()],
            on: database
        )
        if let grant = matchingGrants.first {
            grant.approvingContext = mergedApprovingContext(
                current: grant.approvingContext,
                requestedScope: scope
            )
            if let grantScope {
                grant.permission = grantScope
            }
            try await grant.update(on: database)
        } else {
            let grant = try KeepTalkingNodeRelationAliasRelation(
                relation: relation,
                alias: alias,
                approvingContext: scope.approvingContext,
                permission: grantScope
            )
            try await grant.create(on: database)
        }

        await callbackForBroadcasting?(
            "grant alias=\(aliasID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
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
    }

    public static func grantedNodeIDs(
        forAlias aliasID: UUID,
        context: KeepTalkingContext? = nil,
        node: KeepTalkingNode,
        on database: any Database
    ) async throws -> Set<UUID> {
        let alias = try await requireActionTag(aliasID, on: database)
        let action = try await requireTaggedAction(alias, on: database)
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )
        guard let hostNodeID = hostNode.id else { return [] }

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

        return Set(
            grants.compactMap { grant in
                guard
                    let relation = relationByID[grant.$relation.id],
                    relation.relationship.allowsGrantStaging(context: context),
                    grant.applicable(in: context)
                else {
                    return nil
                }
                return relation.$to.id
            })
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
}

extension KeepTalkingActionPermissionScope {
    fileprivate var context: KeepTalkingContext? {
        switch self {
            case .all: nil
            case .context(let context): context
        }
    }

    fileprivate var approvingContext: KeepTalkingNodeRelationApprovingContext {
        switch self {
            case .all: .all
            case .context(let context): .contexts([context])
        }
    }
}
