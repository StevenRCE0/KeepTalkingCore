import FluentKit
import Foundation

public enum KeepTalkingActionPermissionScope: Sendable {
    case all
    case context(KeepTalkingContext)
}

public struct KeepTalkingActionGrantSummary: Sendable {
    public let toNodeID: UUID
    public let approvingContext: KeepTalkingNodeRelationActionRelation.ApprovingContext?
}

public struct KeepTalkingActionSummary: Sendable {
    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let name: String
    public let description: String
    public let hostedLocally: Bool
    public let remoteAuthorisable: Bool
    public let grants: [KeepTalkingActionGrantSummary]
}

extension KeepTalkingClient {
    public func registerMCPAction(
        bundle: KeepTalkingMCPBundle,
        descriptor: KeepTalkingActionDescriptor? = nil,
        remoteAuthorisable: Bool = true,
        blockingAuthorisation: Bool = false
    ) async throws -> KeepTalkingAction {
        let node = try await getCurrentNodeInstance()

        let action = KeepTalkingAction(
            payload: .mcpBundle(bundle),
            remoteAuthorisable: remoteAuthorisable,
            blockingAuthorisation: blockingAuthorisation
        )
        action.$node.id = try node.requireID()
        action.descriptor = descriptor ?? defaultDescriptor(for: bundle)

        try await action.save(on: localStore.database)
        try await mcpManager.registerMCPAction(action)
        return action
    }

    public func modifyMCPAction(
        actionID: UUID,
        bundle: KeepTalkingMCPBundle? = nil,
        descriptor: KeepTalkingActionDescriptor? = nil,
        remoteAuthorisable: Bool? = nil,
        blockingAuthorisation: Bool? = nil
    ) async throws -> KeepTalkingAction {
        guard
            let action = try await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .filter(\.$node.$id, .equal, config.node)
                .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        if let bundle {
            action.payload = .mcpBundle(bundle)
        }
        if let descriptor {
            action.descriptor = descriptor
        } else if action.descriptor == nil,
                  case .mcpBundle(let existingBundle) = action.payload
        {
            action.descriptor = defaultDescriptor(for: existingBundle)
        }
        if let remoteAuthorisable {
            action.remoteAuthorisable = remoteAuthorisable
        }
        if let blockingAuthorisation {
            action.blockingAuthorisation = blockingAuthorisation
        }

        try await action.save(on: localStore.database)
        try await mcpManager.refreshMCPAction(action)
        return action
    }

    public func removeMCPAction(actionID: UUID) async throws {
        guard
            let action = try await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .filter(\.$node.$id, .equal, config.node)
                .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        let relations = try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$action.$id, .equal, actionID)
            .all()
        for relation in relations {
            try await relation.delete(on: localStore.database)
        }

        try await action.delete(on: localStore.database)
        await mcpManager.unregisterAction(actionID: actionID)
    }

    public func listAvailableActions() async throws -> [KeepTalkingActionSummary] {
        let actions = try await KeepTalkingAction.query(on: localStore.database).all()
        var summaries: [KeepTalkingActionSummary] = []

        for action in actions {
            guard let actionID = action.id else { continue }

            let grants = try await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$action.$id, .equal, actionID)
                .with(\.$relation)
                .all()
                .compactMap { link -> KeepTalkingActionGrantSummary? in
                    let relation = link.relation
                    guard relation.$from.id == config.node else { return nil }
                    return KeepTalkingActionGrantSummary(
                        toNodeID: relation.$to.id,
                        approvingContext: link.approvingContext
                    )
                }

            let name: String
            let description: String
            if case .mcpBundle(let bundle) = action.payload {
                name = bundle.name
                description =
                    action.descriptor?.action?.description
                    ?? bundle.indexDescription
            } else {
                name = "unknown"
                description = action.descriptor?.action?.description ?? ""
            }

            summaries.append(
                KeepTalkingActionSummary(
                    actionID: actionID,
                    ownerNodeID: action.$node.id,
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

    public func grantActionPermission(
        actionID: UUID,
        toNodeID: UUID,
        scope: KeepTalkingActionPermissionScope
    ) async throws {
        guard
            let action = try await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .filter(\.$node.$id, .equal, config.node)
                .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        guard
            let relation = try await KeepTalkingNodeRelation
                .query(on: localStore.database)
                .filter(\.$from.$id, .equal, config.node)
                .filter(\.$to.$id, .equal, toNodeID)
                .filter(\.$relationship ~~ [.owner, .trusted])
                .first()
        else {
            throw KeepTalkingClientError.relationNotTrustedOrOwned(toNodeID)
        }
        guard let relationID = relation.id else {
            throw KeepTalkingClientError.relationNotTrustedOrOwned(toNodeID)
        }

        let approvingContext: KeepTalkingNodeRelationActionRelation.ApprovingContext =
            switch scope {
            case .all:
                .all
            case .context(let context):
                .context(context)
            }

        if let existing = try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id, .equal, relationID)
            .filter(\.$action.$id, .equal, actionID)
            .first()
        {
            existing.approvingContext = approvingContext
            try await existing.save(on: localStore.database)
        } else {
            let link = try KeepTalkingNodeRelationActionRelation(
                relation: relation,
                action: action,
                approvingContext: approvingContext
            )
            try await link.save(on: localStore.database)
        }
    }

    public func registerCurrentNodeID() async throws {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        try await kvService.storeNodeID(config.node)
    }

    public func fetchNodeIDs(for userID: String? = nil) async throws -> [UUID] {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        return try await kvService.loadNodeIDs()
    }

    public func trust(node targetNodeID: UUID) async throws {
        guard targetNodeID != config.node else { return }

        let localNode = try await getCurrentNodeInstance()
        let localNodeID = try localNode.requireID()

        let remoteNode: KeepTalkingNode
        if let existing = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, targetNodeID)
            .first()
        {
            remoteNode = existing
        } else {
            remoteNode = KeepTalkingNode(id: targetNodeID)
            try await remoteNode.save(on: localStore.database)
        }

        if let relation = try await KeepTalkingNodeRelation
            .query(on: localStore.database)
            .filter(\.$from.$id, .equal, localNodeID)
            .filter(\.$to.$id, .equal, targetNodeID)
            .first()
        {
            relation.relationship = .trusted
            try await relation.save(on: localStore.database)
            return
        }

        let relation = try KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted
        )
        try await relation.save(on: localStore.database)
    }

    func getCurrentNodeInstance() async throws -> KeepTalkingNode {
        if let node = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, config.node)
            .first()
        {
            return node
        }

        let node = KeepTalkingNode(id: config.node)
        try await node.save(on: localStore.database)
        return node
    }

    func persistMyNode(_ explicitNode: KeepTalkingNode? = nil)
        async throws
    {
        let node: KeepTalkingNode
        if let explicitNode {
            node = explicitNode
        } else {
            node = try await getCurrentNodeInstance()
        }

        node.lastSeenAt = Date()
        node.discoveredDuringLogon = logon
        try await node.save(on: localStore.database)
    }

    func mergeDiscoveredNode(_ incoming: KeepTalkingNode) async throws {
        guard let incomingNodeID = incoming.id else {
            return
        }
        if incomingNodeID == config.node {
            return
        }

        if let existing = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, incomingNodeID)
            .first()
        {
            existing.lastSeenAt = max(existing.lastSeenAt, incoming.lastSeenAt)
            try await existing.save(on: localStore.database)
            return
        }

        let node = KeepTalkingNode(
            id: incomingNodeID,
            lastSeenAt: incoming.lastSeenAt,
            discoveredDuringLogon: nil
        )
        try await node.save(on: localStore.database)
    }

    func markNodeDiscoveredBySignaling(_ nodeID: UUID) async throws {
        guard nodeID != config.node else {
            return
        }
        guard try await isTrustedOrOwned(nodeID: nodeID) else {
            return
        }

        let node: KeepTalkingNode
        if let existing = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, nodeID)
            .first()
        {
            node = existing
        } else {
            node = KeepTalkingNode(id: nodeID)
        }
        node.lastSeenAt = Date()
        node.discoveredDuringLogon = logon
        try await node.save(on: localStore.database)
    }

    func isTrustedOrOwned(nodeID: UUID) async throws -> Bool {
        try await KeepTalkingNodeRelation.query(on: localStore.database)
            .filter(\.$from.$id, .equal, config.node)
            .filter(\.$to.$id, .equal, nodeID)
            .filter(\.$relationship ~~ [.owner, .trusted])
            .count() > 0
    }

    private func defaultDescriptor(
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
}
