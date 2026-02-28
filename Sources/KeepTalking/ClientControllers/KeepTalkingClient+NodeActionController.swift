//
//  KeepTalkingClient+NodeActionController.swift
//  KeepTalking
//
//  Created by 砚渤 on 25/02/2026.
//

import FluentKit
import Foundation

extension KeepTalkingClient {

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
            let action = try await KeepTalkingAction.query(
                on: localStore.database
            )
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
            let action = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .filter(\.$node.$id, .equal, config.node)
            .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        let relations =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$action.$id, .equal, actionID)
            .all()
        for relation in relations {
            try await relation.delete(on: localStore.database)
        }

        try await action.delete(on: localStore.database)
        await mcpManager.unregisterAction(actionID: actionID)
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
                        approvingContext: link.approvingContext
                    )
                }

            let isMCP: Bool
            let name: String
            let description: String
            if case .mcpBundle(let bundle) = action.payload {
                isMCP = true
                name = bundle.name
                description =
                    action.descriptor?.action?.description
                    ?? bundle.indexDescription
            } else {
                isMCP = false
                name = "unknown"
                description = action.descriptor?.action?.description ?? ""
            }

            summaries.append(
                KeepTalkingActionSummary(
                    actionID: actionID,
                    ownerNodeID: action.$node.id,
                    isMCP: isMCP,
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
            let action = try await KeepTalkingAction.find(
                actionID,
                on: localStore
                    .database
            ),
            action.$node.id == config.node
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }

        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        guard
            let relation = try await selfNode.$outgoingNodeRelations
                .query(on: localStore.database)
                .filter(\.$to.$id == toNodeID)
                .first()
        else {
            // TODO: The error is inaccurate
            throw KeepTalkingClientError.relationNotTrustedOrOwned(toNodeID)
        }

        var targetActionRelation = try await relation.$actionRelations.query(
            on: localStore
                .database
        ).filter(\.$action.$id == actionID).first()

        if targetActionRelation == nil {
            switch scope {
                case .all:
                    targetActionRelation = try .init(
                        relation: relation,
                        action: action,
                        approvingContext: .all
                    )
                case .context(let approvingContext):
                    targetActionRelation = try .init(
                        relation: relation,
                        action: action,
                        approvingContext: .contexts([approvingContext])
                    )
            }

            try await targetActionRelation!.create(on: localStore.database)
        } else {
            switch scope {
                case .all:
                    targetActionRelation!.approvingContext = .all
                case .context(let approvingContext):
                    switch targetActionRelation!.approvingContext {
                        case .all:
                            targetActionRelation!.approvingContext = .all
                        case .contexts(let originalContexts):
                            targetActionRelation!.approvingContext = .contexts(
                                originalContexts + [approvingContext]
                            )
                        default:
                            break
                    }
            }

            try await targetActionRelation!.update(on: localStore.database)
        }

        await broadcastLocalNodeState(
            reason:
                "grant action=\(actionID.uuidString.lowercased()) to=\(toNodeID.uuidString.lowercased())"
        )
    }

    func mergeNodeActions(_ actions: [KeepTalkingAction]) async throws {
        let advertisedActions = deduplicatedAndSortedActions(
            actions
        )

        for incomingAction in advertisedActions {
            guard let actionID = incomingAction.id else {
                continue
            }

            rtcClient.onLog?("Merging action: \(actionID)")

            let persistedAction: KeepTalkingAction
            let existingDescriptor: KeepTalkingActionDescriptor?
            let existingPayload: KeepTalkingAction.Payload?
            let existingRemoteAuthorisable: Bool?
            let existingBlockingAuthorisation: Bool?

            if let existingAction = try await KeepTalkingAction.query(
                on: localStore.database
            )
            .filter(\.$id, .equal, actionID)
            .first() {
                persistedAction = existingAction
                existingDescriptor = existingAction.descriptor
                existingPayload = existingAction.payload
                existingRemoteAuthorisable = existingAction.remoteAuthorisable
                existingBlockingAuthorisation =
                    existingAction
                    .blockingAuthorisation
            } else {
                let newAction = KeepTalkingAction()
                newAction.id = actionID
                persistedAction = newAction
                existingDescriptor = nil
                existingPayload = nil
                existingRemoteAuthorisable = nil
                existingBlockingAuthorisation = nil
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
                incomingAction.payload
                ?? existingPayload
                ?? .mcpBundle(
                    virtualRemoteMCPBundle(
                        actionID: actionID,
                        description: fallbackDescription
                    )
                )

            persistedAction.$node.id = incomingAction.$node.id
            persistedAction.descriptor = resolvedDescriptor
            persistedAction.payload = resolvedPayload
            persistedAction.remoteAuthorisable =
                incomingAction.remoteAuthorisable
                ?? existingRemoteAuthorisable
                ?? true
            persistedAction.blockingAuthorisation =
                incomingAction.blockingAuthorisation
                ?? existingBlockingAuthorisation
                ?? false

            try await persistedAction.save(on: localStore.database)

            if persistedAction.$node.id == config.node,
                case .mcpBundle = persistedAction.payload
            {
                try await mcpManager.refreshMCPAction(persistedAction)
            }
        }
    }

    private func virtualRemoteMCPBundle(
        actionID: UUID,
        description: String
    ) -> KeepTalkingMCPBundle {
        let shortID = actionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        return KeepTalkingMCPBundle(
            id: actionID,
            name: "remote_\(shortID)",
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
}
