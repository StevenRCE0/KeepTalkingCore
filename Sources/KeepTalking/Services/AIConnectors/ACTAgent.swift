import AIProxy
import Foundation

// MARK: - ACT (Action-Calling-Turn) Agent
//
// The ACT agent is invoked exclusively through the `kt_run_action` tool.
// The primary model calls `kt_run_action(action_id:, task:)` and the ACT
// agent handles the full schema-resolution → call → distil cycle
// autonomously using the configured model. The main orchestrator loop only
// routes those tool calls into the ACT executor and otherwise stays
// meta-tool only.

extension KeepTalkingClient {

    private struct ACTResolvedAction: Sendable {
        let tools: [KeepTalkingActionToolDefinition]
        let promptContext: String
    }

    // MARK: - Tool definition

    static let runActionToolFunctionName = "kt_run_action"

    /// Builds the `kt_run_action` tool that the primary model uses to delegate
    /// an action to the ACT agent.
    func makeRunActionTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.runActionToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: """
                Delegate a KeepTalking action to the ACT (Action-Calling) agent.
                The agent will autonomously discover the action's tools, call the
                appropriate one with arguments derived from the conversation, and
                return a concise summary of the result.
                """,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "action_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "UUID of the action to run, taken from the Available actions list."
                        ),
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Natural-language description of what the user wants accomplished."
                        ),
                    ]),
                ]),
                "required": .array([.string("action_id"), .string("task")]),
                "additionalProperties": .bool(false),
            ]
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
        actModel: String,
        publisher: AIOrchestrator.AssistantPublisher,
        agentTurnID: UUID? = nil
    ) async throws -> [AIMessage] {
        let args = try decodeToolArguments(rawArguments)

        guard
            let actionIDString = args["action_id"]?.stringValue,
            let actionID = UUID(uuidString: actionIDString)
        else {
            return [
                toolMessage(
                    payload: jsonString(["ok": false, "error": "missing_or_invalid_action_id"]),
                    toolCallID: toolCallID
                )
            ]
        }

        guard
            let stub = runtimeCatalog.actionStubs.first(where: { $0.actionID == actionID })
        else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "error": "unknown_action_id",
                        "action_id": actionIDString,
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        let task = args["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        actLog(
            "start action=\(actionID.uuidString.lowercased()) kind=\(stub.kind.rawValue) node=\(stub.ownerNodeID.uuidString.lowercased()) task=\(clipped(task.isEmpty ? "(empty)" : task, maxCharacters: 160))"
        )

        return try await runACTMiniLoop(
            actionID: actionID,
            stub: stub,
            task: task,
            toolCallID: toolCallID,
            runtimeCatalog: runtimeCatalog,
            context: context,
            actConnector: actConnector,
            actModel: actModel,
            publisher: publisher,
            agentTurnID: agentTurnID
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
        actModel: String,
        publisher: AIOrchestrator.AssistantPublisher,
        agentTurnID: UUID? = nil
    ) async throws -> [AIMessage] {
        let resolvedAction = try await resolvedACTAction(
            actionID: actionID,
            stub: stub,
            runtimeCatalog: runtimeCatalog,
            context: context
        )
        let actionTools = resolvedAction.tools

        guard !actionTools.isEmpty else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "action_id": actionID.uuidString.lowercased(),
                        "error": "act_agent_no_tools",
                        "message":
                            "ACT agent could not resolve tools for this action.",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        let contextID = (try? context.requireID())?.uuidString.lowercased() ?? "unknown"
        let aliasLookup = try await aliasLookup()
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: runtimeCatalog.routesByFunctionName
        )
        let ownerNodeName = aliasLookup.resolve(.node(stub.ownerNodeID)).primary()
        let selfNodeName = aliasLookup.resolve(.node(config.node)).primary()

        let typeGuidance = AIPromptPresets.actAgentTypeGuidance(for: stub.kind)
        let systemPrompt = """
            You are an Action Execution Agent (ACT agent) for the KeepTalking platform.

            Your mission:
            1. Review the action tools available to you.
            2. Call the most appropriate tool with arguments that fulfil the user's task.
            3. Once you have a result, reply with a concise 1–3 sentence summary of the
               useful information returned by the tool.

            Context: \(contextID)
            Current node: \(selfNodeName)
            Action: \(stub.name) (id: \(actionID.uuidString.lowercased()), type: \(stub.kind.rawValue), node: \(ownerNodeName))
            Task: \(task.isEmpty ? "(no specific task provided — use your best judgment)" : task)
            \(resolvedAction.promptContext.isEmpty ? "" : "\nAction metadata:\n\(resolvedAction.promptContext)\n")
            \(typeGuidance)

            Be factual and direct. Only report what the tool returned. Do not speculate.
            Your job is to get the user's task done — not to ask for clarification or request more information. Make your best judgment and execute.
            """

        var actTranscript: [AIMessage] = [
            .system(systemPrompt),
            .user(task.isEmpty ? "Please execute the action." : task),
        ]

        var summary = ""
        let maxACTTurns = 4
        var stepIndex = 0

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

            // Capture intermediate "thinking" text the inner agent produced
            // alongside its tool calls; we publish it per-turn so the user
            // can watch progress fold into the parent "Inspecting · <action>"
            // row instead of waiting for the loop to finish.
            if let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                summary = text
            }

            guard !turn.toolCalls.isEmpty else {
                // No tool calls → done. Publish a final summary row.
                if !summary.isEmpty {
                    try await publishACTTraceUpdate(
                        publisher: publisher,
                        parentActionName: stub.name,
                        params: ["summary": summary]
                    )
                }
                break
            }

            // Execute the action tool calls directly (no recursive ACT invocation).
            let executions = try await executeAgentToolCalls(
                turn.toolCalls,
                runtimeCatalog: runtimeCatalog,
                promptMessageID: nil,
                context: context,
                agentTurnID: agentTurnID,
                agentIntention: task
            )
            actLog(
                "action-result action=\(actionID.uuidString.lowercased()) calls=\(turn.toolCalls.map(\.name).joined(separator: ",")) payload=\(actExecutionPreview(executions, source: stub.kind))"
            )
            for exec in executions {
                actTranscript.append(contentsOf: exec.messages)
            }
            // Inject native file content inline so the ACT agent can work with
            // files directly without needing to call kt_get_context_attachment.
            let injected = try await adaptMidTurnInjectionMessages(
                executions,
                runtimeCatalog: runtimeCatalog,
                context: context,
                transferReceiptTimeout: .seconds(0)  // blobs already synced
            )
            actTranscript.append(contentsOf: injected)

            // Fold this step's call+result into the parent's expand. The
            // chat renderer merges Output intermediates with matching
            // (actionName, agentTurnID) into the originating tool-call row,
            // so each step appears as additional rows under the parent
            // "Inspecting · <action>" without spawning standalone entries.
            for (toolCall, exec) in zip(turn.toolCalls, executions) {
                stepIndex += 1
                let displayName = publishedToolName(
                    for: toolCall,
                    runtimeCatalog: runtimeCatalog,
                    skillNameByActionID: skillNameByActionID,
                    aliasLookup: aliasLookup
                )
                let resultText = ACTAgentResultExtractor.text(from: exec.messages) ?? ""
                let params = ACTAgentResultExtractor.parameters(
                    stepIndex: stepIndex,
                    toolDisplayName: displayName,
                    arguments: toolCall.argumentsJSON,
                    resultText: resultText
                )
                try await publishACTTraceUpdate(
                    publisher: publisher,
                    parentActionName: stub.name,
                    params: params
                )
            }
        }

        if summary.isEmpty {
            summary = "Action executed successfully. No specific output to report."
        }
        actLog(
            "final-result action=\(actionID.uuidString.lowercased()) summary=\(clipped(summary, maxCharacters: 240))"
        )

        return [
            toolMessage(
                payload: jsonString([
                    "ok": true,
                    "action_id": actionID.uuidString.lowercased(),
                    "act_result": summary,
                ]),
                toolCallID: toolCallID
            )
        ]
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
                    tools: definitions,
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

            case .filesystem:
                return try await resolvedACTFilesystemAction(
                    actionID: actionID,
                    stub: stub,
                    runtimeCatalog: runtimeCatalog,
                    context: context
                )
        }
    }

    /// Returns a tool definition for use inside the ACT mini-loop. Uses the
    /// original MCP `targetName` as the callable function name so the model can
    /// call tools by their real name (e.g. "XcodeListWindows") rather than the
    /// opaque normalized ID.
    private static func actMCPToolDefinition(
        from definition: KeepTalkingActionToolDefinition
    ) -> KeepTalkingActionToolDefinition {
        guard let targetName = definition.targetName, !targetName.isEmpty else {
            return definition
        }
        return .init(
            functionName: targetName,
            actionID: definition.actionID,
            ownerNodeID: definition.ownerNodeID,
            source: definition.source,
            targetName: definition.targetName,
            displayName: definition.displayName,
            supportsWakeAssist: definition.supportsWakeAssist,
            description: definition.description,
            parameters: definition.parameters
        )
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
                tools: existingDefinitions.map(Self.actMCPToolDefinition),
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
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=local_mcp definitions=\(definitions.count)"
            )
        } else {
            actLog(
                "outgoing-request action=\(actionID.uuidString.lowercased()) kind=mcp_tools target=\(stub.ownerNodeID.uuidString.lowercased())"
            )
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
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=remote_mcp tools=\(item.mcpTools.count)"
            )

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

        let hydratedDefinitions =
            definitions.isEmpty
            ? runtimeCatalog.catalog.definitions.filter { $0.actionID == actionID }
            : definitions
        return .init(
            tools: hydratedDefinitions.map(Self.actMCPToolDefinition),
            promptContext: ""
        )
    }

    private func cacheACTHydratedDefinitions(
        _ definitions: [KeepTalkingActionToolDefinition],
        for actionID: UUID,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) async {
        guard !definitions.isEmpty else { return }
        var routes: [String: KeepTalkingAgentToolRoute] = [:]
        for definition in definitions {
            routes[definition.functionName] = .actionProxy(definition)
            // Also register the original MCP tool name as a route alias.
            if let targetName = definition.targetName, !targetName.isEmpty {
                routes[targetName] = .actionProxy(definition)
            }
        }
        await runtimeCatalog.lazyRegistry.register(
            routes: routes,
            for: actionID
        )
        runtimeCatalog.append(definitions: definitions, routes: routes)
        actLog(
            "runtime-catalog action=\(actionID.uuidString.lowercased()) injected=\(definitions.count)"
        )

        // Persist the resolved tool names into the bundle so the grant UI
        // can display them without a live MCP round-trip.
        let toolNames = definitions.compactMap(\.targetName).filter { !$0.isEmpty }
        if !toolNames.isEmpty,
            let action = try? await KeepTalkingAction.find(actionID, on: localStore.database),
            case .mcpBundle(var bundle) = action.payload
        {
            bundle.cachedTools = toolNames.sorted()
            action.payload = .mcpBundle(bundle)
            try? await action.save(on: localStore.database)
        }
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
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=local_skill definitions=3 skill=\(bundle.name)"
            )

            let tools = runtimeCatalog.catalog.definitions
                .filter { $0.actionID == actionID }
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
        actLog(
            "outgoing-request action=\(actionID.uuidString.lowercased()) kind=skill_metadata target=\(stub.ownerNodeID.uuidString.lowercased())"
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
        actLog(
            "incoming-schema action=\(actionID.uuidString.lowercased()) source=remote_skill skill=\(metadata.name) manifest=\(metadata.manifestPath)"
        )

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
        actLog(
            "runtime-catalog action=\(actionID.uuidString.lowercased()) injected=3"
        )
    }

    private func resolvedACTFilesystemAction(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> ACTResolvedAction {
        let existingDefinitions = runtimeCatalog.catalog.definitions
            .filter { $0.actionID == actionID }
        if !existingDefinitions.isEmpty {
            return .init(tools: existingDefinitions, promptContext: "")
        }

        guard
            let action = try await KeepTalkingAction.find(actionID, on: localStore.database),
            case .filesystem(let bundle) = action.payload
        else {
            return .init(tools: [], promptContext: "")
        }

        let tools: [KeepTalkingFilesystemTool]
        if stub.isCurrentNode {
            tools = await filesystemActionManager.availableTools(bundle: bundle, mask: .all)
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=local_filesystem tools=\(tools.count)"
            )
        } else {
            actLog(
                "outgoing-request action=\(actionID.uuidString.lowercased()) kind=filesystem_tools target=\(stub.ownerNodeID.uuidString.lowercased())"
            )
            let result = try await dispatchActionCatalogRequest(
                targetNodeID: stub.ownerNodeID,
                queries: [
                    KeepTalkingActionCatalogQuery(actionID: actionID, kind: .filesystemTools)
                ],
                context: context
            )
            guard
                let item = result.items.first(where: {
                    $0.actionID == actionID && $0.kind == .filesystemTools
                }),
                !item.isError
            else {
                return .init(tools: [], promptContext: "")
            }
            tools = item.filesystemTools
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=remote_filesystem tools=\(tools.count)"
            )
        }

        let definitions = makeFilesystemToolDefinitions(
            actionID: actionID,
            ownerNodeID: stub.ownerNodeID,
            bundle: bundle,
            supportsWakeAssist: stub.supportsWakeAssist,
            allowedTools: tools
        )
        var routes: [String: KeepTalkingAgentToolRoute] = [:]
        for definition in definitions {
            routes[definition.functionName] = .actionProxy(definition)
        }
        guard !definitions.isEmpty else {
            return .init(tools: [], promptContext: "")
        }
        await runtimeCatalog.lazyRegistry.register(routes: routes, for: actionID)
        runtimeCatalog.append(definitions: definitions, routes: routes)
        actLog(
            "runtime-catalog action=\(actionID.uuidString.lowercased()) injected=\(definitions.count)"
        )
        return .init(tools: definitions, promptContext: "")
    }

    private func actExecutionPreview(
        _ executions: [AIOrchestrator.ToolExecution],
        source: KeepTalkingActionStub.Kind
    ) -> String {
        let payloads = executions.flatMap(\.messages).compactMap { message -> String? in
            guard message.role == .tool else { return nil }
            return message.content?.text
        }
        guard !payloads.isEmpty else {
            return "<no-tool-payload>"
        }
        if source == .skill {
            // skill tool results (script outputs) are structured; let's show a preview.
            return clipped(payloads.joined(separator: " | "), maxCharacters: 400)
        }
        return clipped(payloads.joined(separator: " | "), maxCharacters: 320)
    }

    private func actLog(_ message: String) {
        onLog?("[ACT] \(message)")
    }

    /// Publish a trace update keyed to the outer "Inspecting · <action>"
    /// row. The chat's mergedOutputParams logic folds every Output
    /// intermediate sharing the same (actionName, agentTurnID) into the
    /// parent tool-call row's expand — so successive ACT steps accumulate
    /// as additional rows there without spawning standalone entries.
    fileprivate func publishACTTraceUpdate(
        publisher: AIOrchestrator.AssistantPublisher,
        parentActionName: String,
        params: [String: String]
    ) async throws {
        try await publisher(
            (
                parentActionName,
                .intermediate(
                    hint: "Output",
                    targetNodeID: nil,
                    actionID: nil,
                    actionName: parentActionName,
                    parameters: params
                )
            )
        )
    }
}

/// Helper functions to extract structured fields from inner-tool execution
/// results so the ACT mini-loop can fold step-by-step traces into the
/// parent's "Inspecting · <action>" row. Kept as a free enum so the logic
/// is unit-testable without spinning up the full ACT machinery.
enum ACTAgentResultExtractor {
    /// Pull the first `.tool`-role message's text out of a list of messages.
    static func text(from messages: [AIMessage]) -> String? {
        for message in messages where message.role == .tool {
            if case .text(let str)? = message.content {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let content = message.content {
                let projection = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !projection.isEmpty { return projection }
            }
        }
        return nil
    }

    /// Build the per-step parameters dict published to the parent row.
    /// Compact arg summary on top, then the structured script-result fields
    /// (command/exit_code/stdout/stderr) when present, otherwise the raw
    /// reply text under a single `result` key.
    static func parameters(
        stepIndex: Int,
        toolDisplayName: String,
        arguments: String,
        resultText: String
    ) -> [String: String] {
        let prefix = String(format: "%02d", stepIndex)
        var out: [String: String] = [
            "\(prefix). \(toolDisplayName)": shortArguments(arguments)
        ]

        if resultText.hasPrefix("command:") {
            // Surface the actual script run with its raw stdout/stderr.
            for (key, value) in parseScriptResultBlock(resultText) {
                out["\(prefix). \(key)"] = value
            }
        } else if !resultText.isEmpty {
            out["\(prefix). result"] = resultText
        }
        return out
    }

    /// One-line summary of a tool-call's arguments JSON, capped at 200
    /// chars. Used as the value next to the call's display name.
    private static func shortArguments(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return "(no arguments)" }
        return trimmed.count > 200
            ? String(trimmed.prefix(200)) + "…"
            : trimmed
    }

    /// Parse the canonical `command:\n…\nexit_code: N\nstdout:\n…\nstderr:\n…`
    /// block emitted by `SkillManager.executeRunScript`. Mirrors the parser
    /// in `AIOrchestrator.parseScriptResultParameters` but kept local so
    /// this extractor has no orchestrator dependency.
    private static func parseScriptResultBlock(_ text: String) -> [(String, String)] {
        let keys = ["command", "exit_code", "stdout", "stderr", "summary"]
        var ranges: [(key: String, range: Range<String.Index>)] = []
        for key in keys {
            if let r = text.range(of: "\n\(key):") ?? text.range(of: "\(key):") {
                ranges.append((key, r))
            }
        }
        guard !ranges.isEmpty else { return [] }
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [(String, String)] = []
        for (i, entry) in ranges.enumerated() {
            let valueStart = entry.range.upperBound
            let valueEnd = i + 1 < ranges.count ? ranges[i + 1].range.lowerBound : text.endIndex
            let raw = text[valueStart..<valueEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((entry.key, raw.isEmpty ? "<empty>" : raw))
        }
        return out
    }
}
