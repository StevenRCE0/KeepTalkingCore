import FluentKit
import Foundation
import MCP
import OpenAI

private struct LocalExecutorRegistrationTimeoutError: LocalizedError {
    let actionID: UUID
    let source: String
    let actionName: String
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        "Timed out registering \(source) executor '\(actionName)' (\(actionID.uuidString.lowercased())) after \(Int(timeoutSeconds))s."
    }
}

private struct LocalExecutorRegistrationFailedError: LocalizedError {
    let actionID: UUID
    let source: String
    let actionName: String
    let underlying: Error

    var errorDescription: String? {
        "Failed registering \(source) executor '\(actionName)' (\(actionID.uuidString.lowercased())): \(underlying.localizedDescription)"
    }
}

extension KeepTalkingClient {
    static let listingToolFunctionName = "kt_list_available_actions"
    static let maxAgentTurns = 8
    static let skillManifestPreviewMaxCharacters = 20_000
    static let skillFileMaxCharacters = 30_000

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = "gpt-5-codex"
    ) async throws -> String {
        guard let openAIConnector = try await resolveOpenAIConnector() else {
            throw KeepTalkingClientError.aiNotConfigured
        }

        await ensureMCPToolChangeObserverInstalled()

        let persistedContext = try await upsertContext(context)
        let runtimeCatalog = try await resolveActionRuntimeCatalog(
            in: persistedContext
        )
        onLog?(
            "[ai] catalog has \(runtimeCatalog.catalog.definitions.count) tool proxy definition(s)"
        )

        // TODO: be able to switch off in the configurations
        let webSearchTool = makeWebSearchTool()
        let listingTool = makeListingTool()

        let allTools: [OpenAITool] =
            runtimeCatalog.catalog.definitions.isEmpty
            ? []
            : [
                listingTool, webSearchTool,
            ] + runtimeCatalog.catalog.openAITools
        let contextTranscript = try await agentContextTranscript(
            persistedContext,
            skillSummaries: runtimeCatalog.skillSummaries
        )

        logInjectedAITools(
            runtimeCatalog: runtimeCatalog,
            allCompletionTools: allTools,
            context: persistedContext,
            model: model
        )

        let messages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(
                .init(
                    content: .textContent(
                        OpenAIConnector.keepTalkingSystemPrompt(
                            listingToolFunctionName:
                                Self.listingToolFunctionName,
                            contextTranscript: contextTranscript
                        )
                    )
                )
            ),
            .user(.init(content: .string(prompt))),
        ]

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                openAIConnector: openAIConnector,
                assistantMessageBuilder: { [self] turn in
                    assistantMessage(from: turn)
                },
                toolExecutor: { [self] toolCalls in
                    try await executeAgentToolCalls(
                        toolCalls,
                        runtimeCatalog: runtimeCatalog,
                        context: persistedContext
                    )
                },
                assistantPublisher: { [self] assistantText in
                    try await send(
                        assistantText,
                        in: persistedContext,
                        sender: .autonomous(name: "ai"),
                        emitLocalEnvelope: true
                    )
                }
            ),
            configuration: .init(maxTurns: Self.maxAgentTurns)
        )

        return try await orchestrator.run(
            messages: messages,
            tools: allTools,
            model: model
        )
    }

    func registerLocalActionsInExecutors() async throws {
        await ensureMCPToolChangeObserverInstalled()

        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )
        let context = try await ensure(
            config.contextID,
            for: KeepTalkingContext.self
        )
        let localActions = try await selfNode.$actions.query(
            on: localStore.database
        ).all()
        let authorizedLocalActions = try await authorizedActions(
            localActions,
            for: selfNode,
            context: context
        )

        for action in authorizedLocalActions {
            try await registerLocalExecutor(action)
        }

        await invalidateActionToolCatalog(
            reason: "register_local_actions_in_executors"
        )
    }

    private func registerLocalExecutor(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw KeepTalkingClientError.missingAction
        }

        let (source, actionName): (String, String) = {
            switch action.payload {
                case .mcpBundle(let bundle):
                    return ("mcp", bundle.name)
                case .skill(let bundle):
                    return ("skill", bundle.name)
                case .primitive(let bundle):
                    return ("primitive", bundle.name)
                case .none:
                    return ("unknown", "unknown")
            }
        }()

        let timeoutSeconds: TimeInterval = source == "mcp" ? 30 : 10
        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
        let actionIDLabel = actionID.uuidString.lowercased()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    switch action.payload {
                        case .mcpBundle:
                            let actionID = action.id?.uuidString.lowercased()
                                ?? "unknown"
                            onLog?("[mcp] registering local action=\(actionID)")
                            try await mcpManager.registerIfNeeded(action)
                            onLog?("[mcp] registered local action=\(actionID)")
                        case .skill:
                            let actionID = action.id?.uuidString.lowercased()
                                ?? "unknown"
                            onLog?("[skill] registering local action=\(actionID)")
                            try await skillManager.registerIfNeeded(action)
                            onLog?("[skill] registered local action=\(actionID)")
                        case .primitive:
                            let actionID = action.id?.uuidString.lowercased()
                                ?? "unknown"
                            onLog?(
                                "[primitive] registering local action=\(actionID)"
                            )
                            try await primitiveActionManager.registerIfNeeded(
                                action
                            )
                            onLog?(
                                "[primitive] registered local action=\(actionID)"
                            )
                        case .none:
                            return
                    }
                }
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    self.onLog?(
                        "[\(source)] registration timeout action=\(actionIDLabel) after=\(Int(timeoutSeconds))s"
                    )
                    throw LocalExecutorRegistrationTimeoutError(
                        actionID: actionID,
                        source: source,
                        actionName: actionName,
                        timeoutSeconds: timeoutSeconds
                    )
                }

                guard try await group.next() != nil else {
                    throw LocalExecutorRegistrationTimeoutError(
                        actionID: actionID,
                        source: source,
                        actionName: actionName,
                        timeoutSeconds: timeoutSeconds
                    )
                }
                group.cancelAll()
            }
        } catch let error as LocalExecutorRegistrationTimeoutError {
            throw error
        } catch {
            throw LocalExecutorRegistrationFailedError(
                actionID: actionID,
                source: source,
                actionName: actionName,
                underlying: error
            )
        }
    }

    func invalidateActionToolCatalog(reason: String) async {
        await KeepTalkingActionCatalogCache.shared.invalidate(nodeID: config.node)
        onLog?("[ai] catalog invalidated reason=\(reason)")
    }

    public func discoverActionToolCatalog(in context: KeepTalkingContext)
        async throws
        -> KeepTalkingActionToolCatalog
    {
        try await resolveActionRuntimeCatalog(in: context).catalog
    }

    func resolveOpenAIConnector() async throws -> OpenAIConnector? {
        openAIConnector
    }

    func ensureMCPToolChangeObserverInstalled() async {
        await mcpManager.setActionToolsChangedHandler { [weak self] actionID in
            await self?.invalidateActionToolCatalog(
                reason:
                    "mcp_tools_list_changed action=\(actionID.uuidString.lowercased())"
            )
        }
    }

    private func logInjectedAITools(
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        allCompletionTools: [OpenAITool],
        context: KeepTalkingContext,
        model: OpenAIModel
    ) {
        let contextID = context.id ?? config.contextID
        onLog?(
            "[ai/tools] request context=\(contextID.uuidString.lowercased()) model=\(model) total_tools=\(allCompletionTools.count) proxy_tools=\(runtimeCatalog.catalog.definitions.count)"
        )

        if !runtimeCatalog.catalog.definitions.isEmpty {
            let skillNameByActionID = skillNamesByActionID(
                routesByFunctionName: runtimeCatalog.routesByFunctionName
            )
            for definition in runtimeCatalog.catalog.definitions.sorted(by: {
                $0.functionName < $1.functionName
            }) {
                let route = runtimeCatalog.routesByFunctionName[
                    definition.functionName
                ]
                let actionName = actionDisplayName(
                    for: definition,
                    route: route,
                    skillNameByActionID: skillNameByActionID
                )
                let schemaText =
                    (try? JSONEncoder().encode(definition.parameters))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? "<schema-encode-failed>"
                onLog?(
                    "[ai/tools] name=\(definition.functionName) action_name=\(actionName) source=\(definition.source.rawValue) route=\(routeKind(route)) action=\(definition.actionID.uuidString.lowercased()) owner=\(definition.ownerNodeID.uuidString.lowercased()) mcp_tool=\(definition.mcpToolName ?? "") schema=\(schemaText)"
                )
            }
        }

        onLog?(
            "[ai/tools] listing_tool_name=\(Self.listingToolFunctionName) injected=\(!runtimeCatalog.catalog.definitions.isEmpty)"
        )
    }
}
