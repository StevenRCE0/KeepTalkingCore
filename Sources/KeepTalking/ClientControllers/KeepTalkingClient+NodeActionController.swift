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
                return 4
            case .trustedInAllContext:
                return 3
            case .trusted:
                return 2
            case .preTrusted:
                return 1
            case .pending:
                return 0
        }
    }

    static func preferredTrustedRelation(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        allowing context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        on database: any Database
    ) async throws -> KeepTalkingNodeRelation? {
        try await trustedRelations(
            from: fromNodeID,
            to: toNodeID,
            allowing: context,
            eligibility: eligibility,
            on: database
        ).first
    }

    static func trustedRelations(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        allowing context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        on database: any Database
    ) async throws -> [KeepTalkingNodeRelation] {
        try await KeepTalkingNodeRelation
            .query(on: database)
            .filter(\.$from.$id, .equal, fromNodeID)
            .filter(\.$to.$id, .equal, toNodeID)
            .all()
            .sorted(by: {
                let lhs = relationPriority($0.relationship)
                let rhs = relationPriority($1.relationship)
                return lhs == rhs
                    ? ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                    : lhs > rhs
            })
            .filter { relation in
                switch eligibility {
                    case .trustedOnly:
                        return relation.relationship.isTrustedOrOwner
                            && relation.relationship.allows(context: context)
                    case .grantStaging:
                        return relation.relationship.allowsGrantStaging(
                            context: context
                        )
                }
            }
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

    static func resolveGrantHostNode(
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

    static func mergedApprovingContext(
        current: KeepTalkingNodeRelationApprovingContext?,
        requestedScope: KeepTalkingActionPermissionScope
    ) -> KeepTalkingNodeRelationApprovingContext {
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
                case .acp(let b): action.descriptor = Self.defaultDescriptor(for: b)
                case .plugin(let b): action.descriptor = Self.defaultDescriptor(for: b)
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

    /// Moves any HTTP MCP request headers out of the action's database payload
    /// and into the keychain-backed credential store, leaving the persisted
    /// bundle with empty headers. Credentials (bearer tokens, API keys) must
    /// never be written to the DB. A bundle whose headers are already empty is
    /// left untouched, preserving whatever was stored directly via
    /// `storeMCPCredentials`. Existing client secrets are preserved across the
    /// move.
    private func relocateHTTPMCPCredentials(
        from action: KeepTalkingAction
    ) async {
        guard let actionID = action.id,
            case .mcpBundle(var bundle) = action.payload,
            case .http(let url, let payload, let headers, let scope) =
                bundle.service,
            !headers.isEmpty
        else {
            return
        }
        var merged =
            (try? await mcpCredentialStore.load(actionID: actionID))
            ?? KeepTalkingMCPCredentials()
        merged.headers = headers
        try? await mcpCredentialStore.store(merged, actionID: actionID)
        bundle.service = .http(
            url: url,
            payload: payload,
            headers: [:],
            scope: scope
        )
        action.payload = .mcpBundle(bundle)
    }

    public func saveConstructedAction(
        _ action: KeepTalkingAction
    ) async throws -> KeepTalkingAction {
        let payload = action.payload

        if action.id == nil {
            action.id = UUID.v7()
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
                case .acp(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .plugin(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
            }
        }

        await relocateHTTPMCPCredentials(from: action)
        try await action.save(on: localStore.database)
        // A freshly-saved action with `disabled = true` should not spin up
        // any runtime — register the metadata, then immediately tear down the
        // server so it lands in `.disabled` instead of `.connected`.
        let isDisabledAtSave = action.disabled == true
        switch payload {
            case .mcpBundle:
                try await mcpManager.registerMCPAction(action)
                if isDisabledAtSave, let actionID = action.id {
                    await mcpManager.disableAction(actionID: actionID)
                }
            case .skill:
                try await skillManager.registerSkillAction(action)
            case .primitive:
                try await primitiveActionManager.registerPrimitiveAction(action)
            case .semanticRetrieval:
                try await semanticRetrievalActionManager.registerIfNeeded(action)
            case .filesystem:
                try await filesystemActionManager.registerFilesystemAction(action)
            case .acp:
                #if os(macOS)
                try await acpManager.registerACPAction(action)
                if isDisabledAtSave, let actionID = action.id {
                    await acpManager.disableAction(actionID: actionID)
                }
                #endif
            case .plugin:
                // No executor to register: the plugin process attaches on its
                // own and the Catalogue already holds its kind declaration.
                break
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
                case .acp(let bundle):
                    action.descriptor = Self.defaultDescriptor(for: bundle)
                case .plugin(let bundle):
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

        await relocateHTTPMCPCredentials(from: action)
        try await action.save(on: localStore.database)

        let isDisabledNow = action.disabled == true
        switch action.payload {
            case .mcpBundle:
                if isDisabledNow {
                    // User just turned the action off — tear the live MCP
                    // server down rather than reconnecting it. Health flips
                    // to `.disabled`, which the next node-status broadcast
                    // surfaces to peers.
                    await mcpManager.disableAction(actionID: actionID)
                } else {
                    // Either still enabled, or just re-enabled — refresh
                    // (re)spins up the connection.
                    try await mcpManager.refreshMCPAction(action)
                }
            case .skill:
                try await skillManager.refreshSkillAction(action)
            case .primitive:
                try await primitiveActionManager.refreshPrimitiveAction(action)
            case .filesystem:
                try await filesystemActionManager.refreshFilesystemAction(action)
            case .acp:
                #if os(macOS)
                if isDisabledNow {
                    await acpManager.disableAction(actionID: actionID)
                } else {
                    try await acpManager.refreshACPAction(action)
                }
                #endif
            case .plugin:
                // Nothing to refresh: the plugin process owns its own
                // lifecycle. `disabled` is honoured at call time by the
                // normal action gating.
                break
            case .semanticRetrieval:
                break
        }

        await invalidateActionToolCatalog(
            reason: "modify_action action=\(actionID.uuidString.lowercased())"
        )

        // Push the change out so peers see the new availability state
        // (disabled, available, failed, etc.) without waiting for the next
        // periodic sync.
        Task { [weak self] in
            await self?.broadcastLocalNodeState(
                reason: "modify_action action=\(actionID.uuidString.lowercased())"
            )
        }

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
        // Drop the keychain-only credentials alongside the action itself.
        try? await mcpCredentialStore.delete(actionID: actionID)
        await invalidateActionToolCatalog(
            reason: "remove_mcp_action action=\(actionID.uuidString.lowercased())"
        )
        await broadcastLocalNodeState(
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
        await broadcastLocalNodeState(
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
        await broadcastLocalNodeState(
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
        await broadcastLocalNodeState(
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
        await broadcastLocalNodeState(
            reason: "remove_filesystem_action action=\(actionID.uuidString.lowercased())"
        )
    }

    public func removeACPAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: { id in
                #if os(macOS)
                await self.acpManager.unregisterAction(actionID: id)
                #endif
            }
        )
        await invalidateActionToolCatalog(
            reason: "remove_acp_action action=\(actionID.uuidString.lowercased())"
        )
        await broadcastLocalNodeState(
            reason: "remove_acp_action action=\(actionID.uuidString.lowercased())"
        )
    }

    /// Removes a cached remote action. A later node-status advertisement may
    /// materialize it again.
    public func forgetRemoteAction(actionID: UUID) async throws {
        guard
            let action = try await KeepTalkingAction.find(
                actionID,
                on: localStore.database
            )
        else {
            throw KeepTalkingClientError.missingAction
        }
        guard action.$node.id != config.node else {
            throw KeepTalkingClientError.notAuthorized
        }

        let relations = try await KeepTalkingNodeRelationActionRelation.query(
            on: localStore.database
        )
        .filter(\.$action.$id, .equal, actionID)
        .all()
        for relation in relations {
            try await relation.delete(on: localStore.database)
        }
        try await action.delete(on: localStore.database)

        await invalidateActionToolCatalog(
            reason: "forget_remote_action action=\(actionID.uuidString.lowercased())"
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
                case .plugin(let bundle):
                    isMCP = false
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                case .acp(let bundle):
                    isMCP = false
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                case .semanticRetrieval(let bundle):
                    isMCP = false
                    isSkill = false
                    isPrimitive = false
                    isFilesystem = false
                    name = bundle.name
                    description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
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
        grantScope: KeepTalkingActionScope? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
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
        let grantContext: KeepTalkingContext? = {
            switch scope {
                case .all:
                    return nil
                case .context(let context):
                    return context
            }
        }()

        guard
            let hostNodeID = hostNode.id,
            let relation = try await preferredTrustedRelation(
                from: hostNodeID,
                to: toNodeID,
                allowing: grantContext,
                eligibility: eligibility,
                on: database
            )
        else {
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
                        permission: grantScope
                    )
                case .context(let approvingContext):
                    targetActionRelation = try .init(
                        relation: relation,
                        action: action,
                        approvingContext: .contexts([approvingContext]),
                        permission: grantScope
                    )
            }

            try await targetActionRelation!.create(on: database)
        } else {
            targetActionRelation!.approvingContext = mergedApprovingContext(
                current: targetActionRelation!.approvingContext,
                requestedScope: scope
            )
            if let grantScope {
                targetActionRelation!.permission = grantScope
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
        grantScope: KeepTalkingActionScope? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
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
            grantScope: grantScope,
            eligibility: eligibility,
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

    static public func grantActionPermission(
        transaction: KeepTalkingGrantTransaction,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        let entries = transaction.entries
        guard !entries.isEmpty else { return }

        try await database.transaction { database in
            for entry in entries {
                switch entry.change {
                    case .grant(let scope):
                        if let contextID = entry.key.contextID {
                            try await stageActionPermissionWithTrustInvitation(
                                contextID: contextID,
                                actionID: entry.key.actionID,
                                toNodeID: entry.key.nodeID,
                                grantScope: scope,
                                node: node,
                                on: database
                            )
                        } else {
                            try await grantActionPermission(
                                actionID: entry.key.actionID,
                                toNodeID: entry.key.nodeID,
                                scope: .all,
                                grantScope: scope,
                                node: node,
                                on: database
                            )
                        }
                    case .revoke:
                        let context: KeepTalkingContext?
                        if let contextID = entry.key.contextID {
                            context = try await ensureContext(contextID, on: database)
                        } else {
                            context = nil
                        }
                        try await revokeActionPermission(
                            actionID: entry.key.actionID,
                            fromNodeID: entry.key.nodeID,
                            context: context,
                            eligibility: context == nil ? .trustedOnly : .grantStaging,
                            node: node,
                            on: database
                        )
                }
            }
        }

        await callbackForBroadcasting?(
            "grant transaction entries=\(entries.count)"
        )
    }

    public func grantActionPermission(
        transaction: KeepTalkingGrantTransaction
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.grantActionPermission(
            transaction: transaction,
            node: selfNode,
            on: localStore.database,
            callbackForBroadcasting: {
                await self.broadcastLocalNodeState(reason: $0)
            }
        )
        for contextID in Set(transaction.entries.map(\.key.contextID)) {
            await invalidateActionToolCatalog(
                contextID: contextID,
                reason: "grant_transaction"
            )
        }
    }

    static public func stageActionPermissionWithTrustInvitation(
        contextID: UUID,
        actionID: UUID,
        toNodeID: UUID,
        grantScope: KeepTalkingActionScope? = nil,
        node: KeepTalkingNode,
        on database: any Database,
        callbackForBroadcasting: ((String) async -> Void)? = nil
    ) async throws {
        let context = try await ensureContext(contextID, on: database)
        guard let action = try await KeepTalkingAction.find(actionID, on: database) else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }
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

        try await grantActionPermission(
            actionID: actionID,
            toNodeID: toNodeID,
            scope: .context(context),
            grantScope: grantScope,
            eligibility: .grantStaging,
            node: node,
            on: database,
            callbackForBroadcasting: callbackForBroadcasting
        )
    }

    public func stageActionPermissionWithTrustInvitation(
        contextID: UUID,
        actionID: UUID,
        toNodeID: UUID,
        grantScope: KeepTalkingActionScope? = nil
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.stageActionPermissionWithTrustInvitation(
            contextID: contextID,
            actionID: actionID,
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
                "stage_action_permission action=\(actionID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    /// Updates the permission on a specific grant row (identified by its primary key).
    public func updateGrantPermission(
        grantID: UUID,
        grantScope: KeepTalkingActionScope?
    ) async throws {
        guard
            let grant = try await KeepTalkingNodeRelationActionRelation.find(
                grantID, on: localStore.database
            )
        else {
            throw KeepTalkingClientError.missingAction
        }
        grant.permission = grantScope
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

    /// Returns the effective permission allowed for `node` on `action`.
    ///
    /// Direct action grants and grants inherited from active action tags are
    /// additive. This is the sole grant gate used by execution, advertisement,
    /// and UI availability.
    ///
    /// `eligibility` selects which relations count. The default `.trustedOnly`
    /// answers "may this peer use the action right now". `.grantStaging` also
    /// counts pre-trusted relations, answering "does a grant exist at all" —
    /// which is what the trust-invitation invariant is keyed on, since a
    /// pending invitee is pre-trusted by construction.
    public static func allowedActionScope(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
        on database: any Database
    ) async throws -> KeepTalkingActionScope? {
        let nodeID = try node.requireID()
        let actionID = try action.requireID()
        guard let ownerNodeID = action.$node.id else { return nil }

        let relationIDs = try await trustedRelations(
            from: ownerNodeID,
            to: nodeID,
            allowing: context,
            eligibility: eligibility,
            on: database
        )
        .compactMap(\.id)
        guard !relationIDs.isEmpty else { return nil }

        let directPermissions =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: database)
            .filter(\.$relation.$id ~~ relationIDs)
            .filter(\.$action.$id, .equal, actionID)
            .all()
            .filter { $0.applicable(in: context) }
            .map { $0.permission ?? .all }
        let aliasPermissions = try await aliasGrantPermissions(
            forActionID: actionID,
            relationIDs: relationIDs,
            context: context,
            on: database
        )
        let permissions = directPermissions + aliasPermissions
        guard !permissions.isEmpty else { return nil }
        return KeepTalkingActionScope.union(permissions)
    }

    public func allowedActionScope(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
    ) async throws -> KeepTalkingActionScope? {
        try await Self.allowedActionScope(
            node: node,
            action: action,
            context: context,
            eligibility: eligibility,
            on: localStore.database
        )
    }

    /// Whether `nodeID` still holds any grant — direct or tag-inherited — on
    /// any action hosted by `hostNodeID`, within `context`.
    ///
    /// Routed through `allowedActionScope` so the action/alias union stays in
    /// one place; `.grantStaging` is used because the peers this question is
    /// asked about are pre-trusted (invitation pending), not yet trusted.
    static func holdsAnyGrant(
        from hostNodeID: UUID,
        to nodeID: UUID,
        in context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> Bool {
        let node = KeepTalkingNode(id: nodeID)
        let hostedActions = try await KeepTalkingAction.query(on: database)
            .filter(\.$node.$id, .equal, hostNodeID)
            .all()

        for action in hostedActions {
            let scope = try await allowedActionScope(
                node: node,
                action: action,
                context: context,
                eligibility: .grantStaging,
                on: database
            )
            if scope != nil { return true }
        }
        return false
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

    static public func revokeActionPermission(
        actionID: UUID,
        fromNodeID: UUID,
        context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly,
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
                allowing: context,
                eligibility: eligibility,
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

        try await reconcilePendingTrustInvitations(
            from: hostNodeID,
            to: fromNodeID,
            in: context,
            on: database
        )

        await callbackForBroadcasting?(
            "revoke action=\(actionID.uuidString.lowercased()) from=\(fromNodeID.uuidString.lowercased())"
        )
    }

    public func revokeActionPermission(
        actionID: UUID,
        fromNodeID: UUID,
        context: KeepTalkingContext? = nil,
        eligibility: KeepTalkingRelationEligibility = .trustedOnly
    ) async throws {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        try await Self.revokeActionPermission(
            actionID: actionID,
            fromNodeID: fromNodeID,
            context: context,
            eligibility: eligibility,
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
        let revokedContexts = Self.contexts(of: row.approvingContext)
        let relationID = row.$relation.id
        try await row.delete(on: localStore.database)
        try await Self.reconcilePendingTrustInvitations(
            forRelation: relationID,
            in: revokedContexts,
            on: localStore.database
        )
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
            // .all grant — delete the whole row, and sweep every context it
            // was covering rather than just the one named here.
            let relationID = row.$relation.id
            try await row.delete(on: localStore.database)
            try await Self.reconcilePendingTrustInvitations(
                forRelation: relationID,
                in: nil,
                on: localStore.database
            )
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
        try await Self.reconcilePendingTrustInvitations(
            forRelation: row.$relation.id,
            in: [KeepTalkingContext(id: contextID)],
            on: localStore.database
        )
        await broadcastLocalNodeState(
            reason:
                "revoke-context grant=\(grantID.uuidString.lowercased()) context=\(contextID.uuidString.lowercased())"
        )
    }

    /// Contexts a grant row applied to, or `nil` for an all-contexts grant —
    /// which reconciles as a full sweep.
    static func contexts(
        of approvingContext: KeepTalkingNodeRelationApprovingContext?
    ) -> [KeepTalkingContext]? {
        switch approvingContext {
            case .contexts(let contexts):
                return contexts
            case .all, nil:
                return nil
        }
    }

    /// Reconciles invitations for the pair behind `relationID`. `contexts` of
    /// `nil` sweeps every context the pair has a pending invitation in.
    static func reconcilePendingTrustInvitations(
        forRelation relationID: UUID,
        in contexts: [KeepTalkingContext]?,
        on database: any Database
    ) async throws {
        guard
            let relation = try await KeepTalkingNodeRelation.find(
                relationID,
                on: database
            )
        else { return }

        let targets: [KeepTalkingContext?] = contexts ?? [nil]
        for context in targets {
            try await reconcilePendingTrustInvitations(
                from: relation.$from.id,
                to: relation.$to.id,
                in: context,
                on: database
            )
        }
    }

    /// Upserts the action metadata carried by a context-scoped node status.
    /// Grant replacement is handled separately: absence here means "not granted
    /// in this context", not "deleted by its owner".
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

            if let existingOwnerID = persistedAction.$node.id,
                let advertisedOwnerID = incomingAction.ownerNodeID,
                existingOwnerID != advertisedOwnerID
            {
                continue
            }

            let isLocallyHosted = persistedAction.$node.id == config.node

            let advertisedIndexDescription: String = {
                switch incomingAction.payloadSummary {
                    case .mcpBundle(_, let description),
                        .skill(_, let description),
                        .semanticRetrieval(_, let description),
                        .filesystem(_, let description),
                        .acp(_, let description),
                        .primitive(_, let description, _):
                        return description
                }
            }()
            let fallbackDescription =
                incomingAction.descriptor?.action?.description
                ?? (advertisedIndexDescription.isEmpty
                    ? "Virtual remote action \(actionID.uuidString.lowercased())"
                    : advertisedIndexDescription)
            let advertisedDescriptor =
                incomingAction.descriptor
                ?? KeepTalkingActionDescriptor(
                    subject: nil,
                    action: KeepTalkingActionWithDescription(
                        description: fallbackDescription
                    ),
                    object: nil
                )
            let resolvedDescriptor =
                isLocallyHosted
                ? existingDescriptor ?? advertisedDescriptor
                : advertisedDescriptor
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
            persistedAction.payload =
                isLocallyHosted
                ? existingPayload ?? materializedPayload ?? resolvedPayload
                : materializedPayload ?? existingPayload ?? resolvedPayload
            persistedAction.remoteAuthorisable =
                incomingAction.remoteAuthorisable
            persistedAction.blockingAuthorisation =
                incomingAction.blockingAuthorisation
            if !isLocallyHosted {
                persistedAction.disabled = incomingAction.availability == .disabled
            }
            persistedAction.createdAt =
                incomingAction.createdAt ?? persistedAction.createdAt ?? .now
            persistedAction.lastUsed =
                incomingAction.lastUsed ?? persistedAction.lastUsed

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
        description: String,
        tools: [String]? = nil
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
            ),
            cachedTools: tools
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
            ),
            // Remote skills only enter the wire when the owner has analysed
            // them (we filter un-analysed skills out at the broadcaster), so
            // ingestion can treat them as analysed unconditionally — the UI
            // shouldn't show an "analyse this" prompt for something we can
            // only ever invoke remotely.
            toolsAnalysed: true
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
                            : indexDescription,
                        tools: action.tools
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
                        // Remote stubs carry no root; an empty root fails closed
                        // at execution (no unsandboxed filesystem action).
                        rootPath: ""
                    )
                )
            case .acp(let name, let indexDescription):
                return .acp(
                    KeepTalkingACPBundle(
                        id: action.actionID,
                        name: name,
                        indexDescription: indexDescription,
                        // Remote stub: the agent runs on the owner node, so the
                        // local copy carries no command/cwd of its own.
                        cwd: URL(fileURLWithPath: "/")
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

    private static func defaultDescriptor(
        for bundle: KeepTalkingACPBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription
            ),
            object: nil
        )
    }

    /// Catalogue instances declare `.callTool` so the grant editor can narrow
    /// to individual sub-tools, exactly as MCP-backed actions do. No sandbox
    /// verbs: KT never launches the plugin process (design doc §9).
    private static func defaultDescriptor(
        for bundle: KeepTalkingPluginBundle
    ) -> KeepTalkingActionDescriptor {
        KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(
                description: bundle.indexDescription,
                verbs: [.callTool]
            ),
            object: nil
        )
    }

}
