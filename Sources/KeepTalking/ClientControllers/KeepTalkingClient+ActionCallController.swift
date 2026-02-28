import FluentKit
import Foundation

extension KeepTalkingClient {
    func executeActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?
    ) async -> KeepTalkingActionCallResult {
        do {
            let action = try await resolveLocalActionForExecution(
                actionID: request.call.action
            )
            let remoteNode = try await ensure(
                request.callerNodeID,
                for: KeepTalkingNode.self
            )

            guard
                try await isNodeAuthorizedForAction(
                    node: remoteNode,
                    action: action,
                    context: context
                )
            else {
                throw KeepTalkingClientError.actionCallNotAuthorized(
                    action: request.call.action,
                    caller: request.callerNodeID,
                    context: request.contextID
                )
            }

            let callResult = try await mcpManager.callAction(
                action: action,
                call: request.call
            )

            return KeepTalkingActionCallResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                actionID: request.call.action,
                content: callResult.content,
                isError: callResult.isError ?? false,
                errorMessage: nil
            )
        } catch {
            return KeepTalkingActionCallResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                actionID: request.call.action,
                content: [],
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    func handleIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) async throws {
        let context = try await ensure(
            request.contextID,
            for: KeepTalkingContext.self
        )

        let result = await executeActionCallRequest(
            request,
            context: context
        )

        let encryptedResult = try await encryptActionCallResultEnvelope(result)

        try rtcClient.sendEnvelope(.encryptedActionCallResult(encryptedResult))
    }

    func dispatchActionCall(
        actionOwner: UUID,
        call: KeepTalkingActionCall,
        context: KeepTalkingContext
    ) async throws -> KeepTalkingActionCallResult {
        let request = KeepTalkingActionCallRequest(
            contextID: try context.requireID(),
            callerNodeID: config.node,
            targetNodeID: actionOwner,
            call: call
        )

        if actionOwner == config.node {
            return await executeActionCallRequest(request, context: context)
        }

        let encryptedRequest = try await encryptActionCallRequestEnvelope(
            request
        )
        try rtcClient.sendEnvelope(
            .encryptedActionCallRequest(encryptedRequest)
        )

        return try await waitForActionCallResult(
            requestID: request.id,
            timeoutSeconds: 15
        )
    }

    func waitForActionCallResult(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingActionCallResult {
        try await withThrowingTaskGroup(of: KeepTalkingActionCallResult.self) {
            group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.actionCallTimeout(requestID)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingActionCallResult, Error
                        >
                    ) in
                    self.actionCallQueue.sync {
                        self.pendingActionCallResults[requestID] = continuation
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingActionCall(
                    requestID: requestID,
                    error: KeepTalkingClientError.actionCallTimeout(requestID)
                )
                throw KeepTalkingClientError.actionCallTimeout(requestID)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.actionCallTimeout(requestID)
            }
            return first
        }
    }

    func resolvePendingActionCall(_ result: KeepTalkingActionCallResult)
        -> Bool
    {
        actionCallQueue.sync {
            guard
                let continuation = pendingActionCallResults.removeValue(
                    forKey: result.requestID
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingActionCall(requestID: UUID, error: Error) {
        actionCallQueue.sync {
            guard
                let continuation = pendingActionCallResults.removeValue(
                    forKey: requestID
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func failAllPendingActionCalls(error: Error) {
        actionCallQueue.sync {
            let pending = pendingActionCallResults
            pendingActionCallResults.removeAll()
            for continuation in pending.values {
                continuation.resume(throwing: error)
            }
        }
    }

    func resolveLocalActionForExecution(actionID: UUID) async throws
        -> KeepTalkingAction
    {
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
        return action
    }

    public func isNodeAuthorizedForAction(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        guard let actionOwnerID = action.$node.id else {
            return false
        }

        guard actionOwnerID == config.node || actionOwnerID == nodeID else {
            return false
        }

        if nodeID == config.node {
            return actionOwnerID == config.node
        }

        guard action.remoteAuthorisable ?? false else {
            return false
        }

        let selfNode = try await getCurrentNodeInstance()

        let eligibleRelations = try await selfNode.$outgoingNodeRelations
            .query(
                on: localStore.database
            ).filter(\.$to.$id == nodeID).all()
            .filter { relation in
                relation.allows(context: context)
            }

        guard !eligibleRelations.isEmpty else {
            return false
        }

        if eligibleRelations.contains(where: { relation in
            if case .owner = relation.relationship {
                return true
            }
            return false
        }) {
            return true
        }

        let eligibleRelationIDs = eligibleRelations.compactMap(\.id)
        guard !eligibleRelationIDs.isEmpty else {
            return false
        }

        let actionID = try action.requireID()
        let approvals =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: localStore.database)
            .filter(\.$relation.$id ~~ eligibleRelationIDs)
            .filter(\.$action.$id == actionID)
            .all()

        return approvals.contains { approval in
            approvingContextAllows(
                approval.approvingContext,
                context: context
            )
        }
    }

    func authorizedActions(
        _ actions: [KeepTalkingAction],
        for node: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async throws -> [KeepTalkingAction] {
        var allowed: [KeepTalkingAction] = []
        allowed.reserveCapacity(actions.count)

        for action in actions {
            guard
                try await isNodeAuthorizedForAction(
                    node: node,
                    action: action,
                    context: context
                )
            else {
                continue
            }
            allowed.append(action)
        }

        return allowed
    }

    func approvingContextAllows(
        _ approvingContext: KeepTalkingNodeRelationActionRelation
            .ApprovingContext?,
        context testContext: KeepTalkingContext?
    ) -> Bool {
        switch approvingContext {
            case .none, .all:
                return true
            case .contexts(let contexts):
                guard let testContext else {
                    return false
                }
                return contexts.contains(testContext)
        }
    }

}
