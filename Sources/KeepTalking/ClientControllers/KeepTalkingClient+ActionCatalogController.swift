import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    private static let actionCatalogResultTimeoutSeconds: TimeInterval = 15
    private static let actionCatalogSkillManifestMaxCharacters = 20_000
    private static let actionCatalogSkillFileMaxCharacters = 30_000

    private var skillCatalogLoader: KeepTalkingSkillCatalogLoader {
        KeepTalkingSkillCatalogLoader(
            manifestPreviewMaxCharacters: Self
                .actionCatalogSkillManifestMaxCharacters,
            filePreviewMaxCharacters: Self.actionCatalogSkillFileMaxCharacters
        )
    }

    func executeActionCatalogRequest(
        _ request: KeepTalkingActionCatalogRequest,
        context: KeepTalkingContext?
    ) async -> KeepTalkingActionCatalogResult {
        do {
            let remoteNode = try await ensure(
                request.callerNodeID,
                for: KeepTalkingNode.self
            )

            let deduplicatedQueries = deduplicatedCatalogQueries(
                request.queries
            )
            var items: [KeepTalkingActionCatalogItemResult] = []
            items.reserveCapacity(deduplicatedQueries.count)

            for query in deduplicatedQueries {
                let item = await executeActionCatalogQuery(
                    query,
                    remoteNode: remoteNode,
                    context: context
                )
                items.append(item)
            }

            return KeepTalkingActionCatalogResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                items: items,
                isError: false
            )
        } catch {
            return KeepTalkingActionCatalogResult(
                requestID: request.id,
                contextID: request.contextID,
                callerNodeID: request.callerNodeID,
                targetNodeID: request.targetNodeID,
                items: [],
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    func handleIncomingActionCatalogRequest(
        _ request: KeepTalkingActionCatalogRequest
    ) async throws {
        let context = try await ensure(
            request.contextID,
            for: KeepTalkingContext.self
        )

        let result = await executeActionCatalogRequest(
            request,
            context: context
        )
        try await rtcClient.sendTrustedEnvelope(
            result,
            cryptorSource: trustedEnvelopeCryptorSource()
        )
    }

    func dispatchActionCatalogRequest(
        targetNodeID: UUID,
        queries: [KeepTalkingActionCatalogQuery],
        context: KeepTalkingContext
    ) async throws -> KeepTalkingActionCatalogResult {
        let deliveryNodeID = try await deliveryNodeID(
            forRemoteOwnerNodeID: targetNodeID
        )
        let request = KeepTalkingActionCatalogRequest(
            contextID: try context.requireID(),
            callerNodeID: config.node,
            targetNodeID: deliveryNodeID,
            queries: queries
        )

        if deliveryNodeID == config.node {
            return await executeActionCatalogRequest(request, context: context)
        }

        try await rtcClient.sendTrustedEnvelope(
            request,
            cryptorSource: trustedEnvelopeCryptorSource()
        )

        return try await waitForActionCatalogResult(
            requestID: request.id,
            timeoutSeconds: Self.actionCatalogResultTimeoutSeconds
        )
    }

    func waitForActionCatalogResult(
        requestID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> KeepTalkingActionCatalogResult {
        try await withThrowingTaskGroup(of: KeepTalkingActionCatalogResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.actionCatalogTimeout(requestID)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingActionCatalogResult, Error
                        >
                    ) in
                    self.actionCatalogQueue.sync {
                        self.pendingActionCatalogResults[requestID] =
                            continuation
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingActionCatalogRequest(
                    requestID: requestID,
                    error: KeepTalkingClientError.actionCatalogTimeout(requestID)
                )
                throw KeepTalkingClientError.actionCatalogTimeout(requestID)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.actionCatalogTimeout(requestID)
            }
            return first
        }
    }

    func resolvePendingActionCatalogResult(
        _ result: KeepTalkingActionCatalogResult
    ) -> Bool {
        actionCatalogQueue.sync {
            guard
                let continuation = pendingActionCatalogResults.removeValue(
                    forKey: result.requestID
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingActionCatalogRequest(requestID: UUID, error: Error) {
        actionCatalogQueue.sync {
            guard
                let continuation = pendingActionCatalogResults.removeValue(
                    forKey: requestID
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func failAllPendingActionCatalogRequests(error: Error) {
        actionCatalogQueue.sync {
            let pending = pendingActionCatalogResults
            pendingActionCatalogResults.removeAll()
            for continuation in pending.values {
                continuation.resume(throwing: error)
            }
        }
    }

    func enqueueIncomingActionCatalogRequest(
        _ request: KeepTalkingActionCatalogRequest
    ) {
        guard request.targetNodeID == config.node else {
            return
        }
        Task { [weak self] in
            try await self?.handleIncomingActionCatalogRequest(request)
        }
    }

    private func deduplicatedCatalogQueries(
        _ queries: [KeepTalkingActionCatalogQuery]
    ) -> [KeepTalkingActionCatalogQuery] {
        var seen: Set<String> = []
        var result: [KeepTalkingActionCatalogQuery] = []
        result.reserveCapacity(queries.count)

        for query in queries {
            let argumentsKey: String
            let normalizedArguments =
                KeepTalkingSkillCatalogLoader
                .normalizedFileArguments(query.arguments)
            if query.kind == .skillFile,
                !normalizedArguments.isEmpty,
                let data = try? JSONEncoder().encode(normalizedArguments),
                let json = String(data: data, encoding: .utf8)
            {
                argumentsKey = json
            } else {
                argumentsKey = ""
            }

            let key =
                "\(query.actionID.uuidString.lowercased())::\(query.kind.rawValue)::\(argumentsKey)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            result.append(query)
        }

        return result
    }

    private func executeActionCatalogQuery(
        _ query: KeepTalkingActionCatalogQuery,
        remoteNode: KeepTalkingNode,
        context: KeepTalkingContext?
    ) async -> KeepTalkingActionCatalogItemResult {
        do {
            let action = try await resolveLocalActionForExecution(
                actionID: query.actionID
            )
            guard
                try await isActionGrantedToNode(
                    node: remoteNode,
                    action: action,
                    context: context
                )
            else {
                throw KeepTalkingClientError.actionCallNotAuthorized(
                    action: query.actionID,
                    caller: try remoteNode.requireID(),
                    context: context?.id ?? config.contextID
                )
            }

            switch query.kind {
                case .mcpTools:
                    guard case .mcpBundle = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    try await preflightHTTPMCPAuthentication(action: action)
                    let tools = try await mcpManager.listActionTools(
                        action: action
                    )
                    let projectedTools = tools.map { tool in
                        KeepTalkingActionCatalogMCPTool(
                            name: tool.name,
                            description: tool.description,
                            inputSchema: tool.inputSchema
                        )
                    }
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        mcpTools: projectedTools,
                        isError: false
                    )

                case .skillMetadata:
                    guard case .skill(let bundle) = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    let metadata = try buildSkillCatalogMetadata(bundle)
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        skillMetadata: metadata,
                        isError: false
                    )

                case .skillFile:
                    guard case .skill(let bundle) = action.payload else {
                        throw KeepTalkingClientError.unsupportedActionPayload
                    }
                    let filePayload = try buildSkillFileCatalogPayload(
                        bundle,
                        arguments: query.arguments
                    )
                    return KeepTalkingActionCatalogItemResult(
                        actionID: query.actionID,
                        kind: query.kind,
                        skillFile: filePayload,
                        isError: false
                    )
            }
        } catch {
            return KeepTalkingActionCatalogItemResult(
                actionID: query.actionID,
                kind: query.kind,
                isError: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func buildSkillCatalogMetadata(
        _ bundle: KeepTalkingSkillBundle
    ) throws -> KeepTalkingActionCatalogSkillMetadata {
        try skillCatalogLoader.loadMetadata(bundle: bundle)
    }

    private func buildSkillFileCatalogPayload(
        _ bundle: KeepTalkingSkillBundle,
        arguments: [String: Value]?
    ) throws -> KeepTalkingActionCatalogSkillFile {
        try skillCatalogLoader.loadFilePayload(
            bundle: bundle,
            arguments: arguments
        )
    }
}
