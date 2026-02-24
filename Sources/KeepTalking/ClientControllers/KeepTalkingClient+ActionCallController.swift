import FluentKit
import Foundation

extension KeepTalkingClient {
    func handleIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) async throws {
        let result: KeepTalkingActionCallResult
        do {
            let action = try await resolveLocalActionForExecution(
                actionID: request.call.action
            )

            let allowed = try await isCallerAuthorizedForAction(
                callerNodeID: request.callerNodeID,
                actionID: request.call.action,
                contextID: request.contextID
            )
            guard allowed else {
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
            result = KeepTalkingActionCallResult(
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
            result = KeepTalkingActionCallResult(
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

        try rtcClient.sendEnvelope(.actionCallResult(result))
    }

    func dispatchActionCall(
        actionOwner: UUID,
        call: KeepTalkingActionCall,
        contextID: UUID
    ) async throws -> KeepTalkingActionCallResult {
        if actionOwner == config.node {
            let action = try await resolveLocalActionForExecution(actionID: call.action)
            let localResult = try await mcpManager.callAction(action: action, call: call)
            return KeepTalkingActionCallResult(
                requestID: UUID(),
                contextID: contextID,
                callerNodeID: config.node,
                targetNodeID: config.node,
                actionID: call.action,
                content: localResult.content,
                isError: localResult.isError ?? false,
                errorMessage: nil
            )
        }

        let request = KeepTalkingActionCallRequest(
            contextID: contextID,
            callerNodeID: config.node,
            targetNodeID: actionOwner,
            call: call
        )
        try rtcClient.sendEnvelope(.actionCallRequest(request))

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
                    (continuation: CheckedContinuation<KeepTalkingActionCallResult, Error>) in
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
            guard let continuation = pendingActionCallResults.removeValue(
                forKey: result.requestID
            ) else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingActionCall(requestID: UUID, error: Error) {
        actionCallQueue.sync {
            guard let continuation = pendingActionCallResults.removeValue(
                forKey: requestID
            ) else {
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
            let action = try await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .filter(\.$node.$id, .equal, config.node)
                .first()
        else {
            throw KeepTalkingClientError.actionNotHostedLocally(actionID)
        }
        return action
    }

    func isCallerAuthorizedForAction(
        callerNodeID: UUID,
        actionID: UUID,
        contextID: UUID
    ) async throws -> Bool {
        guard callerNodeID != config.node else {
            return true
        }

        let relations = try await KeepTalkingNodeRelation.query(on: localStore.database)
            .filter(\.$from.$id, .equal, config.node)
            .filter(\.$to.$id, .equal, callerNodeID)
            .filter(\.$relationship ~~ [.owner, .trusted])
            .all()

        guard !relations.isEmpty else {
            return false
        }

        for relation in relations {
            guard let relationID = relation.id else { continue }
            let links = try await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$relation.$id, .equal, relationID)
                .filter(\.$action.$id, .equal, actionID)
                .all()

            if links.contains(where: { approvingContextAllows($0.approvingContext, contextID: contextID) }) {
                return true
            }
        }

        return false
    }

    func approvingContextAllows(
        _ approvingContext: KeepTalkingNodeRelationActionRelation.ApprovingContext?,
        contextID: UUID
    ) -> Bool {
        switch approvingContext {
        case .none, .all:
            return true
        case .context(let context):
            return context.id == contextID
        }
    }
}
