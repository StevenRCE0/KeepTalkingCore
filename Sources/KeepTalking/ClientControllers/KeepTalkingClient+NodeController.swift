import FluentKit
import Foundation

public enum KeepTalkingActionPermissionScope: Sendable {
    case all
    case context(KeepTalkingContext)
}

public struct KeepTalkingActionGrantSummary: Sendable {
    public let toNodeID: UUID
    public let approvingContext:
        KeepTalkingNodeRelationActionRelation.ApprovingContext?
}

public struct KeepTalkingActionSummary: Sendable {
    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let isMCP: Bool
    public let name: String
    public let description: String
    public let hostedLocally: Bool
    public let remoteAuthorisable: Bool
    public let grants: [KeepTalkingActionGrantSummary]
}

extension KeepTalkingClient {

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
        if let existing = try await KeepTalkingNode.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, targetNodeID)
        .first() {
            remoteNode = existing
        } else {
            remoteNode = KeepTalkingNode(id: targetNodeID)
            try await remoteNode.save(on: localStore.database)
        }

        if let relation =
            try await KeepTalkingNodeRelation
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

    func currentNodeStatus(contextID: UUID? = nil) async throws
        -> KeepTalkingNodeStatus
    {
        let node = try await getCurrentNodeInstance()
        let activeContextID = contextID ?? config.contextID

        let localActions = try await KeepTalkingAction.query(
            on: localStore.database
        )
        .filter(\.$node.$id, .equal, config.node)
        .all()
        let sortedLocalActions = deduplicatedAndSortedActions(localActions)

        let relations = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$relationship ~~ [.owner, .trusted])
        .all()

        var relationStatuses: [KeepTalkingNodeRelationStatus] = []
        relationStatuses.reserveCapacity(relations.count)

        for relation in relations {
            let relationActions: [KeepTalkingAction]
            switch relation.relationship {
            case .owner:
                relationActions = sortedLocalActions
            case .trusted:
                guard let relationID = relation.id else {
                    relationActions = []
                    break
                }
                let links =
                    try await KeepTalkingNodeRelationActionRelation
                    .query(on: localStore.database)
                    .filter(\.$relation.$id, .equal, relationID)
                    .with(\.$action)
                    .all()
                relationActions = deduplicatedAndSortedActions(
                    links.compactMap { link in
                        guard
                            approvingContextAllows(
                                link.approvingContext,
                                contextID: activeContextID
                            )
                        else {
                            return nil
                        }
                        return link.action
                    }
                )
            case .pending:
                continue
            }

            relationStatuses.append(
                KeepTalkingNodeRelationStatus(
                    toNodeID: relation.$to.id,
                    relationship: relation.relationship,
                    actions: relationActions
                )
            )
        }

        return KeepTalkingNodeStatus(
            node: node,
            contextID: activeContextID,
            nodeRelations: relationStatuses.sorted {
                $0.toNodeID.uuidString < $1.toNodeID.uuidString
            }
        )
    }

    public func announceCurrentNode() async throws {
        let node = try await getCurrentNodeInstance()
        try blocking {
            try await node.save(on: self.localStore.database)
        }
        try rtcClient.sendEnvelope(.node(node))
    }

    public func broadcastCurrentNodeStatus(in contextID: UUID? = nil)
        async throws
    {
        let status = try await currentNodeStatus(contextID: contextID)
        rtcClient.debug(
            "[broadcastCurrentNodeStatus] " + String(decoding: try! JSONEncoder().encode(status), as: UTF8.self)
        )
        try rtcClient.sendEnvelope(.nodeStatus(status))
    }

    func handlePeerConnect(nodeID: UUID) async {
        guard nodeID != config.node else { return }
        onPeerConnect?(nodeID)
        let nodeIDText = nodeID.uuidString.lowercased()
        rtcClient.debug("peer connected node=\(nodeIDText)")

        do {
            try await announceCurrentNode()
            try await broadcastCurrentNodeStatus()
            rtcClient.debug(
                "peer connect sync complete node=\(nodeIDText)"
            )
        } catch {
            rtcClient.debug(
                "peer connect sync failed node=\(nodeIDText) error=\(error.localizedDescription)"
            )
        }
    }

    func mergeDiscoveredNodeStatus(_ status: KeepTalkingNodeStatus) async throws
    {
        try await mergeDiscoveredNode(status.node)

        let advertisedActions = deduplicatedAndSortedActions(
            status.nodeRelations.flatMap(\.actions)
        )

        try await mergeNodeActions(advertisedActions)
        try await mergeIncomingActionAuthorisations(
            from: status,
            advertisedActions: advertisedActions
        )
    }

    private func mergeIncomingActionAuthorisations(
        from status: KeepTalkingNodeStatus,
        advertisedActions: [KeepTalkingAction]
    ) async throws {
        guard let remoteNodeID = status.node.id, remoteNodeID != config.node else {
            return
        }

        let grantsForLocal = status.nodeRelations.filter {
            $0.toNodeID == config.node
                && ($0.relationship == .owner || $0.relationship == .trusted)
        }
        guard !grantsForLocal.isEmpty else {
            return
        }

        let localNode = try await getCurrentNodeInstance()
        let remoteNode: KeepTalkingNode
        if let existingRemote = try await KeepTalkingNode.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, remoteNodeID)
        .first() {
            remoteNode = existingRemote
        } else {
            let created = KeepTalkingNode(id: remoteNodeID)
            try await created.save(on: localStore.database)
            remoteNode = created
        }

        let relation: KeepTalkingNodeRelation
        if let existingRelation = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$to.$id, .equal, remoteNodeID)
        .first() {
            relation = existingRelation
        } else {
            let created = try KeepTalkingNodeRelation(
                from: localNode,
                to: remoteNode,
                relationship: .pending
            )
            try await created.save(on: localStore.database)
            relation = created
        }

        let advertisedByID: [UUID: KeepTalkingAction] = Dictionary(
            uniqueKeysWithValues: advertisedActions.compactMap { action in
                guard let actionID = action.id else { return nil }
                return (actionID, action)
            }
        )
        let grantedActionIDs = Set(
            grantsForLocal.flatMap(\.actions).compactMap(\.id)
        )
        if grantedActionIDs.isEmpty {
            return
        }

        let approvingContext =
            KeepTalkingNodeRelationActionRelation.ApprovingContext.context(
                KeepTalkingContext(id: status.contextID)
            )

        guard let relationID = relation.id else { return }
        for actionID in grantedActionIDs {
            guard let action = advertisedByID[actionID] else {
                continue
            }

            if let existingLink =
                try await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$relation.$id, .equal, relationID)
                .filter(\.$action.$id, .equal, actionID)
                .first()
            {
                existingLink.approvingContext = approvingContext
                try await existingLink.save(on: localStore.database)
            } else {
                let link = try KeepTalkingNodeRelationActionRelation(
                    relation: relation,
                    action: action,
                    approvingContext: approvingContext
                )
                try await link.save(on: localStore.database)
            }
        }
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

        if let existing = try await KeepTalkingNode.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, incomingNodeID)
        .first() {
            existing.lastSeenAt = max(existing.lastSeenAt, incoming.lastSeenAt)
            existing.discoveredDuringLogon = logon
            try await existing.save(on: localStore.database)
            return
        }

        let node = KeepTalkingNode(
            id: incomingNodeID,
            lastSeenAt: incoming.lastSeenAt,
            discoveredDuringLogon: logon
        )
        try await node.save(on: localStore.database)
    }

    func markNodeDiscovered(_ nodeID: UUID) async throws {
        guard nodeID != config.node else {
            return
        }
        guard try await isTrustedOrOwned(nodeID: nodeID) else {
            return
        }

        let node: KeepTalkingNode
        if let existing = try await KeepTalkingNode.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, nodeID)
        .first() {
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

    func defaultDescriptor(
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
