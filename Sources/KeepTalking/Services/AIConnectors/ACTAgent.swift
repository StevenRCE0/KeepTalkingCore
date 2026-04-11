import Foundation
import OpenAI

// MARK: - ACT (Action-Calling-Turn) Agent
//
// The ACT agent is invoked exclusively through the `kt_run_action` tool.
// The primary model calls `kt_run_action(action_id:, task:)` and the ACT
// agent handles the full prefetch → call → distil cycle autonomously using
// the configured model. The main orchestrator loop only routes those tool
// calls into the ACT executor and otherwise stays meta-tool only.

extension KeepTalkingClient {

    private struct ACTResolvedAction: Sendable {
        let tools: [OpenAITool]
        let promptContext: String
    }

    // MARK: - Tool definition

    static let runActionToolFunctionName = "kt_run_action"

    /// Builds the `kt_run_action` tool that the primary model uses to delegate
    /// an action to the ACT agent.
    func makeRunActionTool() -> OpenAITool {
        .functionTool(
            .init(
                name: Self.runActionToolFunctionName,
                description: """
                    Delegate a KeepTalking action to the ACT (Action-Calling) agent.
                    The agent will autonomously discover the action's tools, call the
                    appropriate one with arguments derived from the conversation, and
                    return a concise summary of the result.
                    """,
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "action_id": JSONSchema(
                            .type(.string),
                            .description(
                                "UUID of the action to run, taken from the Available actions list."
                            )
                        ),
                        "task": JSONSchema(
                            .type(.string),
                            .description(
                                "Natural-language description of what the user wants accomplished."
                            )
                        ),
                    ]),
                    .required(["action_id", "task"]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    // MARK: - Tool executor

    /// Executes a `kt_run_action` tool call by running the ACT agent mini-loop.
    func executeRunActionToolCall(
        toolCallID: String,
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext,
        actConnector: any AIConnector,
        actModel: OpenAIModel,
        publisher: AIOrchestrator.AssistantPublisher
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        let args = try decodeToolArguments(rawArguments)

        guard
            let actionIDString = args["action_id"]?.stringValue,
            let actionID = UUID(uuidString: actionIDString)
        else {
            return [toolMessage(
                payload: jsonString(["ok": false, "error": "missing_or_invalid_action_id"]),
                toolCallID: toolCallID
            )]
        }

        guard
            let stub = runtimeCatalog.actionStubs.first(where: { $0.actionID == actionID })
        else {
            return [toolMessage(
                payload: jsonString([
                    "ok": false,
                    "error": "unknown_action_id",
                    "action_id": actionIDString,
                ]),
                toolCallID: toolCallID
            )]
        }

        let task = args["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return try await runACTMiniLoop(
            actionID: actionID,
            stub: stub,
            task: task,
            toolCallID: toolCallID,
            runtimeCatalog: runtimeCatalog,
            context: context,
            actConnector: actConnector,
            actModel: actModel,
            publisher: publisher
        )
    }

    // MARK: - Mini-loop

    private func runACTMiniLoop(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        task: String,
        toolCallID: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext,
        actConnector: any AIConnector,
        actModel: OpenAIModel,
        publisher: AIOrchestrator.AssistantPublisher
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        let resolvedAction = try await resolvedACTAction(
            actionID: actionID,
            stub: stub,
            runtimeCatalog: runtimeCatalog,
            context: context
        )
        let actionTools = resolvedAction.tools

        guard !actionTools.isEmpty else {
            return [toolMessage(
                payload: jsonString([
                    "ok": false,
                    "action_id": actionID.uuidString.lowercased(),
                    "error": "act_agent_no_tools",
                    "message":
                        "ACT agent could not resolve tools for this action.",
                ]),
                toolCallID: toolCallID
            )]
        }

        let contextID = (try? context.requireID())?.uuidString.lowercased() ?? "unknown"
        let aliasLookup = try await aliasLookup()
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: runtimeCatalog.routesByFunctionName
        )
        let ownerNodeName = aliasLookup.resolve(.node(stub.ownerNodeID)).primary()
        let selfNodeName = aliasLookup.resolve(.node(config.node)).primary()

        let systemPrompt = """
            You are an Action Execution Agent (ACT agent) for the KeepTalking platform.

            Your mission:
            1. Review the action tools available to you.
            2. Call the most appropriate tool with arguments that fulfil the user's task.
            3. Once you have a result, reply with a concise 1–3 sentence summary of the
               useful information returned by the tool.

            Context: \(contextID)
            Current node: \(selfNodeName)
            Action: \(stub.name) (id: \(actionID.uuidString.lowercased()), node: \(ownerNodeName))
            Task: \(task.isEmpty ? "(no specific task provided — use your best judgment)" : task)
            \(resolvedAction.promptContext.isEmpty ? "" : "\nAction metadata:\n\(resolvedAction.promptContext)\n")

            Be factual and direct. Only report what the tool returned. Do not speculate.
            """

        var actTranscript: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(systemPrompt))),
            .user(.init(content: .string(
                task.isEmpty ? "Please execute the action." : task
            ))),
        ]

        var summary = ""
        let maxACTTurns = 4

        for _ in 0..<maxACTTurns {
            let turn = try await actConnector.completeTurn(
                messages: actTranscript,
                tools: actionTools,
                model: actModel,
                toolChoice: .auto,
                stage: .planning,
                toolExecutor: nil
            )

            if let assistantMsg = assistantMessage(from: turn) {
                actTranscript.append(assistantMsg)
            }

            if !turn.toolCalls.isEmpty,
                let chatText = AIOrchestrator.chatText(
                    for: .init(assistantText: nil, toolCalls: turn.toolCalls),
                    stage: .execution,
                    toolNameResolver: { [self] toolCall in
                        publishedToolName(
                            for: toolCall,
                            runtimeCatalog: runtimeCatalog,
                            skillNameByActionID: skillNameByActionID,
                            aliasLookup: aliasLookup
                        )
                    },
                    toolHintResolver: { [self] toolCall, stage in
                        publishedToolHint(for: toolCall, stage: stage)
                    }
                )
            {
                try await publisher(chatText)
            }

            if let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                summary = text
            }

            guard !turn.toolCalls.isEmpty else { break }

            // Execute the action tool calls directly (no recursive ACT invocation).
            let executions = try await executeAgentToolCalls(
                turn.toolCalls,
                runtimeCatalog: runtimeCatalog,
                promptMessageID: nil,
                context: context
            )
            for exec in executions {
                actTranscript.append(contentsOf: exec.messages)
            }
        }

        if summary.isEmpty {
            summary = "Action executed successfully. No specific output to report."
        }

        return [toolMessage(
            payload: jsonString([
                "ok": true,
                "action_id": actionID.uuidString.lowercased(),
                "act_result": summary,
            ]),
            toolCallID: toolCallID
        )]
    }

    // MARK: - Helpers

    private func resolvedACTAction(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> ACTResolvedAction {
        switch stub.kind {
            case .mcp:
                return try await resolvedACTMCPAction(
                    actionID: actionID,
                    stub: stub,
                    runtimeCatalog: runtimeCatalog,
                    context: context
                )

            case .primitive:
                let definitions = runtimeCatalog.catalog.definitions
                    .filter { $0.actionID == actionID }
                return .init(
                    tools: definitions.map(\.openAITool),
                    promptContext: ""
                )

            case .skill:
                return try await resolvedACTSkillAction(
                    actionID: actionID,
                    stub: stub,
                    runtimeCatalog: runtimeCatalog,
                    context: context
                )

            case .semanticRetrieval:
                return .init(tools: [], promptContext: "")
        }
    }

    private func resolvedACTMCPAction(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> ACTResolvedAction {
        let existingDefinitions = runtimeCatalog.catalog.definitions
            .filter { $0.actionID == actionID }
        if !existingDefinitions.isEmpty {
            return .init(
                tools: existingDefinitions.map(\.openAITool),
                promptContext: ""
            )
        }

        guard
            let action = try await KeepTalkingAction.find(
                actionID,
                on: localStore.database
            ),
            case .mcpBundle(let bundle) = action.payload
        else {
            return .init(tools: [], promptContext: "")
        }

        let definitions: [KeepTalkingActionToolDefinition]
        if stub.isCurrentNode {
            definitions = await ensureLocalMCPToolsRegistered(
                actionID: actionID,
                stub: stub,
                runtimeCatalog: runtimeCatalog
            )
        } else {
            let result = try await dispatchActionCatalogRequest(
                targetNodeID: stub.ownerNodeID,
                queries: [
                    KeepTalkingActionCatalogQuery(
                        actionID: actionID,
                        kind: .mcpTools
                    )
                ],
                context: context
            )
            guard
                let item = result.items.first(where: {
                    $0.actionID == actionID && $0.kind == .mcpTools
                }),
                !item.isError
            else {
                return .init(tools: [], promptContext: "")
            }

            definitions = mcpProxyDefinitionsForRemoteAction(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                action: action,
                bundle: bundle,
                remoteTools: item.mcpTools
            )
            await cacheACTHydratedDefinitions(
                definitions,
                for: actionID,
                runtimeCatalog: runtimeCatalog
            )
        }

        let hydratedDefinitions = definitions.isEmpty
            ? runtimeCatalog.catalog.definitions.filter { $0.actionID == actionID }
            : definitions
        return .init(
            tools: hydratedDefinitions.map(\.openAITool),
            promptContext: ""
        )
    }

    private func cacheACTHydratedDefinitions(
        _ definitions: [KeepTalkingActionToolDefinition],
        for actionID: UUID,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) async {
        guard !definitions.isEmpty else { return }
        let routes = Dictionary(
            uniqueKeysWithValues: definitions.map { definition in
                (
                    definition.functionName,
                    KeepTalkingAgentToolRoute.actionProxy(definition)
                )
            }
        )
        await runtimeCatalog.lazyRegistry.register(
            routes: routes,
            for: actionID
        )
        runtimeCatalog.append(definitions: definitions, routes: routes)
    }

    private func resolvedACTSkillAction(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> ACTResolvedAction {
        if stub.isCurrentNode {
            guard
                let action = try await KeepTalkingAction.find(
                    actionID,
                    on: localStore.database
                ),
                case .skill(let bundle) = action.payload
            else {
                return .init(tools: [], promptContext: "")
            }

            let skillContext = loadSkillCatalogContext(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle
            )
            let actionToolDef = makeSkillActionProxyDefinition(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle,
                descriptor: action.descriptor,
                supportsWakeAssist: stub.supportsWakeAssist
            )
            let fileToolDef = makeSkillFileReaderDefinition(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle
            )
            let metaToolDef = makeSkillMetadataDefinition(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle
            )
            await cacheACTSkillDefinitions(
                actionID: actionID,
                actionToolDef: actionToolDef,
                metadataToolDef: metaToolDef,
                fileToolDef: fileToolDef,
                metadataRoute: .skillMetadata(skillContext),
                fileRoute: .skillFileLocal(skillContext),
                runtimeCatalog: runtimeCatalog
            )

            let tools = runtimeCatalog.catalog.definitions
                .filter { $0.actionID == actionID }
                .map(\.openAITool)
            return .init(
                tools: tools,
                promptContext: renderSkillMetadataPayload(
                    functionName: Self.ktSkillMetainfoToolFunctionName,
                    context: skillContext
                )
            )
        }

        let remoteAction = try await KeepTalkingAction.find(
            actionID,
            on: localStore.database
        )
        let result = try await dispatchActionCatalogRequest(
            targetNodeID: stub.ownerNodeID,
            queries: [
                KeepTalkingActionCatalogQuery(
                    actionID: actionID,
                    kind: .skillMetadata
                )
            ],
            context: context
        )
        guard
            let item = result.items.first(where: {
                $0.actionID == actionID && $0.kind == .skillMetadata
            }),
            !item.isError,
            let metadata = item.skillMetadata
        else {
            return .init(tools: [], promptContext: "")
        }

        let bundle = KeepTalkingSkillBundle(
            name: metadata.name,
            indexDescription: metadata.manifestMetadata["description"] ?? "",
            directory: URL(fileURLWithPath: metadata.directoryPath)
        )
        let actionToolDef = makeSkillActionProxyDefinition(
            actionID: actionID,
            ownerNodeID: stub.ownerNodeID,
            bundle: bundle,
            descriptor: remoteAction?.descriptor,
            supportsWakeAssist: stub.supportsWakeAssist
        )
        let metadataToolDef = makeSkillMetadataDefinition(
            actionID: actionID,
            ownerNodeID: stub.ownerNodeID,
            bundle: bundle
        )
        let fileToolDef = makeSkillFileReaderDefinition(
            actionID: actionID,
            ownerNodeID: stub.ownerNodeID,
            bundle: bundle
        )
        let skillContext = KeepTalkingSkillCatalogContext(
            actionID: actionID,
            ownerNodeID: stub.ownerNodeID,
            bundle: bundle,
            manifestPath: metadata.manifestPath,
            manifestMetadata: metadata.manifestMetadata,
            referencesFiles: metadata.referencesFiles,
            scripts: metadata.scripts,
            assets: metadata.assets,
            manifestPreview: metadata.manifestPreview,
            loadError: nil
        )
        await cacheACTSkillDefinitions(
            actionID: actionID,
            actionToolDef: actionToolDef,
            metadataToolDef: metadataToolDef,
            fileToolDef: fileToolDef,
            metadataRoute: .skillMetadata(skillContext),
            fileRoute: .skillFileRemote(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                skillName: metadata.name
            ),
            runtimeCatalog: runtimeCatalog
        )

        let tools = runtimeCatalog.catalog.definitions
            .filter { $0.actionID == actionID }
            .map(\.openAITool)
        let promptContext = jsonString([
            "ok": true,
            "function_name": Self.ktSkillMetainfoToolFunctionName,
            "route_kind": "skill_metadata",
            "action_id": actionID.uuidString.lowercased(),
            "owner_node_id": stub.ownerNodeID.uuidString.lowercased(),
            "skill_name": metadata.name,
            "manifest_path": metadata.manifestPath,
            "manifest_metadata": metadata.manifestMetadata,
            "references_files": metadata.referencesFiles,
            "scripts": metadata.scripts,
            "assets": metadata.assets,
        ])
        return .init(
            tools: tools,
            promptContext: promptContext
        )
    }

    private func cacheACTSkillDefinitions(
        actionID: UUID,
        actionToolDef: KeepTalkingActionToolDefinition,
        metadataToolDef: KeepTalkingActionToolDefinition,
        fileToolDef: KeepTalkingActionToolDefinition,
        metadataRoute: KeepTalkingAgentToolRoute,
        fileRoute: KeepTalkingAgentToolRoute,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) async {
        if await runtimeCatalog.lazyRegistry.isInitialized(actionID) {
            return
        }
        let routes: [String: KeepTalkingAgentToolRoute] = [
            actionToolDef.functionName: .actionProxy(actionToolDef),
            metadataToolDef.functionName: metadataRoute,
            fileToolDef.functionName: fileRoute,
        ]
        await runtimeCatalog.lazyRegistry.register(
            routes: routes,
            for: actionID
        )
        runtimeCatalog.append(
            definitions: [actionToolDef, metadataToolDef, fileToolDef],
            routes: routes
        )
    }
}
