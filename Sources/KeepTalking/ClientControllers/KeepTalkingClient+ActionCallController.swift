import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    private static let actionCallResultTimeoutSeconds: TimeInterval = 45
    private static let actionCallAckTimeoutSeconds: TimeInterval = 4
    private static let actionCallAckRetryLimit = 2
    private static let actionCallDeliveryCacheLimit = 32
    private static let completedIncomingActionCallCacheLimit = 32

    public func deliveryNodeID(forRemoteOwnerNodeID ownerNodeID: UUID) async throws
        -> UUID
    {
        if ownerNodeID == config.node {
            return ownerNodeID
        }
        return try await Self.deliveryNodeID(
            forRemoteOwnerNodeID: ownerNodeID,
            on: localStore.database
        )
    }

    public func deliveryNodeID(for action: KeepTalkingAction) async throws -> UUID? {
        guard let ownerNodeID = action.$node.id else {
            return nil
        }
        return try await deliveryNodeID(forRemoteOwnerNodeID: ownerNodeID)
    }

    public func isActionReachable(_ action: KeepTalkingAction) async -> Bool {
        guard let deliveryNodeID = try? await deliveryNodeID(for: action) else {
            return false
        }
        if deliveryNodeID == config.node {
            return true
        }
        return isNodeOnline(deliveryNodeID)
    }

    func enqueueIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) {
        guard request.targetNodeID == config.node else {
            return
        }
        Task { [weak self] in
            do {
                try await self?.handleIncomingActionCallRequest(request)
            } catch {
                self?.onLog?(
                    "[action-call/request] failed request=\(request.id.uuidString.lowercased()) action=\(request.call.action.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private static func deliveryNodeID(
        forRemoteOwnerNodeID ownerNodeID: UUID,
        on database: any Database,
        visited: Set<UUID> = []
    ) async throws -> UUID {
        return ownerNodeID
        // TODO: Very interesting walking logic, leave it for another day...Not hopping now.
        //        if visited.contains(ownerNodeID) {
        //            return ownerNodeID
        //        }
        //
        //        let ownerRelations = try await KeepTalkingNodeRelation.query(on: database)
        //            .filter(\.$to.$id, .equal, ownerNodeID)
        //            .all()
        //            .filter { $0.relationship == .owner }
        //            .sorted { lhs, rhs in
        //                lhs.$from.id.uuidString < rhs.$from.id.uuidString
        //            }
        //
        //        guard let ownerRelation = ownerRelations.first else {
        //            return ownerNodeID
        //        }
        //
        //        var nextVisited = visited
        //        nextVisited.insert(ownerNodeID)
        //        return try await deliveryNodeID(
        //            forRemoteOwnerNodeID: ownerRelation.$from.id,
        //            on: database,
        //            visited: nextVisited
        //        )
    }

    func executeActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?,
        onAcknowledgement:
            (@Sendable (KeepTalkingRequestAckState, String?) async -> Void)? =
            nil
    ) async -> KeepTalkingActionCallResult {
        let action: KeepTalkingAction
        let callerMask: KeepTalkingActionPermissionMask
        let allowedMCPTools: Set<String>?
        do {
            (action, callerMask, allowedMCPTools) = try await prepareActionCallExecution(
                request,
                context: context
            )
        } catch {
            if let onAcknowledgement {
                await onAcknowledgement(.rejected, error.localizedDescription)
            }
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

        if let onAcknowledgement {
            await onAcknowledgement(.accepted, "Accepted by target node.")
        }

        do {
            #if os(macOS)
            let sandboxPolicy = try? await scopeManager.resolvedPolicy(for: action)
            #endif
            let callResult: (content: [Tool.Content], isError: Bool?)
            switch action.payload {
                case .mcpBundle:
                    callResult = try await mcpManager.callAction(
                        action: action,
                        call: request.call,
                        allowedTools: allowedMCPTools
                    )
                case .skill:
                    #if os(macOS)
                    callResult = try await skillManager.callAction(
                        action: action,
                        call: request.call,
                        sandboxPolicy: sandboxPolicy
                    )
                    #else
                    callResult = (content: [], isError: true)
                    #endif
                case .primitive:
                    callResult = try await primitiveActionManager.callAction(
                        action: action,
                        call: request.call
                    )
                case .filesystem:
                    callResult = try await filesystemActionManager.callAction(
                        action: action,
                        call: request.call,
                        callerMask: callerMask,
                        contextID: request.contextID
                    )
                case .semanticRetrieval:
                    callResult = try await semanticRetrievalActionManager.callAction(
                        action: action,
                        call: request.call,
                        contextID: request.contextID
                    )
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
                    case .filesystem:
                        return "filesystem"
                    case .semanticRetrieval:
                        return "semantic_retrieval"
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

    private func prepareActionCallExecution(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?
    ) async throws -> (KeepTalkingAction, KeepTalkingActionPermissionMask, Set<String>?) {
        let action = try await resolveLocalActionForExecution(
            actionID: request.call.action
        )
        let callerNode = try await ensure(
            request.callerNodeID,
            for: KeepTalkingNode.self
        )

        if action.disabled == true {
            throw KeepTalkingClientError.actionCallNotAuthorized(
                action: request.call.action,
                caller: request.callerNodeID,
                context: request.contextID
            )
        }

        let callerMask = try await effectiveGrantMask(
            node: callerNode,
            action: action,
            context: context
        )

        guard callerMask != [] else {
            throw KeepTalkingClientError.actionCallNotAuthorized(
                action: request.call.action,
                caller: request.callerNodeID,
                context: request.contextID
            )
        }

        // blockingAuthorisation actions from remote callers are now handled via
        // the agentTurnContinuation message channel — the remote agent suspends
        // and B's user responds in-chat.  If this path is reached for such an
        // action it means a legacy or local caller is executing it; fall through
        // to normal execution in that case (local callers still use the approval
        // handler).
        if action.blockingAuthorisation == true,
            request.callerNodeID == config.node,
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

        let allowedMCPTools: Set<String>?
        if case .mcpBundle = action.payload {
            allowedMCPTools = try await effectiveAllowedMCPTools(
                node: callerNode,
                action: action,
                context: context
            )
        } else {
            allowedMCPTools = nil
        }

        return (action, callerMask, allowedMCPTools)
    }

    func handleIncomingActionCallRequest(
        _ request: KeepTalkingActionCallRequest
    ) async throws {
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()
        let inFlightTask: Task<KeepTalkingActionCallResult, Never>

        await sendActionCallAcknowledgementBestEffort(
            request,
            state: .received,
            message: "Received by target node."
        )

        if let cachedResult = cachedIncomingActionCallResult(for: request.id) {
            onLog?(
                "[action-call/request] duplicate completed request=\(requestID) action=\(actionID) resending cached result"
            )
            try await sendIncomingActionCallResult(
                cachedResult,
                requestID: requestID,
                actionID: actionID
            )
            return
        }

        let existingTask = existingIncomingActionCallTask(for: request.id)
        if let existingTask {
            onLog?(
                "[action-call/request] duplicate in-flight request=\(requestID) action=\(actionID) joining existing execution"
            )
            await sendActionCallAcknowledgementBestEffort(
                request,
                state: .accepted,
                message: "Request is already running on target node."
            )
            inFlightTask = existingTask
        } else {
            onLog?(
                "[action-call/request] handling request=\(requestID) action=\(actionID) caller=\(request.callerNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
            )
            let createdTask = Task { [weak self] in
                guard let self else {
                    return Self.actionCallErrorResult(
                        request,
                        error: KeepTalkingClientError.actionCallTimeout(
                            request.id
                        )
                    )
                }
                do {
                    let context = try await self.upsertContext(
                        KeepTalkingContext(id: request.contextID)
                    )
                    return await self.executeActionCallRequest(
                        request,
                        context: context,
                        onAcknowledgement: { state, message in
                            await self.sendActionCallAcknowledgementBestEffort(
                                request,
                                state: state,
                                message: message
                            )
                        }
                    )
                } catch {
                    await self.sendActionCallAcknowledgementBestEffort(
                        request,
                        state: .rejected,
                        message: error.localizedDescription
                    )
                    return Self.actionCallErrorResult(request, error: error)
                }
            }
            storeIncomingActionCallTask(createdTask, for: request.id)
            inFlightTask = createdTask
        }

        let result = await inFlightTask.value
        finalizeIncomingActionCall(
            requestID: request.id,
            result: result
        )
        try await sendIncomingActionCallResult(
            result,
            requestID: requestID,
            actionID: actionID
        )
        await runPrimitiveActionPostResultHookIfNeeded(
            actionID: request.call.action,
            call: request.call,
            result: result
        )
    }

    private static func actionCallErrorResult(
        _ request: KeepTalkingActionCallRequest,
        error: Error
    ) -> KeepTalkingActionCallResult {
        KeepTalkingActionCallResult(
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

    private func sendIncomingActionCallResult(
        _ result: KeepTalkingActionCallResult,
        requestID: String,
        actionID: String
    ) async throws {
        onLog?(
            "[action-call/result] returning request=\(requestID) action=\(actionID) is_error=\(result.isError)"
        )

        try await rtcClient.sendTrustedEnvelope(
            result,
            cryptorSource: trustedEnvelopeCryptorSource()
        )
    }

    private func sendActionCallAcknowledgementBestEffort(
        _ request: KeepTalkingActionCallRequest,
        state: KeepTalkingRequestAckState,
        message: String?
    ) async {
        let acknowledgement = KeepTalkingRequestAck(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            kind: .actionCall,
            state: state,
            actionID: request.call.action,
            message: message
        )
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()
        let messageSuffix = acknowledgementLogMessageSuffix(message)
        onLog?(
            "[action-call/ack] sending request=\(requestID) action=\(actionID) state=\(state.rawValue)\(messageSuffix)"
        )

        do {
            try await rtcClient.sendTrustedEnvelope(
                acknowledgement,
                cryptorSource: trustedEnvelopeCryptorSource()
            )
        } catch {
            onLog?(
                "[action-call/ack] failed request=\(requestID) action=\(actionID) state=\(state.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    func handleIncomingRequestAck(_ acknowledgement: KeepTalkingRequestAck) {
        guard acknowledgement.kind == .actionCall else {
            return
        }
        let requestID = acknowledgement.requestID.uuidString.lowercased()
        let actionID = acknowledgement.actionID?.uuidString.lowercased() ?? ""
        onLog?(
            "[action-call/ack] received request=\(requestID) action=\(actionID) state=\(acknowledgement.state.rawValue)\(acknowledgementLogMessageSuffix(acknowledgement.message))"
        )
        _ = resolvePendingActionCallAcknowledgement(acknowledgement)
    }

    private func cachedIncomingActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            completedIncomingActionCallResults[requestID]
        }
    }

    private func existingIncomingActionCallTask(for requestID: UUID)
        -> Task<KeepTalkingActionCallResult, Never>?
    {
        actionCallQueue.sync {
            inFlightIncomingActionCalls[requestID]
        }
    }

    private func storeIncomingActionCallTask(
        _ task: Task<KeepTalkingActionCallResult, Never>,
        for requestID: UUID
    ) {
        actionCallQueue.sync {
            inFlightIncomingActionCalls[requestID] = task
        }
    }

    private func finalizeIncomingActionCall(
        requestID: UUID,
        result: KeepTalkingActionCallResult
    ) {
        actionCallQueue.sync {
            inFlightIncomingActionCalls.removeValue(forKey: requestID)
            completedIncomingActionCallResults[requestID] = result
            completedIncomingActionCallOrder.removeAll {
                $0 == requestID
            }
            completedIncomingActionCallOrder.append(requestID)
            while completedIncomingActionCallOrder.count
                > Self.completedIncomingActionCallCacheLimit
            {
                let evicted = completedIncomingActionCallOrder.removeFirst()
                completedIncomingActionCallResults.removeValue(
                    forKey: evicted
                )
            }
        }
    }

    func dispatchActionCall(
        actionOwner: UUID,
        call: KeepTalkingActionCall,
        context: KeepTalkingContext,
        agentTurnID: UUID? = nil
    ) async throws -> KeepTalkingActionCallResult {
        // TODO: This is a bug
        let deliveryNodeID = try await deliveryNodeID(
            forRemoteOwnerNodeID: actionOwner
        )

        let request = KeepTalkingActionCallRequest(
            contextID: try context.requireID(),
            callerNodeID: config.node,
            targetNodeID: deliveryNodeID,
            call: call
        )
        let requestID = request.id.uuidString.lowercased()
        let actionID = call.action.uuidString.lowercased()

        if deliveryNodeID == config.node {
            onLog?(
                "[action-call/request] executing locally request=\(requestID) action=\(actionID)"
            )
            let result = await executeActionCallRequest(request, context: context)
            await runPrimitiveActionPostResultHookIfNeeded(
                actionID: call.action,
                call: call,
                result: result
            )
            return result
        }

        // Remote blocking actions use the continuation model instead of the
        // synchronous action-call channel. The agent turn suspends until the
        // remote user responds via the in-chat widget.
        if await shouldUseWakeAssistedDelivery(for: call.action), let agentTurnID {
            return try await dispatchBlockingActionCallViaContinuation(
                request: request,
                call: call,
                context: context,
                agentTurnID: agentTurnID
            )
        }

        onLog?(
            "[action-call/request] dispatching remote request=\(requestID) action=\(actionID) owner=\(actionOwner.uuidString.lowercased()) target=\(deliveryNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased())"
        )

        try await sendRemoteActionCallRequest(request, deliveryDescription: "rtc")

        return try await waitForActionCallResult(
            requestID: request.id,
            timeoutSeconds: Self.actionCallResultTimeoutSeconds
        )
    }

    private func dispatchBlockingActionCallViaContinuation(
        request: KeepTalkingActionCallRequest,
        call: KeepTalkingActionCall,
        context: KeepTalkingContext,
        agentTurnID: UUID
    ) async throws -> KeepTalkingActionCallResult {
        let actionID = call.action.uuidString.lowercased()
        let targetNodeID = request.targetNodeID
        onLog?(
            "[action-call/continuation] suspending agentTurnID=\(agentTurnID.uuidString.lowercased()) action=\(actionID) target=\(targetNodeID.uuidString.lowercased())"
        )

        // Encrypt the full action call request for the target node.
        let encryptedRequest = try await encryptActionCallRequestEnvelope(request)

        // Look up action kind for the `kind` label in the continuation message.
        let kind: String
        if let action = try? await KeepTalkingAction.find(call.action, on: localStore.database) {
            kind = switch action.payload {
                case .primitive(let b): b.action.rawValue
                case .mcpBundle: "mcp"
                case .skill: "skill"
                case .filesystem: "filesystem"
                case .semanticRetrieval: "semantic_retrieval"
            }
        } else {
            kind = actionID
        }

        let selfNode = try await getCurrentNodeInstance()
        let selfNodeID = try selfNode.requireID()
        let sender = KeepTalkingContextMessage.Sender.node(node: selfNodeID)

        // Push-wake the target node in case it's offline, then suspend.
        await sendActionWakeIfNeeded(
            actionOwner: targetNodeID,
            call: call,
            context: context
        )

        let content = try await suspendAgentTurnForContinuation(
            agentTurnID: agentTurnID,
            toolCallID: request.id.uuidString.lowercased(),
            actionID: call.action,
            targetNodeID: targetNodeID,
            kind: kind,
            encryptedPayload: encryptedRequest.ciphertext,
            context: context,
            sender: sender
        )

        // For file requests, wait until blobs have synced before returning
        // control to the agent so it can immediately read the files.
        if kind == KeepTalkingPrimitiveActionKind.askForFile.rawValue, !content.isEmpty {
            let contextID = try context.requireID()
            await waitForContinuationBlobs(from: content, in: contextID)
        }

        return KeepTalkingActionCallResult(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: config.node,
            targetNodeID: targetNodeID,
            actionID: call.action,
            content: content,
            isError: content.isEmpty
        )
    }

    private func sendRemoteActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        deliveryDescription: String
    ) async throws {
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()

        for attempt in 1...Self.actionCallAckRetryLimit {
            onLog?(
                "[action-call/request] sending request=\(requestID) action=\(actionID) attempt=\(attempt) delivery=\(deliveryDescription)"
            )
            try await rtcClient.sendTrustedEnvelope(
                request,
                cryptorSource: trustedEnvelopeCryptorSource()
            )

            let acknowledgement = try await waitForActionCallAcknowledgement(
                requestID: request.id,
                timeoutSeconds: Self.actionCallAckTimeoutSeconds
            )
            if acknowledgement != nil {
                return
            }
            if cachedReceivedActionCallResult(for: request.id) != nil {
                onLog?(
                    "[action-call/ack] missing request=\(requestID) action=\(actionID) but result already arrived"
                )
                return
            }
            guard attempt < Self.actionCallAckRetryLimit else {
                onLog?(
                    "[action-call/ack] missing request=\(requestID) action=\(actionID) after=\(Int(Self.actionCallAckTimeoutSeconds))s"
                )
                return
            }

            onLog?(
                "[action-call/ack] missing request=\(requestID) action=\(actionID) after=\(Int(Self.actionCallAckTimeoutSeconds))s; retrying on reliable route"
            )
            rtcClient.preferReliableRoute(
                reason: "missing action-call ack request=\(requestID)"
            )
        }
    }

    func waitForActionCallAcknowledgement(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingRequestAck? {
        if let acknowledgement = consumeReceivedActionCallAcknowledgement(
            for: requestID
        ) {
            return acknowledgement
        }

        return try await withThrowingTaskGroup(
            of: KeepTalkingRequestAck?.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else {
                    return nil
                }
                return try await withTaskCancellationHandler(
                    operation: {
                        try await withCheckedThrowingContinuation {
                            (
                                continuation: CheckedContinuation<
                                    KeepTalkingRequestAck, Error
                                >
                            ) in
                            self.actionCallQueue.sync {
                                if let acknowledgement =
                                    self
                                    .consumeReceivedActionCallAcknowledgementLocked(
                                        for: requestID
                                    )
                                {
                                    continuation.resume(
                                        returning: acknowledgement
                                    )
                                    return
                                }
                                self.pendingActionCallAcknowledgements[
                                    requestID
                                ] = continuation
                            }
                        }
                    },
                    onCancel: {
                        self.cancelPendingActionCallAcknowledgement(
                            requestID: requestID
                        )
                    }
                )
            }

            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                return nil
            }

            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    func waitForActionCallResult(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingActionCallResult {
        if let cachedResult = consumeReceivedActionCallResult(for: requestID) {
            return cachedResult
        }

        return try await withThrowingTaskGroup(
            of: KeepTalkingActionCallResult.self
        ) {
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
                        if let cachedResult =
                            self.consumeReceivedActionCallResultLocked(
                                for: requestID
                            )
                        {
                            continuation.resume(returning: cachedResult)
                            return
                        }
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
            if let continuation = pendingActionCallResults.removeValue(
                forKey: result.requestID
            ) {
                continuation.resume(returning: result)
                return true
            }

            storeReceivedActionCallResultLocked(result)
            return false
        }
    }

    func resolvePendingActionCallAcknowledgement(
        _ acknowledgement: KeepTalkingRequestAck
    ) -> Bool {
        actionCallQueue.sync {
            if let continuation =
                pendingActionCallAcknowledgements
                .removeValue(forKey: acknowledgement.requestID)
            {
                continuation.resume(returning: acknowledgement)
                return true
            }

            storeReceivedActionCallAcknowledgementLocked(acknowledgement)
            return false
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
            if let continuation = pendingActionCallResults.removeValue(
                forKey: requestID
            ) {
                continuation.resume(throwing: error)
            }
            if let continuation =
                pendingActionCallAcknowledgements
                .removeValue(forKey: requestID)
            {
                continuation.resume(throwing: error)
            }
        }
    }

    func failAllPendingActionCalls(error: Error) {
        actionCallQueue.sync {
            let pendingResults = pendingActionCallResults
            let pendingAcknowledgements = pendingActionCallAcknowledgements
            pendingActionCallResults.removeAll()
            pendingActionCallAcknowledgements.removeAll()
            receivedActionCallResults.removeAll()
            receivedActionCallResultOrder.removeAll()
            receivedActionCallAcknowledgements.removeAll()
            receivedActionCallAcknowledgementOrder.removeAll()
            for continuation in pendingResults.values {
                continuation.resume(throwing: error)
            }
            for continuation in pendingAcknowledgements.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func consumeReceivedActionCallAcknowledgement(for requestID: UUID)
        -> KeepTalkingRequestAck?
    {
        actionCallQueue.sync {
            consumeReceivedActionCallAcknowledgementLocked(for: requestID)
        }
    }

    private func consumeReceivedActionCallAcknowledgementLocked(
        for requestID: UUID
    ) -> KeepTalkingRequestAck? {
        let acknowledgement = receivedActionCallAcknowledgements.removeValue(
            forKey: requestID
        )
        if acknowledgement != nil {
            receivedActionCallAcknowledgementOrder.removeAll {
                $0 == requestID
            }
        }
        return acknowledgement
    }

    private func cancelPendingActionCallAcknowledgement(requestID: UUID) {
        actionCallQueue.sync {
            guard
                let continuation =
                    pendingActionCallAcknowledgements
                    .removeValue(forKey: requestID)
            else {
                return
            }
            continuation.resume(throwing: CancellationError())
        }
    }

    private func storeReceivedActionCallAcknowledgementLocked(
        _ acknowledgement: KeepTalkingRequestAck
    ) {
        receivedActionCallAcknowledgements[acknowledgement.requestID] =
            acknowledgement
        receivedActionCallAcknowledgementOrder.removeAll {
            $0 == acknowledgement.requestID
        }
        receivedActionCallAcknowledgementOrder.append(
            acknowledgement.requestID
        )
        while receivedActionCallAcknowledgementOrder.count
            > Self.actionCallDeliveryCacheLimit
        {
            let evicted = receivedActionCallAcknowledgementOrder.removeFirst()
            receivedActionCallAcknowledgements.removeValue(forKey: evicted)
        }
    }

    private func consumeReceivedActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            consumeReceivedActionCallResultLocked(for: requestID)
        }
    }

    private func cachedReceivedActionCallResult(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        actionCallQueue.sync {
            receivedActionCallResults[requestID]
        }
    }

    private func consumeReceivedActionCallResultLocked(for requestID: UUID)
        -> KeepTalkingActionCallResult?
    {
        let result = receivedActionCallResults.removeValue(forKey: requestID)
        if result != nil {
            receivedActionCallResultOrder.removeAll {
                $0 == requestID
            }
        }
        return result
    }

    private func storeReceivedActionCallResultLocked(
        _ result: KeepTalkingActionCallResult
    ) {
        receivedActionCallResults[result.requestID] = result
        receivedActionCallResultOrder.removeAll {
            $0 == result.requestID
        }
        receivedActionCallResultOrder.append(result.requestID)
        while receivedActionCallResultOrder.count
            > Self.actionCallDeliveryCacheLimit
        {
            let evicted = receivedActionCallResultOrder.removeFirst()
            receivedActionCallResults.removeValue(forKey: evicted)
        }
    }

    private func acknowledgementLogMessageSuffix(_ message: String?) -> String {
        let trimmed = message?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let trimmed, !trimmed.isEmpty else {
            return ""
        }
        return " message=\(trimmed)"
    }

    private func runPrimitiveActionPostResultHookIfNeeded(
        actionID: UUID,
        call: KeepTalkingActionCall,
        result: KeepTalkingActionCallResult
    ) async {
        guard !result.isError else {
            return
        }
        guard
            let action = try? await resolveLocalActionForExecution(
                actionID: actionID
            ),
            case .primitive(let primitive) = action.payload
        else {
            return
        }
        primitiveActionPostResultHandler?(primitive, call)
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

    public static func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        selfNode: KeepTalkingNode,
        on database: any Database
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        let actionID = try action.requireID()
        let selfNodeID = try selfNode.requireID()
        guard let ownerNodeID = action.$node.id else {
            return false
        }

        guard
            let relationID = try await preferredTrustedRelation(
                from: ownerNodeID,
                to: nodeID,
                allowing: context,
                allowPending: ownerNodeID != selfNodeID,
                on: database
            )?.requireID()
        else {
            return false
        }

        let approvals =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: database)
            .filter(\.$relation.$id == relationID)
            .filter(\.$action.$id, .equal, actionID)
            .all()

        return approvals.contains { approval in
            approval.applicable(in: context)
        }
    }

    public func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        try await Self.isActionGrantedToNode(
            node: node,
            action: action,
            context: context,
            selfNode: getCurrentNodeInstance(),
            on: localStore.database
        )
    }

    public func isNodeAuthorizedToGrantAction(
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

    func grantedActions(
        _ actions: [KeepTalkingAction],
        for node: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async throws -> [KeepTalkingAction] {
        var allowed: [KeepTalkingAction] = []
        allowed.reserveCapacity(actions.count)

        for action in actions {
            if action.disabled == true { continue }
            guard
                try await isActionGrantedToNode(
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
            case .text(let text, let annotations, let metadata):
                return """
                    text: \(text)
                    annotations: \(annotations.debugDescription)
                    metadata: \(metadata.debugDescription)
                    """
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
