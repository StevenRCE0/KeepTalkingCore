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
                concise summary of the result.

                Resource handles (`KT_<KIND>_<HEX>`) are the single vocabulary for
                every file. Two kinds exist:
                - `KT_ATTACHMENT_<HEX>`: durable, shared context attachment.
                - `KT_OTB_<HEX>`: private, ephemeral one-time blob (from
                  `kt_send_file` or a prior `produced_resources` entry with
                  persistence=otb). NOT retrievable via attachment tools.

                To feed a file INTO the action: pass its handle in
                `input_handles` here. This is the ONLY way an action receives a
                file — it cannot see this conversation's attachments, so a file
                the user attached does not reach it unless you pass the handle.
                For a file already attached here, look up its
                `KT_ATTACHMENT_<HEX>` handle in the context attachment listing.
                For a local file you hold, stage it on the action's owner node
                with `kt_send_file` (returns a `KT_OTB_<HEX>` handle); that
                handle resolves only on the node you staged it to.

                To capture a file the action PRODUCES: request it in `outputs`.
                Each entry needs a `name` and a `persistence`:
                - `otb` (private): delivered only to you as a `KT_OTB_<HEX>`
                  handle. Default for intermediate files.
                - `attachment` (shared): becomes a durable context attachment
                  (`KT_ATTACHMENT_<HEX>`), visible to all participants.
                The inner skill/action receives an exact `$KT_...` write
                variable for each requested output. After the call returns, its
                result carries a `produced_resources` array listing each produced
                file by handle, and the bytes are injected into your next turn
                automatically — do NOT call any tool to fetch them. The handle is
                the stable identity to mention or pass to a later action.
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
                            "Resource handles to deliver as the action's file input. REQUIRED whenever the chosen action's `objects:` line lists a file `in` — that input is never filled implicitly, and the action cannot see this conversation's attachments, so omitting the handle makes the call fail with \"could not resolve its SOURCE\". For a file already attached to this conversation, get its KT_ATTACHMENT_<HEX> handle from the context attachment listing first. For a local file you hold, stage it with kt_send_file (returns KT_OTB_<HEX>) — only handles staged on this action's owner node resolve."
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
                                        "otb = private, ephemeral, delivered only to you as a KT_OTB_<HEX> handle (default; use for intermediate files you'll feed into a later action). attachment = durable, shared context attachment (KT_ATTACHMENT_<HEX>), visible to all participants via attachment tools (use only for a shared, durable artifact)."
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

    /// Display name for an action id, for disambiguation messages.
    static func stubName(_ id: UUID, in catalog: KeepTalkingActionRuntimeCatalog) -> String {
        catalog.actionStubs.first { $0.actionID == id }?.name ?? "(unknown)"
    }

    /// The `unknown_action_id` reply. A bare error string is a dead end — the
    /// agent cannot tell a typo from a vanished action, and has been known to
    /// conclude the host crashed — so hand back the roster for self-correction.
    private func unknownActionReply(
        _ actionToken: String,
        toolCallID: String,
        in runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) -> AIMessage {
        toolMessage(
            payload: jsonString([
                "ok": false,
                "error": "unknown_action_id",
                "action_id": actionToken,
                "hint": "No action matches that name, and it is not close "
                    + "enough to one to guess. Copy an `action:` value from "
                    + "available_actions exactly. Do NOT conclude the action "
                    + "or its host is unavailable — this is a naming miss.",
                "available_actions": runtimeCatalog.actionStubs.prefix(40).map {
                    ["action": $0.actionID.friendlyNameToken, "name": $0.name]
                },
            ]),
            toolCallID: toolCallID
        )
    }

    /// Executes a `kt_run_action` tool call by running the ACT agent mini-loop.
    func executeRunActionToolCall(
        toolCallID: String,
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext,
        actConnector: any AIConnector,
        actModel: String,
        publisher: AIOrchestrator.ToolHintPublisher,
        agentTurnID: UUID? = nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
    ) async throws -> [AIMessage] {
        let args = try decodeToolArguments(rawArguments)

        guard let actionToken = args["action_id"]?.stringValue else {
            return [
                toolMessage(
                    payload: jsonString(["ok": false, "error": "missing_or_invalid_action_id"]),
                    toolCallID: toolCallID
                )
            ]
        }

        // The agent references actions by their word-name (`amber-swift-koala`),
        // and a raw UUID still works. Resolution repairs a single mistyped word;
        // it never repairs hex, which has no redundancy to repair from.
        let candidates = runtimeCatalog.actionStubs.map(\.actionID)
        let resolution = UUIDFriendlyName.resolve(actionToken, among: candidates)
        let actionID: UUID
        switch resolution {
            case .resolved(let id):
                actionID = id
            case .corrected(let id, let from, let to):
                actionID = id
                onLog?("[act/action-id] repaired '\(from)' -> '\(to)'")
            case .ambiguous(let ids):
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": false,
                            "error": "ambiguous_action_id",
                            "action_id": actionToken,
                            "candidates": ids.map {
                                ["action": $0.friendlyNameToken, "name": Self.stubName($0, in: runtimeCatalog)]
                            },
                            "hint": "More than one action matches. Retry with one of the "
                                + "candidate names exactly.",
                        ]),
                        toolCallID: toolCallID
                    )
                ]
            case .unknown:
                return [unknownActionReply(actionToken, toolCallID: toolCallID, in: runtimeCatalog)]
        }

        // `resolve(_:among:)` only returns ids drawn from `candidates`, so this
        // lookup is total; the fallback shares the `.unknown` reply so even a
        // future desynchronisation cannot regress to a bare dead-end error.
        guard
            let stub = runtimeCatalog.actionStubs.first(where: { $0.actionID == actionID })
        else {
            return [unknownActionReply(actionToken, toolCallID: toolCallID, in: runtimeCatalog)]
        }

        let task = args["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Keep the resolved (kind, id) — not just the bare UUID — so the ACT agent
        // can be TOLD which canonical handles it holds (the bare-UUID side-channel
        // alone left the agent blind to its own handles).
        let suppliedHandles = args["input_handles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        // A friendly name — or a repairable hex near-miss — only becomes an id
        // against the handles that actually exist, so the caller-scoped staged
        // set is fetched once, lazily: the common calls (no input handles, or
        // exact non-OTB handles) skip the actor hop and its reap scan.
        var stagedHandles: [UUID]?
        func ownedHandles() async -> [UUID] {
            if let stagedHandles { return stagedHandles }
            let owned = await stagedFileStore.handles(forCaller: config.node)
            stagedHandles = owned
            return owned
        }
        // ONE resolution per handle, settled once: the resolved list, the
        // repair log, and the failure report all derive from the same outcome
        // and cannot disagree. A handle that does not resolve used to be
        // dropped here in silence: the action then ran without its input and
        // failed further downstream with "could not resolve its SOURCE", which
        // tells the agent nothing about the handle it actually mistyped. Say
        // so plainly instead — with a per-handle reason, because "re-copy it
        // exactly" is the wrong advice for an ambiguous name.
        var resolvedInputHandles: [(kind: KTResourceManifest.Kind?, id: UUID)] = []
        var unresolvedHandles: [[String: String]] = []
        func settle(
            _ resolution: KTResourceManifest.Resolution,
            supplied: String,
            kind: KTResourceManifest.Kind?,
            whenUnknown problem: String,
            hint: String
        ) {
            switch resolution {
                case .resolved(let id):
                    resolvedInputHandles.append((kind, id))
                case .corrected(let id, let from, let to):
                    onLog?("[act/input-handle] repaired '\(from)' -> '\(to)'")
                    resolvedInputHandles.append((kind, id))
                case .ambiguous(let ids):
                    unresolvedHandles.append([
                        "handle": supplied,
                        "problem": "ambiguous",
                        "candidates": ids.map(\.friendlyNameToken).joined(separator: ", "),
                        "hint": "More than one staged file plausibly matches. Retry with "
                            + "one of the candidates exactly.",
                    ])
                case .unknown:
                    unresolvedHandles.append([
                        "handle": supplied, "problem": problem, "hint": hint,
                    ])
            }
        }
        for supplied in suppliedHandles {
            let direct = KTResourceManifest.resolveAgentHandle(supplied)
            if let direct, direct.kind != .otb {
                // Attachment handles and bare UUIDs resolve in universes the
                // staged store does not hold — they pass through as before.
                resolvedInputHandles.append(direct)
            } else if direct != nil {
                // A parsed OTB handle claims caller-staged bytes: resolve it
                // against the handles that exist, repairing a single mistyped
                // hex character — a substitution typo still parses as a
                // well-formed id for something that was never staged.
                settle(
                    KTResourceManifest.resolveAgentHandle(supplied, among: await ownedHandles()),
                    supplied: supplied,
                    kind: .otb,
                    whenUnknown: "not_staged",
                    hint: "Well-formed, but no file staged on this node matches — "
                        + "stale, already consumed, or mistyped. Re-stage the file "
                        + "with kt_send_file, or re-copy the handle from the "
                        + "produced_resources of the call that created it.")
            } else {
                // Not a handle — a friendly name, or a handle mangled past
                // parsing (dropped/extra character), which hex repair recovers.
                var resolution = UUIDFriendlyName.resolve(supplied, among: await ownedHandles())
                if case .unknown = resolution {
                    resolution = KTResourceManifest.resolveAgentHandle(
                        supplied, among: await ownedHandles())
                }
                settle(
                    resolution,
                    supplied: supplied,
                    kind: nil,
                    whenUnknown: "unrecognized",
                    hint: "Not a resource handle. A handle looks like KT_OTB_<32 hex> "
                        + "or KT_ATTACHMENT_<32 hex>, or the three-word `friendly` name "
                        + "shown beside it — either works, but it must be copied exactly "
                        + "from the resource that produced it. It is not a filename and "
                        + "not a path. Re-read the produced_resources of the call that "
                        + "created the file, or the context attachment listing, and copy "
                        + "one of those two forms.")
            }
        }
        let inputHandles = resolvedInputHandles.map(\.id)
        if !unresolvedHandles.isEmpty {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "error": "unresolvable_input_handles",
                        "handles": unresolvedHandles,
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }
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
            outputHandles: outputHandles,
            assistantPublisher: assistantPublisher,
            toolHintPublisher: toolHintPublisher
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
        publisher: AIOrchestrator.ToolHintPublisher,
        agentTurnID: UUID? = nil,
        inputHandles: [UUID]? = nil,
        resolvedInputHandles: [(kind: KTResourceManifest.Kind?, id: UUID)] = [],
        outputHandles: [KeepTalkingActionOutputHandle]? = nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
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

            Sandbox & resource handles:
            You execute inside a SANDBOX. The outside world reaches you only through the
            resource handles provisioned for this run — every `KT_<KIND>_<HEX>` handle is
            an environment variable whose VALUE is that file's real absolute path on this
            host. Handles are the ONLY reliable bridge between you and any file the caller
            staged, any attachment the user provided, and any output slot you must fill.
            - Prefer handles over every other path form. When a tool or script argument
              needs a file, pass the handle in its $-form (e.g. `"$KT_ATTACHMENT_<HEX>"`,
              always quoted) — the shell expands it to the real path for you.
            - Never hardcode, guess, or fabricate an absolute filesystem path. The sandbox
              layout is not stable across runs and you cannot discover paths by reasoning.
            - Never invent a handle that was not provided in the resources block or output
              slots above. If a file you need is not represented by a handle, you do not
              have access to it — say so rather than guessing a path.
            - To RETURN a file to the caller, write it to an output-slot variable
              (`$KT_<KIND>_<HEX>` from the outputs block), not to an arbitrary path. A
              file written anywhere else is invisible to the caller and will be lost.

            Privacy and confidentiality: Do not disclose, summarize, or infer the user's environment in user-facing answers, including local machine or system state, filesystem paths, connected devices or nodes, credentials or configuration, screen contents, network details, or other ambient context. This applies especially to ACT agents, which may encounter such context while executing actions. You may disclose only information contained in explicitly provided or returned resources, information necessary to complete or accurately report the requested action, or information the node owner or action description explicitly authorizes or asks you to disclose.

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
                outputHandles: outputHandles,
                assistantPublisher: assistantPublisher,
                toolHintPublisher: toolHintPublisher
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
            let friendly = handle.id.friendlyName
            lines.append(
                name.map { "- \(token)  (\(friendly)) — \"\($0)\"" }
                    ?? "- \(token)  (\(friendly))")
        }
        return """

            Resources provided for this run — the file(s) the task refers to. Reference each
            by its HANDLE (the handle IS the file): pass it verbatim as a tool's file
            argument, or use it in $-form as the path in a shell command. The name in
            parentheses is the same resource and is accepted wherever the handle is —
            copy whichever you can reproduce exactly (e.g. "$\(handles.first.flatMap { h in h.kind.map { KTResourceManifest.agentHandle(kind: $0, id: h.id) } } ?? "KT_…")").
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

            case .plugin:
                return try await resolvedACTPluginAction(
                    actionID: actionID,
                    stub: stub,
                    runtimeCatalog: runtimeCatalog,
                    context: context
                )

            case .acp:
                // Its callable tool def is already in the runtime catalog;
                // expose it like a primitive.
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

    /// Hydrates a Catalogue instance's tool definition at inspection time.
    ///
    /// A LOCAL instance is already schema-complete: the runtime catalog read
    /// its kind's `inputSchema` straight off the connected plugin host. A
    /// REMOTE one cannot be — the kind's schema is deliberately not advertised
    /// (it would bloat every status envelope and go stale between
    /// advertisements), so the catalog could only register the permissive
    /// parameter shape. This is where the real declaration is fetched, on
    /// demand, from the node that actually holds the plugin: the `pluginKind`
    /// twin of the `mcpTools` query.
    private func resolvedACTPluginAction(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> ACTResolvedAction {
        let catalogDefinitions = runtimeCatalog.catalog.definitions
            .filter { $0.actionID == actionID }

        guard !stub.isCurrentNode else {
            return .init(tools: catalogDefinitions, promptContext: "")
        }
        guard
            let action = try await KeepTalkingAction.find(
                actionID,
                on: localStore.database
            ),
            case .plugin(let bundle) = action.payload
        else {
            return .init(tools: catalogDefinitions, promptContext: "")
        }

        actLog(
            "outgoing-request action=\(actionID.uuidString.lowercased()) kind=plugin_kind target=\(stub.ownerNodeID.uuidString.lowercased())"
        )
        let result = try await dispatchActionCatalogRequest(
            targetNodeID: stub.ownerNodeID,
            queries: [
                KeepTalkingActionCatalogQuery(
                    actionID: actionID,
                    kind: .pluginKind
                )
            ],
            context: context
        )
        guard
            let item = result.items.first(where: {
                $0.actionID == actionID && $0.kind == .pluginKind
            }),
            !item.isError,
            let remoteKind = item.pluginKind
        else {
            // Owner could not answer — plugin forgotten, grant narrowed, or a
            // build without this query. Keep the permissive definition rather
            // than dropping the tool: the call still routes, and the owner is
            // the node that validates arguments anyway.
            actLog(
                "incoming-schema action=\(actionID.uuidString.lowercased()) source=remote_plugin result=unavailable"
            )
            return .init(tools: catalogDefinitions, promptContext: "")
        }

        // A pinned instance answers to its sub-tool's schema; an unpinned one
        // to the kind's own.
        let schema =
            bundle.tool.flatMap { pinned in
                remoteKind.declaration.subTools?
                    .first { $0.name == pinned }?.inputSchema
            } ?? remoteKind.declaration.inputSchema
        actLog(
            "incoming-schema action=\(actionID.uuidString.lowercased()) source=remote_plugin kind=\(remoteKind.declaration.kindName) available=\(remoteKind.isAvailable)"
        )

        let definitions = [
            makePluginActionProxyDefinition(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle,
                descriptor: action.descriptor,
                inputSchema: schema.flatMap {
                    KeepTalkingActionToolDefinition.jsonSchema(from: $0)
                },
                supportsWakeAssist: action.blockingAuthorisation == true
            )
        ]
        await cacheACTHydratedDefinitions(
            definitions,
            for: actionID,
            runtimeCatalog: runtimeCatalog
        )
        return .init(tools: definitions, promptContext: "")
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
        publisher: AIOrchestrator.ToolHintPublisher,
        parentActionName: String,
        params: [String: String]
    ) async throws {
        try await publisher(
            parentActionName,
            .intermediate(
                hint: "Output",
                targetNodeID: nil,
                actionID: nil,
                actionName: parentActionName,
                sealedParameters: nil
            ),
            params
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
