import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    private static let actionCallResultTimeoutSeconds: TimeInterval = 45

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

            if action.blockingAuthorisation == true,
                let context,
                let actionApprovalHandler
            {
                let approved = await actionApprovalHandler(
                    request,
                    action,
                    context
                )
                guard approved else {
                    throw KeepTalkingClientError.actionCallNotAuthorized(
                        action: request.call.action,
                        caller: request.callerNodeID,
                        context: request.contextID
                    )
                }
            }

            let callResult: (content: [Tool.Content], isError: Bool?)
            switch action.payload {
                case .mcpBundle:
                    callResult = try await mcpManager.callAction(
                        action: action,
                        call: request.call
                    )
                case .skill:
                    callResult = try await skillManager.callAction(
                        action: action,
                        call: request.call
                    )
                case .primitive:
                    callResult = try await primitiveActionManager.callAction(
                        action: action,
                        call: request.call
                    )
                default:
                    throw KeepTalkingClientError.unsupportedActionPayload
            }

            let actionID = request.call.action.uuidString.lowercased()
            let source = {
                switch action.payload {
                    case .mcpBundle:
                        return "mcp"
                    case .skill:
                        return "skill"
                    case .primitive:
                        return "primitive"
                    default:
                        return "unknown"
                }
            }()
            let rendered = callResult.content.map {
                renderToolContentForDebug($0)
            }.joined(separator: " | ")
            let loggedContent =
                source == "skill"
                ? "<skill-result-redacted>"
                : truncatedActionCallDebug(rendered)
            onLog?(
                "[action-call/result] action=\(actionID) source=\(source) is_error=\(callResult.isError ?? false) content=\(loggedContent)"
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
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()
        onLog?(
            "[action-call/request] handling request=\(requestID) action=\(actionID) caller=\(request.callerNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
        )
        let context = try await upsertContext(
            KeepTalkingContext(id: request.contextID)
        )

        let result = await executeActionCallRequest(
            request,
            context: context
        )
        onLog?(
            "[action-call/result] returning request=\(requestID) action=\(actionID) is_error=\(result.isError)"
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
        let requestID = request.id.uuidString.lowercased()
        let actionID = call.action.uuidString.lowercased()

        if actionOwner == config.node {
            onLog?(
                "[action-call/request] executing locally request=\(requestID) action=\(actionID)"
            )
            return await executeActionCallRequest(request, context: context)
        }

        onLog?(
            "[action-call/request] dispatching remote request=\(requestID) action=\(actionID) target=\(actionOwner.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
        )
        if await shouldUseWakeAssistedDelivery(for: call.action) {
            onLog?(
                "[action-call/request] wake-assisted delivery request=\(requestID) action=\(actionID) target=\(actionOwner.uuidString.lowercased())"
            )
            await sendActionWakeIfNeeded(
                actionOwner: actionOwner,
                call: call,
                context: context
            )
            await waitForNodeToComeOnline(actionOwner)
        }

        let encryptedRequest = try await encryptActionCallRequestEnvelope(
            request
        )
        try rtcClient.sendEnvelope(
            .encryptedActionCallRequest(encryptedRequest)
        )

        return try await waitForActionCallResult(
            requestID: request.id,
            timeoutSeconds: Self.actionCallResultTimeoutSeconds
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
                self?.onLog?(
                    "[action-call/request] timed out request=\(requestID.uuidString.lowercased()) after=\(Int(timeoutSeconds))s"
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

    private func shouldUseWakeAssistedDelivery(for actionID: UUID) async -> Bool {
        guard
            let action = try? await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, actionID)
                .first()
        else {
            return false
        }
        return action.blockingAuthorisation == true
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

    public static func isNodeAuthorizedForAction(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> Bool {
        let actionID = try action.requireID()
        let approvals =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: database)
            .filter(\.$action.$id == actionID)
            .all()

        return approvals.contains { approval in
            approval.applicable(in: context)
        }
    }

    public func isNodeAuthorizedForAction(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        try await Self.isNodeAuthorizedForAction(
            node: node,
            action: action,
            context: context,
            on: localStore.database
        )
    }

    public func isNodeAuthorizedToAuthorizeAction(
        node: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        if nodeID == config.node {
            return true
        }

        let selfNode = try await getCurrentNodeInstance()
        let relations = try await selfNode.$outgoingNodeRelations
            .query(on: localStore.database)
            .filter(\.$to.$id == nodeID)
            .all()

        return relations.contains { relation in
            relation.allows(context: context)
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

    private func renderToolContentForDebug(_ content: Tool.Content) -> String {
        switch content {
            case .text(let text):
                return text
            default:
                if let data = try? JSONEncoder().encode(content),
                    let json = String(data: data, encoding: .utf8)
                {
                    return json
                }
                return "<non-text content>"
        }
    }

    private func truncatedActionCallDebug(_ payload: String) -> String {
        let maxCharacters = 2_000
        guard payload.count > maxCharacters else {
            return payload
        }
        return String(payload.prefix(maxCharacters)) + "...[truncated]"
    }

}
