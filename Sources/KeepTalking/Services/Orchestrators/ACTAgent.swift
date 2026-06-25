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
    static func makeRunActionTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.runActionToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: """
                Delegate a KeepTalking action to the ACT (Action-Calling) agent.
                Choose the action_id from the full Available actions list before
                calling this. The ACT agent only receives that selected action,
                then autonomously discovers its tools, calls the appropriate one
                with arguments derived from the conversation, and returns a
                concise summary of the result. To feed a file into the action,
                first stage it on the action's owner node with kt_send_file, then
                pass the returned handle(s) in `input_handles` here. To capture a
                file the action PRODUCES, request it in `outputs`; the inner
                skill/action receives an exact `$KT_...` write variable for each
                requested output. Produced resource content is injected into the
                following turn automatically; its `handle` is the stable identity
                to mention or pass to a later action.
                Identify resources by `handle`, not by name: identical filenames
                across resources are DISTINCT files, never the same one.
                """,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "action_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "UUID of the best matching action from the full Available actions list. Match by user intent, node, action name, type, and description before delegating."
                        ),
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Natural-language description of what the selected action should accomplish, including any target node/action context the user implied."
                        ),
                    ]),
                    "input_handles": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Optional resource handles (KT_<KIND>_<HEX> form — from kt_send_file or a prior produced_resources entry) to deliver as the action's file input. Only use handles staged on this action's owner node."
                        ),
                    ]),
                    "outputs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object([
                                    "type": .string("string"),
                                    "description": .string(
                                        "Logical name for this output (e.g. \"result\"). The executor will expose the concrete write path in the inner action's KeepTalking resources block as an exact `$KT_...` variable; the action must write to that listed variable."
                                    ),
                                ]),
                                "persistence": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("attachment"), .string("otb")]),
                                    "description": .string(
                                        "attachment = durable, shared with this context's participants; otb = private, ephemeral, delivered point-to-point to you only."
                                    ),
                                ]),
                                "multiple": .object([
                                    "type": .string("boolean"),
                                    "description": .string(
                                        "True if this output may be several files (a collection) rather than one."
                                    ),
                                ]),
                            ]),
                            "required": .array([.string("name"), .string("persistence")]),
                        ]),
                        "description": .string(
                            "Optional outputs you want this action to PRODUCE. Each becomes a write handle the action fills; KeepTalking delivers it as a durable attachment or a private file per `persistence`. Use this to capture an action's file output (and later reference it)."
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
        // Keep the resolved (kind, id) — not just the bare UUID — so the ACT agent
        // can be TOLD which canonical handles it holds (the bare-UUID side-channel
        // alone left the agent blind to its own handles).
        let resolvedInputHandles: [(kind: KTResourceManifest.Kind?, id: UUID)] =
            args["input_handles"]?.arrayValue?.compactMap {
                $0.stringValue.flatMap { KTResourceManifest.resolveAgentHandle($0) }
            } ?? []
        let inputHandles = resolvedInputHandles.map(\.id)
        // Caller-requested OUTPUTS the action should PRODUCE. We mint each handle id
        // here (caller-side) so it round-trips with the produced output; `persistence`
        // is the caller's switch (durable attachment vs private OTB).
        let outputHandles: [KeepTalkingActionOutputHandle]? = {
            guard case .array(let entries)? = args["outputs"] else { return nil }
            let handles: [KeepTalkingActionOutputHandle] = entries.compactMap { entry in
                guard case .object(let obj) = entry,
                    case .string(let rawName)? = obj["name"]
                else { return nil }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let persistence: KeepTalkingActionOutputHandle.Persistence = {
                    if case .string(let p)? = obj["persistence"], p.lowercased() == "otb" {
                        return .otb
                    }
                    return .attachment
                }()
                let multiple: Bool = {
                    if case .bool(let m)? = obj["multiple"] { return m }
                    return false
                }()
                return KeepTalkingActionOutputHandle(
                    name: name, persistence: persistence, multiple: multiple)
            }
            return handles.isEmpty ? nil : handles
        }()
        actLog(
            "start action=\(actionID.uuidString.lowercased()) kind=\(stub.kind.rawValue) node=\(stub.ownerNodeID.uuidString.lowercased()) handles=\(inputHandles.count) task=\(clipped(task.isEmpty ? "(empty)" : task, maxCharacters: 160))"
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
            agentTurnID: agentTurnID,
            inputHandles: inputHandles.isEmpty ? nil : inputHandles,
            resolvedInputHandles: resolvedInputHandles,
            outputHandles: outputHandles
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
        agentTurnID: UUID? = nil,
        inputHandles: [UUID]? = nil,
        resolvedInputHandles: [(kind: KTResourceManifest.Kind?, id: UUID)] = [],
        outputHandles: [KeepTalkingActionOutputHandle]? = nil
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
        let resourceBlock = await describeDelegatedInputResources(
            resolvedInputHandles, in: context)
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
            \(resolvedAction.promptContext.isEmpty ? "" : "\nAction metadata:\n\(resolvedAction.promptContext)\n")\(resourceBlock)
            \(typeGuidance)

            Be factual and direct. Only report what the tool returned. Do not speculate.
            If the tool result shows a non-zero exit code or an error, report that FAILURE honestly — never claim success when the output shows an error.
            Your job is to get the user's task done — not to ask for clarification or request more information. Make your best judgment and execute.
            """

        var actTranscript: [AIMessage] = [
            .system(systemPrompt),
            .user(task.isEmpty ? "Please execute the action." : task),
        ]

        var summary = ""
        var successfulOutputs: [String] = []
        // Resources the delegated action PRODUCED, aggregated across inner steps and
        // surfaced to the MAIN agent in this loop's result — otherwise the ACT
        // summary would swallow them and the orchestrator would never see the
        // produced attachment/output handles (the unified resource-manifest flow).
        var producedResources: [Any] = []
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
            // Any staged-file handles the orchestrator relayed for this
            // delegation ride along on every proxy call this loop makes.
            let executions = try await executeAgentToolCalls(
                turn.toolCalls,
                runtimeCatalog: runtimeCatalog,
                promptMessageID: nil,
                context: context,
                agentTurnID: agentTurnID,
                agentIntention: task,
                inputHandles: inputHandles,
                outputHandles: outputHandles
            )
            actLog(
                "action-result action=\(actionID.uuidString.lowercased()) calls=\(turn.toolCalls.map(\.name).joined(separator: ",")) payload=\(actExecutionPreview(executions, source: stub.kind))"
            )
            for exec in executions {
                actTranscript.append(contentsOf: exec.messages)
            }
            // Aggregate any `produced_resources` the inner action results carry, so
            // they reach the main agent through this loop's result instead of being
            // lost in the prose summary.
            for exec in executions {
                guard let resultText = ACTAgentResultExtractor.text(from: exec.messages),
                    let data = resultText.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let resources = json["produced_resources"] as? [[String: Any]]
                else { continue }
                producedResources.append(contentsOf: resources)
            }

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
                if !resultText.isEmpty, !ACTAgentResultExtractor.isError(from: exec.messages) {
                    successfulOutputs.append(resultText)
                }
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
            "final-result action=\(actionID.uuidString.lowercased()) successful_calls=\(successfulOutputs.count) summary=\(clipped(summary, maxCharacters: 240))"
        )

        var payload: [String: Any] = [
            "ok": true,
            "action_id": actionID.uuidString.lowercased(),
            "act_result": summary,
        ]
        if !successfulOutputs.isEmpty {
            payload["act_output"] = successfulOutputs.joined(separator: "\n\n---\n\n")
        }
        // Surface produced resources (attachments / outputs) to the main agent in
        // the unified resource-manifest format — the same `produced_resources`
        // vocabulary direct tool calls and the context-attachment listing use.
        if !producedResources.isEmpty {
            payload["produced_resources"] = producedResources
        }
        return [
            toolMessage(
                payload: jsonString(payload),
                toolCallID: toolCallID
            )
        ]
    }

    // MARK: - Helpers

    /// Renders the resource handles relayed for THIS delegation into a prompt
    /// block, so the ACT agent actually KNOWS which handles it holds — otherwise
    /// they ride along as an invisible side-channel and the agent can't reference
    /// them (to fill a tool's file argument, or as `$KT_…` in a shell command).
    /// Each line carries the canonical `KT_<KIND>_<HEX>` handle and, when
    /// resolvable, the filename. Returns "" when no handles were relayed.
    private func describeDelegatedInputResources(
        _ handles: [(kind: KTResourceManifest.Kind?, id: UUID)],
        in context: KeepTalkingContext
    ) async -> String {
        guard !handles.isEmpty else { return "" }
        let contextID = try? context.requireID()
        var lines: [String] = []
        for handle in handles {
            let token =
                handle.kind.map { KTResourceManifest.agentHandle(kind: $0, id: handle.id) }
                ?? handle.id.uuidString.lowercased()
            var name: String?
            if handle.kind == .attachment || handle.kind == nil, let contextID {
                name = (try? await contextAttachment(handle.id, in: contextID))?.filename
            }
            if name == nil, handle.kind == .otb || handle.kind == nil {
                name = await stagedFileStore.file(
                    handle: handle.id, callerNodeID: config.node)?.filename
            }
            lines.append(name.map { "- \(token) — \"\($0)\"" } ?? "- \(token)")
        }
        return """

            Resources provided for this run — the file(s) the task refers to. Reference each
            by its HANDLE (the handle IS the file): pass it verbatim as a tool's file
            argument, or use it in $-form as the path in a shell command (e.g. "$\(handles.first.flatMap { h in h.kind.map { KTResourceManifest.agentHandle(kind: $0, id: h.id) } } ?? "KT_…")").
            \(lines.joined(separator: "\n"))
            """
    }

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

            case .acp:
                // The callable ACP tool def (single `prompt` arg) is already in
                // the runtime catalog; expose it like a primitive.
                let definitions = runtimeCatalog.catalog.definitions
                    .filter { $0.actionID == actionID }
                return .init(tools: definitions, promptContext: "")
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
            tools = await filesystemActionManager.availableTools(bundle: bundle, scope: .all)
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
    /// Returns true when the tool-role message in `messages` carries a failure
    /// payload. Detects JSON payloads via `"ok":false` and script-result blocks
    /// via a non-zero `exit_code`. Defaults to false (success) for formats that
    /// can't be parsed, so non-JSON tool results are never silently dropped.
    static func isError(from messages: [AIMessage]) -> Bool {
        for message in messages where message.role == .tool {
            let text: String
            if case .text(let str)? = message.content {
                text = str
            } else {
                text = message.content?.text ?? ""
            }
            guard !text.isEmpty else { continue }

            if let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = json["ok"] as? Bool
            {
                return !ok
            }
            // Script result block emitted by SkillManager.executeRunScript
            if text.hasPrefix("command:") || text.contains("\nexit_code:") {
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("exit_code:"),
                        let codeStr = trimmed.dropFirst("exit_code:".count)
                            .trimmingCharacters(in: .whitespaces)
                            .split(separator: " ").first,
                        let code = Int(codeStr)
                    {
                        return code != 0
                    }
                }
            }
            return false
        }
        return false
    }

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
