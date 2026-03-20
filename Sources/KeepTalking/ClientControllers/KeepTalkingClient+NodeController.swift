import CryptoKit
import FluentKit
import Foundation

public enum KeepTalkingActionPermissionScope: Sendable {
    case all
    case context(KeepTalkingContext)
}

public enum KeepTalkingNodeTrustScope: Sendable {
    case allContexts
    case context(KeepTalkingContext)
}

public struct KeepTalkingActionGrantSummary: Sendable {
    public let toNodeID: UUID
    public let approvingContext: KeepTalkingNodeRelationActionRelation.ApprovingContext?
}

public struct KeepTalkingActionSummary: Sendable {
    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let isMCP: Bool
    public let isSkill: Bool
    public let isPrimitive: Bool
    public let name: String
    public let description: String
    public let hostedLocally: Bool
    public let remoteAuthorisable: Bool
    public let grants: [KeepTalkingActionGrantSummary]
}

extension KeepTalkingClient {
    private static let nodeBroadcastDebounceNanoseconds: UInt64 =
        1_000_000_000

    /// Publishes the current node identifier to the configured KV service.
    public func registerCurrentNodeID() async throws {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }

        try await kvService.storeNodeID(config.node)
    }

    /// Loads known node identifiers from the configured KV service.
    public func fetchNodeIDs(for userID: String? = nil) async throws -> [UUID] {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }

        return try await kvService.loadNodeIDs()
    }

    /// Marks a remote node as trusted or owned and returns the local public key for that relation.
    ///
    /// - Parameters:
    ///   - targetNodeID: Remote node to update.
    ///   - scope: Trust scope to grant.
    ///   - own: Whether the relationship should become ownership.
    /// - Returns: The public key shared with the remote node.
    @discardableResult
    public func trust(
        node targetNodeID: UUID,
        scope: KeepTalkingNodeTrustScope = .allContexts,
        own: Bool = false
    ) async throws -> String {
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

        let relation: KeepTalkingNodeRelation

        if let existingRelation =
            try await KeepTalkingNodeRelation
            .query(on: localStore.database)
            .filter(\.$from.$id, .equal, localNodeID)
            .filter(\.$to.$id, .equal, targetNodeID)
            .first()
        {
            existingRelation.relationship =
                own
                ? .owner
                : mergedTrustRelationship(
                    current: existingRelation.relationship,
                    requestedScope: scope
                )
            try await existingRelation.save(on: localStore.database)

            relation = existingRelation
        } else {
            let newRelationship: KeepTalkingRelationship
            if own {
                newRelationship = .owner
            } else {
                switch scope {
                    case .allContexts:
                        newRelationship = .trustedInAllContext
                    case .context(let context):
                        newRelationship = .trusted([context])
                }
            }

            relation = try KeepTalkingNodeRelation(
                from: localNode,
                to: remoteNode,
                relationship: newRelationship
            )

            try await relation.save(on: localStore.database)
        }

        return try await ensureOutgoingIdentityKeypair(for: relation).publicKey
    }

    /// Records a remote node's public key so it can complete a pending trust handshake.
    public func lure(node sourceNodeID: UUID, publicKey: String) async throws {
        let trimmedPublicKey = publicKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedPublicKey.isEmpty else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }
        guard
            let publicKeyData = Data(base64Encoded: trimmedPublicKey),
            (try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: publicKeyData
            )) != nil
        else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }
        guard sourceNodeID != config.node else {
            return
        }

        let localNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        let localNodeID = try localNode.requireID()

        let remoteNode: KeepTalkingNode
        if let existing = try await KeepTalkingNode.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, sourceNodeID)
        .first() {
            remoteNode = existing
        } else {
            remoteNode = KeepTalkingNode(id: sourceNodeID)
            try await remoteNode.save(on: localStore.database)
        }

        let relation: KeepTalkingNodeRelation
        if let existingRelation = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, sourceNodeID)
        .filter(\.$to.$id, .equal, localNodeID)
        .first() {
            relation = existingRelation
        } else {
            relation = try KeepTalkingNodeRelation(
                from: remoteNode,
                to: localNode,
                relationship: .pending
            )
            try await relation.save(on: localStore.database)
        }

        guard relation.id != nil else {
            return
        }

        let existingKeys = try await relation.$identityKeys.get(
            on: localStore.database
        )

        if existingKeys.contains(where: {
            guard let privateKey = $0.privateKey else { return true }
            return privateKey.isEmpty
        }) {
            return
        }

        let identityKey = try KeepTalkingNodeIdentityKey(
            relation: relation,
            publicKey: trimmedPublicKey,
            privateKey: Data()
        )
        try await identityKey.save(on: localStore.database)
    }

    func currentNodeStatus(
        context: KeepTalkingContext? = nil,
        recipientNodeID: UUID? = nil,
        includeActionPayloads: Bool = true
    ) async throws
        -> KeepTalkingNodeStatus
    {
        let node = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        let currentContext = try await ensure(
            config.contextID,
            for: KeepTalkingContext.self
        )

        let localActions = try await KeepTalkingAction.query(
            on: localStore.database
        )
        .filter(\.$node.$id, .equal, config.node)
        .all()
        let sortedLocalActions = deduplicatedAndSortedActions(localActions)

        let relations =
            (try await KeepTalkingNodeRelation.query(
                on: localStore.database
            )
            .filter(\.$from.$id, .equal, config.node)
            .all())
            .filter { $0.relationship.allows(context: context) }

        var relationStatuses: [KeepTalkingNodeRelationStatus] = []
        relationStatuses.reserveCapacity(relations.count)

        for relation in relations {
            let relatedNodeID = relation.$to.id
            if relatedNodeID == config.node {
                continue
            }
            if let recipientNodeID, relatedNodeID != recipientNodeID {
                continue
            }
            if case .pending = relation.relationship {
                continue
            }

            let relationActions = deduplicatedAndSortedActions(
                try await authorizedActions(
                    sortedLocalActions,
                    for: KeepTalkingNode(id: relatedNodeID),
                    context: currentContext
                )
            )

            let outgoingActions: [KeepTalkingAction]
            if includeActionPayloads {
                outgoingActions = relationActions
            } else {
                outgoingActions = relationActions.map {
                    redactedBroadcastAction(from: $0)
                }
            }

            let wakeHandlesByActionID: [UUID: [KeepTalkingPushWakeHandle]]
            if let relationID = relation.id {
                let relationActionLinks =
                    try await KeepTalkingNodeRelationActionRelation
                    .query(on: localStore.database)
                    .filter(\.$relation.$id, .equal, relationID)
                    .all()
                wakeHandlesByActionID = Dictionary(
                    uniqueKeysWithValues: relationActionLinks.compactMap {
                        link in
                        guard
                            let wakeHandles = link.wakeHandles,
                            !wakeHandles.isEmpty
                        else {
                            return nil
                        }
                        return (link.$action.id, wakeHandles)
                    }
                )
            } else {
                wakeHandlesByActionID = [:]
            }
            let actionWakeRoutes: [KeepTalkingActionWakeRoute] =
                outgoingActions.compactMap { action in
                guard
                    let actionID = action.id,
                    let wakeHandles = wakeHandlesByActionID[actionID]
                else {
                    return nil
                }
                return KeepTalkingActionWakeRoute(
                    actionID: actionID,
                    wakeHandles: wakeHandles
                )
            }

            relationStatuses.append(
                KeepTalkingNodeRelationStatus(
                    toNodeID: relatedNodeID,
                    relationship: relation.relationship,
                    actions: outgoingActions,
                    actionWakeRoutes: actionWakeRoutes
                )
            )
        }

        return KeepTalkingNodeStatus(
            node: node,
            context: currentContext,
            nodeRelations: relationStatuses.sorted {
                $0.toNodeID.uuidString < $1.toNodeID.uuidString
            }
        )
    }

    /// Broadcasts the current node record to connected peers.
    public func announceCurrentNode() async throws {
        let node = try await getCurrentNodeInstance()
        try blocking {
            try await node.save(on: self.localStore.database)
        }
        try rtcClient.sendEnvelope(.node(node))
    }

    // TODO: Add online filter
    /// Broadcasts a redacted node-status snapshot to the selected peers.
    public func broadcastCurrentNodeStatus(
        in context: KeepTalkingContext,
        to nodes: [KeepTalkingNode]? = nil,
        onlineOnly: Bool = false
    )
        async throws
    {
        let statusesByRecipient = try await qualifiedNodeStatuses(
            in: context,
            from: nodes,
            includeActionPayloads: false
        )

        let sortedRecipientNodeIDs = statusesByRecipient.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        for recipientNodeID in sortedRecipientNodeIDs {
            guard let status = statusesByRecipient[recipientNodeID] else {
                continue
            }
            do {
                rtcClient.debug(
                    "[broadcastCurrentNodeStatus] recipient=\(recipientNodeID.uuidString.lowercased()) "
                        + String(
                            decoding: try! JSONEncoder().encode(status),
                            as: UTF8.self
                        )
                )
                if let keyInfo = try await asymmetricPublicKeysForRecipient(
                    nodeID: recipientNodeID
                ) {
                    rtcClient.debug(
                        "[broadcastCurrentNodeStatus.keys] recipient=\(recipientNodeID.uuidString.lowercased()) localPublicKey=\(keyInfo.localPublicKey) remotePublicKey=\(keyInfo.remotePublicKey) relation=\(keyInfo.relationID.uuidString.lowercased())"
                    )
                }
                let encryptedEnvelope = try await encryptNodeStatusEnvelope(
                    status,
                    recipientNodeID: recipientNodeID
                )
                try rtcClient.sendEnvelope(
                    .encryptedNodeStatus(encryptedEnvelope)
                )
            } catch {
                rtcClient.debug(
                    "encrypted node status send failed node=\(recipientNodeID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    func handlePeerConnect(nodeID: UUID) async {
        guard nodeID != config.node else { return }
        onPeerConnect?(nodeID)
        let nodeIDText = nodeID.uuidString.lowercased()
        rtcClient.debug("peer connected node=\(nodeIDText)")
        await broadcastLocalNodeState(
            reason: "peer-connect node=\(nodeIDText)"
        )
        await syncCurrentContext(with: nodeID)
    }

    func mergeDiscoveredNodeStatus(_ status: KeepTalkingNodeStatus) async throws {
        rtcClient.debug(
            "[mergeDiscoveredNodeStatus] "
                + String(
                    decoding: try! JSONEncoder().encode(status),
                    as: UTF8.self
                )
        )
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
        guard let remoteNodeID = status.node.id, remoteNodeID != config.node
        else {
            return
        }

        let grantsForLocal = status.nodeRelations.filter {
            $0.toNodeID == config.node
                && $0.relationship.isTrustedOrOwner
                && $0.relationship.allows(context: status.context)
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

        let relationCandidates = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$to.$id, .equal, remoteNodeID)
        .all()
        let relation: KeepTalkingNodeRelation
        if let preferred = relationCandidates.sorted(by: {
            relationPriority($0.relationship)
                > relationPriority($1.relationship)
        }).first {
            relation = preferred
        } else {
            let created = try KeepTalkingNodeRelation(
                from: localNode,
                to: remoteNode,
                relationship: .pending
            )
            try await created.save(on: localStore.database)
            relation = created
        }

        let requestedTrustScope: KeepTalkingNodeTrustScope =
            grantsForLocal.contains {
                switch $0.relationship {
                    case .owner, .trustedInAllContext:
                        return true
                    case .trusted(_), .pending:
                        return false
                }
            } ? .allContexts : .context(status.context)

        let mergedRelationship = mergedTrustRelationship(
            current: relation.relationship,
            requestedScope: requestedTrustScope
        )
        if mergedRelationship != relation.relationship {
            relation.relationship = mergedRelationship
            try await relation.save(on: localStore.database)
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
        let wakeRoutesByActionID: [UUID: [KeepTalkingPushWakeHandle]] = Dictionary(
            uniqueKeysWithValues: grantsForLocal.flatMap { relationStatus in
                relationStatus.actionWakeRoutes.map { route in
                    (route.actionID, route.wakeHandles)
                }
            }
        )
        if grantedActionIDs.isEmpty {
            return
        }

        let approvingContext =
            KeepTalkingNodeRelationActionRelation.ApprovingContext.contexts(
                [
                    status.context
                ]
            )

        guard let relationID = relation.id else { return }
        for actionID in grantedActionIDs {
            guard advertisedByID[actionID] != nil else {
                continue
            }
            guard
                let action = try await KeepTalkingAction.query(
                    on: localStore.database
                )
                .filter(\.$id, .equal, actionID)
                .first()
            else {
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
                existingLink.wakeHandles = wakeRoutesByActionID[actionID]
                try await existingLink.save(on: localStore.database)
            } else {
                let link = try KeepTalkingNodeRelationActionRelation(
                    relation: relation,
                    action: action,
                    approvingContext: approvingContext
                )
                link.wakeHandles = wakeRoutesByActionID[actionID]
                try await link.save(on: localStore.database)
            }
        }
    }

    private func relationPriority(_ relationship: KeepTalkingRelationship)
        -> Int
    {
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

    func encryptNodeStatusEnvelope(
        _ status: KeepTalkingNodeStatus,
        recipientNodeID: UUID
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(status)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: recipientNodeID,
            purpose: "node-status"
        )
    }

    func decryptNodeStatusEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingNodeStatus {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "node-status"
        )
        let status = try JSONDecoder().decode(
            KeepTalkingNodeStatus.self,
            from: payload
        )
        guard status.node.id == envelope.senderNodeID else {
            throw KeepTalkingClientError.malformedEncryptedNodeStatus
        }
        return status
    }

    private func qualifiedNodeStatuses(
        in context: KeepTalkingContext,
        from nodes: [KeepTalkingNode]?,
        includeActionPayloads: Bool
    ) async throws -> [UUID: KeepTalkingNodeStatus] {
        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        var outgoingRelations = try await selfNode.$outgoingNodeRelations.get(
            on: localStore.database
        )
        outgoingRelations = outgoingRelations.filter { outgoingRelation in
            outgoingRelation.allows(context: context)
        }

        let scopedNodeIDs = Set((nodes ?? []).compactMap(\.id))
        if !scopedNodeIDs.isEmpty {
            outgoingRelations = outgoingRelations.filter { outgoingRelation in
                scopedNodeIDs.contains(outgoingRelation.$to.id)
            }
        }

        let recipientNodeIDs = Set(outgoingRelations.map(\.$to.id))
        var statusesByRecipient: [UUID: KeepTalkingNodeStatus] = [:]
        statusesByRecipient.reserveCapacity(recipientNodeIDs.count)

        for recipientNodeID in recipientNodeIDs {
            let status = try await currentNodeStatus(
                context: context,
                recipientNodeID: recipientNodeID,
                includeActionPayloads: includeActionPayloads
            )
            statusesByRecipient[recipientNodeID] = status
        }

        return statusesByRecipient
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

    func ensure<NodeType: Model>(
        _ id: NodeType.IDValue,
        for _: NodeType.Type,
        strict: Bool = false
    ) async throws -> NodeType {
        if let entity = try await NodeType.find(
            id,
            on: localStore.database
        ) {
            return entity
        }

        if strict {
            throw KeepTalkingClientError.missingNode
        }

        let entity = NodeType()
        entity.id = id

        try await entity.save(on: localStore.database)

        return entity
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

        try await node.save(on: localStore.database)
        _ = try await ensureLocalIdentityRelation()
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
            existing.contextWakeHandles = incoming.contextWakeHandles
            try await existing.save(on: localStore.database)
            return
        }

        let node = KeepTalkingNode(
            id: incomingNodeID,
            lastSeenAt: incoming.lastSeenAt
        )
        node.contextWakeHandles = incoming.contextWakeHandles

        try await node.save(on: localStore.database)
    }

    func markNodeDiscovered(_ nodeID: UUID) async throws {
        guard nodeID != config.node else {
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

        try await node.save(on: localStore.database)
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

    private func redactedBroadcastAction(from action: KeepTalkingAction)
        -> KeepTalkingAction
    {
        let redacted = KeepTalkingAction()
        redacted.id = action.id
        redacted.$node.id = action.$node.id
        redacted.descriptor = action.descriptor
        redacted.payload = redactedBroadcastPayload(
            action.payload,
            actionID: action.id
        )
        redacted.remoteAuthorisable = action.remoteAuthorisable
        redacted.blockingAuthorisation = action.blockingAuthorisation
        redacted.createdAt = action.createdAt
        redacted.lastUsed = action.lastUsed

        return redacted
    }

    private func redactedBroadcastPayload(
        _ payload: KeepTalkingAction.Payload?,
        actionID: UUID?
    ) -> KeepTalkingAction.Payload? {
        guard let payload else {
            return nil
        }

        switch payload {
            case .mcpBundle(let bundle):
                let token = actionID?.uuidString.lowercased() ?? "unknown"
                return .mcpBundle(
                    KeepTalkingMCPBundle(
                        id: bundle.id,
                        name: bundle.name,
                        indexDescription: bundle.indexDescription,
                        service: .stdio(
                            arguments: [
                                "__kt_redacted_mcp_action__",
                                token,
                            ],
                            environment: [:]
                        )
                    )
                )
            case .primitive(let bundle):
                return .primitive(bundle)
            case .skill(let bundle):
                let token = actionID?.uuidString.lowercased() ?? "unknown"
                return .skill(
                    KeepTalkingSkillBundle(
                        id: bundle.id,
                        name: bundle.name,
                        indexDescription: bundle.indexDescription,
                        directory: URL(
                            fileURLWithPath:
                                "/__kt_remote_skill__/\(token)"
                        )
                    )
                )
        }
    }

    func broadcastLocalNodeState(reason: String) async {
        do {
            let currentContext = try await ensure(
                config.contextID,
                for: KeepTalkingContext.self,
                strict: true
            )

            try await announceCurrentNode()
            try await broadcastCurrentNodeStatus(in: currentContext)
            rtcClient.debug("node state broadcast complete reason=\(reason)")
        } catch {
            rtcClient.debug(
                "node state broadcast failed reason=\(reason) error=\(error.localizedDescription)"
            )
        }
    }

    func scheduleDebouncedNodeStateBroadcast(reason: String) {
        cancelDebouncedNodeStateBroadcast()
        nodeStateBroadcastDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nodeBroadcastDebounceNanoseconds
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.broadcastLocalNodeState(reason: "debounced \(reason)")
        }
    }

    func cancelDebouncedNodeStateBroadcast() {
        nodeStateBroadcastDebounceTask?.cancel()
        nodeStateBroadcastDebounceTask = nil
    }

    private func mergedTrustRelationship(
        current: KeepTalkingRelationship,
        requestedScope: KeepTalkingNodeTrustScope
    ) -> KeepTalkingRelationship {
        switch requestedScope {
            case .allContexts:
                switch current {
                    case .owner:
                        return .owner
                    case .trustedInAllContext, .trusted, .pending:
                        return .trustedInAllContext
                }
            case .context(let context):
                switch current {
                    case .owner, .trustedInAllContext:
                        return current
                    case .trusted(let existingContexts):
                        var merged = Set(existingContexts)
                        merged.insert(context)

                        let mergedArray = Array(merged)

                        return .trusted(mergedArray)
                    case .pending:
                        return .trusted([context])
                }
        }
    }

    func ensureLocalNodeSigningKeypair(
        to node: KeepTalkingNode
    ) async throws
        -> KeepTalkingNodeIdentityKey
    {
        guard let toNodeID = node.id else {
            throw KeepTalkingClientError.missingNode
        }

        guard
            let relation = try await getCurrentNodeInstance().$outgoingNodeRelations.query(
                on: localStore.database
            ).filter(\.$to.$id == toNodeID).first()
        else {
            throw KeepTalkingClientError.missingRelation
        }

        return try await ensureOutgoingIdentityKeypair(for: relation)
    }

    private func ensureLocalIdentityRelation() async throws
        -> KeepTalkingNodeRelation
    {
        let localNode = try await getCurrentNodeInstance()

        if let existing = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$to.$id, .equal, config.node)
        .first() {
            if existing.relationship != .owner {
                existing.relationship = .owner
                try await existing.save(on: localStore.database)
            }
            return existing
        }

        let relation = try KeepTalkingNodeRelation(
            from: localNode,
            to: localNode,
            relationship: .owner
        )

        try await relation.save(on: localStore.database)
        return relation
    }

    private func ensureOutgoingIdentityKeypair(for relation: KeepTalkingNodeRelation) async throws
        -> KeepTalkingNodeIdentityKey
    {
        guard let relationID = relation.id else {
            throw KeepTalkingClientError.missingRelation
        }

        if let existingKeypair = try await KeepTalkingNodeIdentityKey.query(
            on: localStore.database
        )
        .filter(\.$relation.$id, .equal, relationID)
        .sort(\.$createdAt, .descending)
        .first() {
            return existingKeypair
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = Data(privateKey.publicKey.rawRepresentation)
            .base64EncodedString()
        let keypair = try KeepTalkingNodeIdentityKey(
            relation: relation,
            publicKey: publicKey,
            privateKey: Data(privateKey.rawRepresentation)
        )

        try await keypair.save(on: localStore.database)
        return keypair
    }
}
