import FluentKit
import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    static let listingToolFunctionName = "kt_list_available_actions"
    static let maxAgentTurns = 8
    static let skillManifestPreviewMaxCharacters = 20_000
    static let skillFileMaxCharacters = 30_000

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = .gpt4_o
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

        let listingTool = makeListingTool()
        let allTools: [ChatQuery.ChatCompletionToolParam] =
            runtimeCatalog.catalog.definitions.isEmpty
            ? []
            : [listingTool] + runtimeCatalog.catalog.openAITools
        let contextTranscript = try await agentContextTranscript(
            persistedContext,
            skillSummaries: runtimeCatalog.skillSummaries
        )
        logInjectedAITools(
            runtimeCatalog: runtimeCatalog,
            allTools: allTools,
            context: persistedContext,
            model: model
        )

        let messages: [ChatQuery.ChatCompletionMessageParam] = [
            .developer(
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
                        sender: .autonomous(name: "ai")
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
            switch action.payload {
                case .mcpBundle:
                    try await mcpManager.registerIfNeeded(action)
                case .skill:
                    try await skillManager.registerIfNeeded(action)
                default:
                    continue
            }
        }

        await invalidateActionToolCatalog(
            reason: "register_local_actions_in_executors"
        )
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
        allTools: [ChatQuery.ChatCompletionToolParam],
        context: KeepTalkingContext,
        model: OpenAIModel
    ) {
        let contextID = context.id ?? config.contextID
        onLog?(
            "[ai/tools] request context=\(contextID.uuidString.lowercased()) model=\(model) total_tools=\(allTools.count) proxy_tools=\(runtimeCatalog.catalog.definitions.count)"
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
