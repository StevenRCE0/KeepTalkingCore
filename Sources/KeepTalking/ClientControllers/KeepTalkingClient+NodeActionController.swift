//
//  KeepTalkingClient+NodeActionController.swift
//  KeepTalking
//
//  Created by 砚渤 on 25/02/2026.
//

import FluentKit
import Foundation

extension KeepTalkingClient {
    static func relationPriority(_ relationship: KeepTalkingRelationship) -> Int {
        switch relationship {
            case .owner:
                return 3
            case .trustedInAllContext:
                return 2
            case .trusted:
                return 1
            case .pending:
                return 0
        }
    }

    static func preferredTrustedRelation(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        allowing context: KeepTalkingContext? = nil,
        allowPending: Bool = false,
        on database: any Database
    ) async throws -> KeepTalkingNodeRelation? {
        try await KeepTalkingNodeRelation
            .query(on: database)
            .filter(\.$from.$id, .equal, fromNodeID)
            .filter(\.$to.$id, .equal, toNodeID)
            .all()
            .sorted(by: {
                relationPriority($0.relationship)
                    > relationPriority($1.relationship)
            })
            .first(where: { relation in
                if relation.relationship.isTrustedOrOwner {
                    return relation.relationship.allows(context: context)
                } else if allowPending {
                    return true
                }

                return false
            })
    }

    private static func normalizedBlockingAuthorisation(_ value: Bool) -> Bool {
        #if os(iOS)
        true
        #else
        value
        #endif
    }

    private static func loadedDescriptor(
        from action: KeepTalkingAction
    ) -> KeepTalkingActionDescriptor? {
        action.$descriptor.value ?? nil
    }

    func deduplicatedAndSortedActions(
        _ actions: [KeepTalkingAction]
    ) -> [KeepTalkingAction] {
        var byID: [UUID: KeepTalkingAction] = [:]
        var withoutID: [KeepTalkingAction] = []

        for action in actions {
            guard let actionID = action.id else {
                withoutID.append(action)
                continue
            }
            byID[actionID] = action
        }

        return byID.values.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        } + withoutID
    }

    func deduplicatedAndSortedActions(
        _ actions: [KeepTalkingAdvertisedAction]
    ) -> [KeepTalkingAdvertisedAction] {
        var byID: [UUID: KeepTalkingAdvertisedAction] = [:]

        for action in actions {
            byID[action.actionID] = action
        }

        return byID.values.sorted {
            $0.actionID.uuidString < $1.actionID.uuidString
        }
    }

    private static func resolveGrantHostNode(
        for action: KeepTalkingAction,
        authorizingNode: KeepTalkingNode,
        on database: any Database
    ) async throws -> KeepTalkingNode {
        let actionID = try action.requireID()
        let authorizingNodeID = try authorizingNode.requireID()

        guard let hostNodeID = action.$node.id else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }
        if hostNodeID == authorizingNodeID {
            return authorizingNode
        }

        guard
            let ownershipRelation =
                try await KeepTalkingNodeRelation
                .query(on: database)
                .filter(\.$from.$id == authorizingNodeID)
                .filter(\.$to.$id == hostNodeID)
                .first(),
            ownershipRelation.relationship == .owner,
            let hostNode = try await KeepTalkingNode.find(
                hostNodeID,
                on: database
            )
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        return hostNode
    }

    private static func mergedApprovingContext(
        current: KeepTalkingNodeRelationActionRelation.ApprovingContext?,
        requestedScope: KeepTalkingActionPermissionScope
    ) -> KeepTalkingNodeRelationActionRelation.ApprovingContext {
        switch requestedScope {
            case .all:
                return .all
            case .context(let approvingContext):
                switch current {
                    case .all:
                        return .contexts([approvingContext])
                    case .contexts(let originalContexts):
                        guard !originalContexts.contains(approvingContext) else {
                            return .contexts(originalContexts)
                        }
                        return .contexts(originalContexts + [approvingContext])
                    case nil:
                        return .contexts([approvingContext])
                }
        }
    }

    public func registerAction(
        payload: KeepTalkingAction.Payload,
        descriptor: KeepTalkingActionDescriptor? = nil,
        remoteAuthorisable: Bool = true,
        blockingAuthorisation: Bool = false
    ) async throws -> KeepTalkingAction {
        var finalPayload = payload
        if case .primitive(let bundle) = payload {
            finalPayload = .primitive(bundle.assigningNewID())
        }
        let action = KeepTalkingAction(
            payload: finalPayload,
            remoteAuthorisable: remoteAuthorisable,
            blockingAuthorisation: blockingAuthorisation
        )
        if let descriptor { action.descriptor = descriptor }
        return try await saveConstructedAction(action)
    }

    static public func registerAction(
        payload: KeepTalkingAction.Payload,
        descriptor: KeepTalkingActionDescriptor? = nil,
        remoteAuthorisable: Bool = true,
        blockingAuthorisation: Bool = false,
        node: KeepTalkingNode,
        on database: any Database
    ) async throws -> KeepTalkingAction {
        var finalPayload = payload
        if case .primitive(let bundle) = payload {
            finalPayload = .primitive(bundle.assigningNewID())
        }
        let action = KeepTalkingAction(
            payload: finalPayload,
            remoteAuthorisable: remoteAuthorisable,
            blockingAuthorisation: normalizedBlockingAuthorisation(blockingAuthorisation)
        )
        action.$node.id = try node.requireID()
        if let descriptor {
            action.descriptor = descriptor
        } else {
            switch finalPayload {
                case .mcpBundle(let b): action.descriptor = Self.defaultDescriptor(for: b)
                case .skill(let b): action.descriptor = Self.defaultDescriptor(for: b)
                case .primitive(let b): action.descriptor = Self.defaultDescriptor(for: b)
                case .semanticRetrieval(let b): action.descriptor = Self.defaultDescriptor(for: b)
                case .filesystem(let b): action.descriptor = Self.defaultDescriptor(for: b)
            }
        }
        try await action.save(on: database)
        return action
    }

    public func preflightHTTPMCPAuthentication(actionID: UUID) async throws {
        guard
            let action = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .filter(\.$node.$id, .equal, config.node)
            .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        guard case .mcpBundle(let bundle) = action.payload else {
            return
        }
        guard case .http = bundle.service else {
            return
        }

        try await preflightHTTPMCPAuthentication(action: action)
    }

    public func preflightHTTPMCPAuthentication(
        action: KeepTalkingAction
    ) async throws {
        guard case .mcpBundle(let bundle) = action.payload else {
            return
        }
        guard case .http = bundle.service else {
            return
        }

        try await mcpManager.preflightHTTPAuthentication(action: action)
    }

    public func saveConstructedAction(
        _ action: KeepTalkingAction
    ) async throws -> KeepTalkingAction {
        let payload = action.payload

        if action.id == nil {
            action.id = UUID()
        }
        if action.$node.id == nil {
            let node = try await getCurrentNodeInstance()
            action.$node.id = try node.requireID()
        }
        action.blockingAuthorisation = Self.normalizedBlockingAuthorisation(
            action.blockingAuthorisation ?? false
        )
        if Self.loadedDescriptor(from: action) == nil {
            switch payload {
                case .mcpBundle(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .skill(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .primitive(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .semanticRetrieval(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .filesystem(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
            }
        }

        try await action.save(on: localStore.database)
        switch payload {
            case .mcpBundle:
                try await mcpManager.registerMCPAction(action)
            case .skill:
                try await skillManager.registerSkillAction(action)
            case .primitive:
                try await primitiveActionManager.registerPrimitiveAction(action)
            case .semanticRetrieval:
                try await semanticRetrievalActionManager.registerIfNeeded(action)
            case .filesystem:
                try await filesystemActionManager.registerFilesystemAction(action)
        }
        await invalidateActionToolCatalog(
            reason: "register_action action=\(action.id?.uuidString.lowercased() ?? "unknown")"
        )
        return action
    }

    public func modifyAction(
        actionID: UUID,
        payload: KeepTalkingAction.Payload? = nil,
        descriptor: KeepTalkingActionDescriptor? = nil,
        remoteAuthorisable: Bool? = nil,
        blockingAuthorisation: Bool? = nil,
        disabled: Bool? = nil
    ) async throws -> KeepTalkingAction {
        guard
            let action = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .filter(\.$node.$id, .equal, config.node)
            .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        if let payload {
            action.payload = payload
        }
        if let descriptor {
            action.descriptor = descriptor
        } else if Self.loadedDescriptor(from: action) == nil {
            switch action.payload {
                case .mcpBundle(let bundle):
                    action.descriptor = defaultDescriptor(for: bundle)
                case .skill(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .primitive(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .filesystem(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .semanticRetrieval:
                    break
            }
        }

        if let remoteAuthorisable {
            action.remoteAuthorisable = remoteAuthorisable
        }
        if let blockingAuthorisation {
            action.blockingAuthorisation =
                Self.normalizedBlockingAuthorisation(blockingAuthorisation)
        }
        if let disabled {
            action.disabled = disabled
        }

        try await action.save(on: localStore.database)

        switch action.payload {
            case .mcpBundle:
                try await mcpManager.refreshMCPAction(action)
            case .skill:
                try await skillManager.refreshSkillAction(action)
            case .primitive:
                try await primitiveActionManager.refreshPrimitiveAction(action)
            case .filesystem:
                try await filesystemActionManager.refreshFilesystemAction(action)
            case .semanticRetrieval:
                break
        }

        await invalidateActionToolCatalog(
            reason: "modify_action action=\(actionID.uuidString.lowercased())"
        )

        return action
    }

    public func removeMCPAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: {
                await self.mcpManager.unregisterAction(actionID: $0)
            }
        )
        await invalidateActionToolCatalog(
            reason: "remove_mcp_action action=\(actionID.uuidString.lowercased())"
        )
    }

    public func removeSkillAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: {
                await self.skillManager.unregisterAction(actionID: $0)
            }
        )
        await invalidateActionToolCatalog(
            reason: "remove_skill_action action=\(actionID.uuidString.lowercased())"
        )
    }

    public func removePrimitiveAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: {
                await self.primitiveActionManager.unregisterAction(actionID: $0)
            }
        )
        await invalidateActionToolCatalog(
            reason:
                "remove_primitive_action action=\(actionID.uuidString.lowercased())"
        )
    }

    /// Removes a semantic retrieval action and its grants. No executor to unregister.
    public func removeSemanticRetrievalAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: nil
        )
        await invalidateActionToolCatalog(
            reason: "remove_semantic_retrieval_action action=\(actionID.uuidString.lowercased())"
        )
    }

    public func removeFilesystemAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: { id in
                await self.filesystemActionManager.unregisterAction(actionID: id)
            }
        )
        await invalidateActionToolCatalog(
            reason: "remove_filesystem_action action=\(actionID.uuidString.lowercased())"
        )
    }

    static public func removeMCPAction(
        actionID: UUID,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForUnregisteringAction: ((UUID) async -> Void)? = nil
    ) async throws {
        guard
            let action = try await KeepTalkingAction.query(
                on: database
            )
            .filter(\.$id, .equal, actionID)
            //            .filter(\.$node.$id, .equal, try node.requireID())
            .first()
        else {
            throw KeepTalkingClientError.missingAction
        }

        if action.id != node.id {
            print(KeepTalkingClientError.actionNotHostedLocally(actionID))
        }

        let relations =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: database)
            .filter(\.$action.$id, .equal, actionID)
            .all()
        for relation in relations {
            try await relation.delete(on: database)
        }

        try await action.delete(on: database)
        await callbackForUnregisteringAction?(actionID)
    }

    public func listAvailableActions() async throws
        -> [KeepTalkingActionSummary]
    {
        let actions = try await KeepTalkingAction.query(on: localStore.database)
            .all()
        var summaries: [KeepTalkingActionSummary] = []

        for action in actions {
            guard let actionID = action.id else { continue }

            let grants =
                try await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$action.$id, .equal, actionID)
                .with(\.$relation)
                .all()
                .compactMap { link -> KeepTalkingActionGrantSummary? in
                    let relation = link.relation
                    guard relation.$from.id == config.node else { return nil }
                    return KeepTalkingActionGrantSummary(
                        toNodeID: relation.$to.id,
                        approvingContext: link.approvingContext,
                        permission: link.permission
                    )
                }

            let isMCP: Bool
            let isSkill: Bool
            let isPrimitive: Bool
            let isFilesystem: Bool
            let name: String
            let description: String
            switch action.payload {
                case .mcpBundle(let bundle):
                    isMCP = true
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                case .skill(let bundle):
                    isMCP = false
                    isSkill = true
                    isPrimitive = false
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                case .primitive(let bundle):
                    isMCP = false
                    isSkill = false
                    isPrimitive = true
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                case .filesystem(let bundle):
                    isMCP = false
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = true
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                default:
                    isMCP = false
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = false
                    name = "unknown"
                    description = action.descriptor?.action?.description ?? ""
            }

            summaries.append(
                KeepTalkingActionSummary(
                    actionID: actionID,
                    ownerNodeID: action.$node.id,
                    isMCP: isMCP,
                    isSkill: isSkill,
                    isPrimitive: isPrimitive,
                    isFilesystem: isFilesystem,
                    name: name,
                    description: description,
                    hostedLocally: action.$node.id == config.node,
                    remoteAuthorisable: action.remoteAuthorisable ?? false,
                    grants: grants
                )
            )
        }

        return summaries.sorted { lhs, rhs in
            if lhs.hostedLocally != rhs.hostedLocally {
                return lhs.hostedLocally && !rhs.hostedLocally
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.actionID.uuidString < rhs.actionID.uuidString
        }
    }

    static public func grantActionPermission(
        actionID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        permission: KeepTalkingGrantPermission? = nil,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        guard
            let action = try await KeepTalkingAction.find(actionID, on: database)
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }
        let hostNode = try await resolveGrantHostNode(
            for: action,
            authorizingNode: node,
            on: database
        )

        guard
            let hostNodeID = hostNode.id,
            let relation = try await preferredTrustedRelation(
                from: hostNodeID,
                to: toNodeID,
                on: database
            )
        else {
            // TODO: The error is inaccurate
            throw KeepTalkingClientError.relationNotTrustedOrOwned(toNodeID)
        }

        var targetActionRelation = try await relation.$actionRelations.query(
            on: database
        ).filter(\.$action.$id == actionID).first()

        if targetActionRelation == nil {
            switch scope {
                case .all:
                    targetActionRelation = try .init(
                        relation: relation,
                        action: action,
                        approvingContext: .all,
                        permission: permission
                    )
                case .context(let approvingContext):
                    targetActionRelation = try .init(
                        relation: relation,
                        action: action,
                        approvingContext: .contexts([approvingContext]),
                        permission: permission
                    )
            }

            try await targetActionRelation!.create(on: database)
        } else {
            targetActionRelation!.approvingContext = mergedApprovingContext(
                current: targetActionRelation!.approvingContext,
                requestedScope: scope
            )
            if let permission {
                targetActionRelation!.permission = permission
            }

            try await targetActionRelation!.update(on: database)
        }

        await callbackForBroadcasting?(
            "grant action=\(actionID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    public func grantActionPermission(
        actionID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope,
        permission: KeepTalkingGrantPermission? = nil
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.grantActionPermission(
            actionID: actionID,
            toNodeID: toNodeID,
            scope: scope,
            permission: permission,
            node: selfNode,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        let contextID: UUID? = {
            switch scope {
                case .all: return nil
                case .context(let ctx): return ctx.id
            }
        }()
        await invalidateActionToolCatalog(
            contextID: contextID,
            reason:
                "grant_action_permission action=\(actionID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    /// Updates the permission on a specific grant row (identified by its primary key).
    public func updateGrantPermission(
        grantID: UUID,
        permission: KeepTalkingGrantPermission?
    ) async throws {
        guard
            let grant = try await KeepTalkingNodeRelationActionRelation.find(
                grantID, on: localStore.database
            )
        else {
            throw KeepTalkingClientError.missingAction
        }
        grant.permission = permission
        try await grant.update(on: localStore.database)
        await broadcastLocalNodeState(
            reason: "update_grant_permission grant=\(grantID.uuidString.lowercased())"
        )

        switch grant.approvingContext {
            case .all:
                await invalidateActionToolCatalog(reason: "update_grant_permission_all")
            case .contexts(let contexts):
                for contextID in contexts.compactMap(\.id) {
                    await invalidateActionToolCatalog(contextID: contextID, reason: "update_grant_permission_context")
                }
            case nil:
                break
        }
    }

    /// Returns the effective permission mask a node has for a given action in context.
    ///
    /// The mask is the union of all applicable grant relations. If the caller is
    /// the owner node itself, `.all` is returned unconditionally.
    /// Returns `[]` (empty) if the action is not granted to the node.
    func effectiveGrantMask(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> KeepTalkingActionPermissionMask {
        let nodeID = try node.requireID()
        guard let ownerNodeID = action.$node.id else { return [] }

        // Owner always has full access to their own actions.
        if nodeID == ownerNodeID {
            return .all
        }

        let selfNode = try await getCurrentNodeInstance()

        guard
            let relation = try await Self.preferredTrustedRelation(
                from: ownerNodeID,
                to: nodeID,
                allowing: context,
                allowPending: ownerNodeID != (try? selfNode.requireID()),
                on: localStore.database
            )
        else {
            return []
        }

        let approvals =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id == (try relation.requireID()))
            .filter(\.$action.$id, .equal, try action.requireID())
            .all()

        var merged: KeepTalkingActionPermissionMask = []
        var anyApplicable = false
        for approval in approvals where approval.applicable(in: context) {
            anyApplicable = true
            merged.formUnion(approval.effectiveFilesystemMask)
        }

        return anyApplicable ? merged : []
    }

    /// Lists the tool names currently exposed by a locally-hosted MCP action.
    public func listMCPToolNames(actionID: UUID) async throws -> [String] {
        guard
            let action = try await KeepTalkingAction.find(actionID, on: localStore.database)
        else {
            throw KeepTalkingClientError.missingAction
        }
        let names = try await mcpManager.listActionToolNames(action: action)
        await cacheMCPTools(actionID: actionID, toolNames: names)

        return names
    }

    /// Persists a freshly-fetched tool list into the action's bundle in the DB.
    /// Called by the MCPManager `onToolsFetched` callback so every live server
    /// listing is automatically reflected in the stored payload.
    public func cacheMCPTools(actionID: UUID, toolNames: [String]) async {
        guard
            let action = try? await KeepTalkingAction.find(actionID, on: localStore.database),
            case .mcpBundle(var bundle) = action.payload
        else {
            return
        }
        bundle.cachedTools = toolNames
        action.payload = .mcpBundle(bundle)
        try? await action.save(on: localStore.database)
    }

    /// Returns the effective MCP tool allowlist for a caller on a given action in context.
    ///
    /// Returns `nil` if all tools are permitted (owner access or no restriction set).
    /// Returns an empty set if the action is not granted.
    /// Returns a non-nil set when at least one grant has an explicit allowlist;
    /// the result is the union of all applicable allowlists.
    func effectiveAllowedMCPTools(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Set<String>? {
        let nodeID = try node.requireID()
        guard let ownerNodeID = action.$node.id else { return Set() }

        if nodeID == ownerNodeID { return nil }

        let selfNode = try await getCurrentNodeInstance()

        guard
            let relation = try await Self.preferredTrustedRelation(
                from: ownerNodeID,
                to: nodeID,
                allowing: context,
                allowPending: ownerNodeID != (try? selfNode.requireID()),
                on: localStore.database
            )
        else {
            return Set()
        }

        let approvals =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id == (try relation.requireID()))
            .filter(\.$action.$id, .equal, try action.requireID())
            .all()

        var merged: Set<String> = []
        var anyApplicable = false
        var anyUnrestricted = false

        for approval in approvals where approval.applicable(in: context) {
            anyApplicable = true
            let tools = approval.effectiveMCPAllowedTools
            if tools == nil {
                anyUnrestricted = true
            } else {
                merged.formUnion(tools!)
            }
        }

        guard anyApplicable else { return Set() }
        return anyUnrestricted ? nil : merged
    }

    static public func revokeActionPermission(
        actionID: UUID,
        fromNodeID: UUID,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        let hostNode = try await resolveGrantHostNode(
            for: try await KeepTalkingAction.find(actionID, on: database)
                ?? { throw KeepTalkingClientError.actionNotHostedLocally(actionID) }(),
            authorizingNode: node,
            on: database
        )

        guard
            let hostNodeID = hostNode.id,
            let relation = try await preferredTrustedRelation(
                from: hostNodeID,
                to: fromNodeID,
                on: database
            )
        else {
            throw KeepTalkingClientError.relationNotTrustedOrOwned(fromNodeID)
        }

        let actionRelations = try await relation.$actionRelations.query(
            on: database
        ).filter(\.$action.$id == actionID).all()

        for actionRelation in actionRelations {
            try await actionRelation.delete(on: database)
        }

        await callbackForBroadcasting?(
            "revoke action=\(actionID.uuidString.lowercased()) from=\(fromNodeID.uuidString.lowercased())"
        )
    }

    public func revokeActionPermission(
        actionID: UUID,
        fromNodeID: UUID
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.revokeActionPermission(
            actionID: actionID,
            fromNodeID: fromNodeID,
            node: selfNode,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
    }

    /// Revokes a single grant row by its primary key, leaving any other
    /// context-scoped grants for the same node intact.
    public func revokeActionPermissionGrant(grantID: UUID) async throws {
        guard
            let row = try await KeepTalkingNodeRelationActionRelation.find(
                grantID,
                on: localStore.database
            )
        else { return }
        let actionID = row.$action.id
        try await row.delete(on: localStore.database)
        await broadcastLocalNodeState(
            reason: "revoke-grant grant=\(grantID.uuidString.lowercased()) action=\(actionID.uuidString.lowercased())"
        )
    }

    /// Removes a single context from a `.contexts([...])` grant row.
    /// If it is the last context in the row the entire row is deleted.
    public func revokeContextFromGrant(grantID: UUID, contextID: UUID) async throws {
        guard
            let row = try await KeepTalkingNodeRelationActionRelation.find(
                grantID,
                on: localStore.database
            )
        else { return }

        guard case .contexts(let contexts) = row.approvingContext else {
            // .all grant — delete the whole row
            try await row.delete(on: localStore.database)
            await broadcastLocalNodeState(
                reason:
                    "revoke-grant grant=\(grantID.uuidString.lowercased()) context=\(contextID.uuidString.lowercased())"
            )
            return
        }

        let remaining = contexts.filter { $0.id != contextID }
        if remaining.isEmpty {
            try await row.delete(on: localStore.database)
        } else {
            row.approvingContext = .contexts(remaining)
            try await row.save(on: localStore.database)
        }
        await broadcastLocalNodeState(
            reason:
                "revoke-context grant=\(grantID.uuidString.lowercased()) context=\(contextID.uuidString.lowercased())"
        )
    }

    func mergeNodeActions(_ actions: [KeepTalkingAdvertisedAction]) async throws {
        let advertisedActions = deduplicatedAndSortedActions(
            actions
        )

        for incomingAction in advertisedActions {
            let actionID = incomingAction.actionID

            let persistedAction: KeepTalkingAction
            let existingDescriptor: KeepTalkingActionDescriptor?
            let existingPayload: KeepTalkingAction.Payload?

            if let existingAction = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .first() {
                persistedAction = existingAction
                existingDescriptor = existingAction.descriptor
                existingPayload = existingAction.payload
            } else {
                let newAction = KeepTalkingAction()
                newAction.id = actionID
                persistedAction = newAction
                existingDescriptor = nil
                existingPayload = nil
            }

            let fallbackDescription =
                incomingAction.descriptor?.action?.description
                ?? "Virtual remote action \(actionID.uuidString.lowercased())"
            let resolvedDescriptor =
                incomingAction.descriptor
                ?? existingDescriptor
                ?? KeepTalkingActionDescriptor(
                    subject: nil,
                    action: KeepTalkingActionWithDescription(
                        description: fallbackDescription
                    ),
                    object: nil
                )
            let resolvedPayload: KeepTalkingAction.Payload =
                existingPayload
                ?? .mcpBundle(
                    virtualRemoteMCPBundle(
                        actionID: actionID,
                        name:
                            "remote_\(actionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))",
                        description: fallbackDescription
                    )
                )
            let materializedPayload = materializedRemotePayload(
                from: incomingAction,
                fallbackDescription: fallbackDescription
            )

            // Only adopt the advertised owner when we don't already know one,
            // and never overwrite a known owner with nil — a stale or partial
            // advertisement otherwise orphans the action and the catalog drops
            // it (guard let ownerNodeID = action.$node.id).
            if let advertisedOwnerID = incomingAction.ownerNodeID,
                persistedAction.$node.id == nil
                    || persistedAction.$node.id == advertisedOwnerID
            {
                persistedAction.$node.id = advertisedOwnerID
            }
            persistedAction.descriptor = resolvedDescriptor
            persistedAction.payload = existingPayload ?? materializedPayload ?? resolvedPayload
            persistedAction.remoteAuthorisable =
                incomingAction.remoteAuthorisable
            persistedAction.blockingAuthorisation =
                incomingAction.blockingAuthorisation
            persistedAction.createdAt = incomingAction.createdAt
            persistedAction.lastUsed = incomingAction.lastUsed

            try await persistedAction.save(on: localStore.database)

            if persistedAction.$node.id == config.node,
                case .mcpBundle = persistedAction.payload
            {
                try await mcpManager.refreshMCPAction(persistedAction)
            } else if persistedAction.$node.id == config.node,
                case .skill = persistedAction.payload
            {
                try await skillManager.refreshSkillAction(persistedAction)
            } else if persistedAction.$node.id == config.node,
                case .primitive = persistedAction.payload
            {
                try await primitiveActionManager.refreshPrimitiveAction(
                    persistedAction
                )
            }
        }

        await invalidateActionToolCatalog(reason: "merge_node_actions")
    }

    private func virtualRemoteMCPBundle(
        actionID: UUID,
        name: String,
        description: String
    ) -> KeepTalkingMCPBundle {
        return KeepTalkingMCPBundle(
            id: actionID,
            name: name,
            indexDescription: description,
            service: .stdio(
                arguments: [
                    "__kt_virtual_remote_action__",
                    actionID.uuidString.lowercased(),
                ],
                environment: [:]
            )
        )
    }

    private func virtualRemoteSkillBundle(
        actionID: UUID,
        name: String,
        description: String
    ) -> KeepTalkingSkillBundle {
        KeepTalkingSkillBundle(
            id: actionID,
            name: name,
            indexDescription: description,
            directory: URL(
                fileURLWithPath:
                    "/__kt_remote_skill__/\(actionID.uuidString.lowercased())"
            )
        )
    }

    private func materializedRemotePayload(
        from action: KeepTalkingAdvertisedAction,
        fallbackDescription: String
    ) -> KeepTalkingAction.Payload? {
        switch action.payloadSummary {
            case .mcpBundle(let name, let indexDescription):
                return .mcpBundle(
                    virtualRemoteMCPBundle(
                        actionID: action.actionID,
                        name: name,
                        description: indexDescription.isEmpty
                            ? fallbackDescription
                            : indexDescription
                    )
                )
            case .skill(let name, let indexDescription):
                return .skill(
                    virtualRemoteSkillBundle(
                        actionID: action.actionID,
                        name: name,
                        description: indexDescription.isEmpty
                            ? fallbackDescription
                            : indexDescription
                    )
                )
            case .primitive(let name, let indexDescription, let primitiveKind):
                return .primitive(
                    .init(
                        id: action.actionID,
                        name: name,
                        indexDescription: indexDescription.isEmpty
                            ? fallbackDescription
                            : indexDescription,
                        action: primitiveKind
                    )
                )
            case .semanticRetrieval(let name, let indexDescription):
                return .semanticRetrieval(
                    .init(
                        id: action.actionID,
                        name: name,
                        indexDescription: indexDescription,
                        contextIDs: []
                    )
                )
            case .filesystem(let name, let indexDescription):
                return .filesystem(
                    KeepTalkingFilesystemBundle(
                        id: action.actionID,
                        name: name,
                        indexDescription: indexDescription,
                        rootPath: nil
                    )
                )
        }
    }

    private static func defaultDescriptor(
        for bundle: KeepTalkingMCPBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

    private static func defaultDescriptor(
        for bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

    private static func defaultDescriptor(
        for bundle: KeepTalkingPrimitiveBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

    private static func defaultDescriptor(
        for bundle: KeepTalkingSemanticRetrievalBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

    private static func defaultDescriptor(
        for bundle: KeepTalkingFilesystemBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

}
