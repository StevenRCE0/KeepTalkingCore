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

        let localActions = try await KeepTalkingAction.query(
            on: localStore.database
        )
        .filter(\.$node.$id, .equal, config.node)
        .all()

        for action in localActions {
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
}
