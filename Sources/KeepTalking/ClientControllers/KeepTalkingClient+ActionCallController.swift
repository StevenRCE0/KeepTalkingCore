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
        do {
            action = try await prepareActionCallExecution(
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

    private func prepareActionCallExecution(
        _ request: KeepTalkingActionCallRequest,
        context: KeepTalkingContext?
    ) async throws -> KeepTalkingAction {
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

        return action
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

        let encryptedResult = try await encryptActionCallResultEnvelope(result)
        try rtcClient.sendEnvelope(.encryptedActionCallResult(encryptedResult))
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
            let encryptedAcknowledgement = try await encryptRequestAckEnvelope(
                acknowledgement
            )
            try rtcClient.sendEnvelope(
                .encryptedRequestAck(encryptedAcknowledgement)
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
        context: KeepTalkingContext
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

        let usesWakeAssistedDelivery = await shouldUseWakeAssistedDelivery(
            for: call.action
        )
        let deliveryDescription = usesWakeAssistedDelivery
            ? "rtc (with APN wake if needed)"
            : "rtc"
        onLog?(
            "[action-call/request] dispatching remote request=\(requestID) action=\(actionID) owner=\(actionOwner.uuidString.lowercased()) target=\(deliveryNodeID.uuidString.lowercased()) context=\(request.contextID.uuidString.lowercased()) delivery=\(deliveryDescription)"
        )
        if usesWakeAssistedDelivery {
            onLog?(
                "[action-call/request] wake-assisted delivery request=\(requestID) action=\(actionID) owner=\(actionOwner.uuidString.lowercased()) target=\(deliveryNodeID.uuidString.lowercased())"
            )
            await sendActionWakeIfNeeded(
                actionOwner: deliveryNodeID,
                call: call,
                context: context
            )
            await waitForNodeToComeOnline(deliveryNodeID)
        }

        let encryptedRequest = try await encryptActionCallRequestEnvelope(
            request
        )
        try await sendRemoteActionCallRequest(
            request,
            encryptedRequest: encryptedRequest,
            deliveryDescription: deliveryDescription
        )

        return try await waitForActionCallResult(
            requestID: request.id,
            timeoutSeconds: Self.actionCallResultTimeoutSeconds
        )
    }

    private func sendRemoteActionCallRequest(
        _ request: KeepTalkingActionCallRequest,
        encryptedRequest: KeepTalkingAsymmetricCipherEnvelope,
        deliveryDescription: String
    ) async throws {
        let requestID = request.id.uuidString.lowercased()
        let actionID = request.call.action.uuidString.lowercased()

        for attempt in 1...Self.actionCallAckRetryLimit {
            onLog?(
                "[action-call/request] sending request=\(requestID) action=\(actionID) attempt=\(attempt) delivery=\(deliveryDescription)"
            )
            try rtcClient.sendEnvelope(
                .encryptedActionCallRequest(encryptedRequest)
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
            if let continuation = pendingActionCallAcknowledgements
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
            if let continuation = pendingActionCallAcknowledgements
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
                let continuation = pendingActionCallAcknowledgements
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

    public static func isNodeAuthorizedForAction(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        guard let ownerNodeID = action.$node.id else {
            return false
        }
        if nodeID == ownerNodeID {
            return true
        }

        let actionID = try action.requireID()
        guard
            let relation = try await preferredTrustedRelation(
                from: ownerNodeID,
                to: nodeID,
                allowing: context,
                on: database
            )
        else {
            return false
        }

        let approvals = try await relation.$actionRelations
            .query(on: database)
            .filter(\.$action.$id == actionID)
            .all()

        return approvals.contains { approval in
            approval.applicable(in: context)
        }
    }

    public static func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> Bool {
        let nodeID = try node.requireID()
        guard let ownerNodeID = action.$node.id else {
            return false
        }
        if nodeID == ownerNodeID {
            return true
        }

        if let relation = try await preferredTrustedRelation(
            from: nodeID,
            to: ownerNodeID,
            allowing: context,
            on: database
        ),
            relation.relationship == .owner
        {
            return true
        }

        let actionID = try action.requireID()
        let relationIDs = try await KeepTalkingNodeRelation
            .query(on: database)
            .filter(\.$from.$id, .equal, nodeID)
            .all()
            .filter { relation in
                relation.relationship.isTrustedOrOwner
                    && relation.relationship.allows(context: context)
            }
            .compactMap(\.id)

        guard !relationIDs.isEmpty else {
            return false
        }

        let approvals = try await KeepTalkingNodeRelationActionRelation
            .query(on: database)
            .filter(\.$relation.$id ~~ relationIDs)
            .filter(\.$action.$id, .equal, actionID)
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

    public func isActionGrantedToNode(
        node: KeepTalkingNode,
        action: KeepTalkingAction,
        context: KeepTalkingContext?
    ) async throws -> Bool {
        try await Self.isActionGrantedToNode(
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
