import AIProxy
import FluentKit
import Foundation
import MCP

private struct KeepTalkingQueuedPromptPreparationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

extension KeepTalkingClient {
    static let ktSkillMetainfoToolFunctionName = "kt_skill_metainfo"
    static let contextAttachmentListingToolFunctionName =
        "kt_list_context_attachments"
    static let resourceReadToolFunctionName =
        "kt_get_resource"
    static let markTurningPointToolFunctionName = "kt_mark_turning_point"
    static let markChitterChatterToolFunctionName = "kt_mark_chitter_chatter"
    static let contextAttachmentUpdateMetadataToolFunctionName =
        "kt_update_context_attachment_metadata"
    static let searchThreadsToolFunctionName = "kt_search_threads"
    static let createActionToolFunctionName = "kt_create_action"
    static let evaluateJSToolFunctionName = "kt_evaluate_js"
    /// Function name used for web search in chat-completions mode (e.g. OpenRouter).
    /// In Responses API mode the built-in webSearchPreview tool is used instead.
    static let updateSideNoteToolFunctionName = "kt_update_side_note"
    static let archiveSideNoteToolFunctionName = "kt_archive_side_note"
    static let sendFileToolFunctionName = "kt_send_file"
    static let webSearchFunctionName = "web_search"
    static let maxAgentTurns = 32
    static let maxAINativeAttachmentBytes = 8 * 1024 * 1024
    static let skillManifestPreviewMaxCharacters = 20_000
    static let skillFileMaxCharacters = 30_000

    // MARK: - Queued entry point

    /// Enqueues an AI prompt for `contextID`.  The prompt message is sent to
    /// chat only when the run actually starts (dequeues), so queued prompts
    /// are invisible in chat until it is their turn.
    ///
    /// Returns the stable run ID that can be passed to `cancelAgentRun(_:)`.
    @discardableResult
    public func enqueueAIPrompt(
        _ prompt: String,
        attachments: [KeepTalkingLocalAttachmentInput] = [],
        in contextID: UUID,
        model: String = "gpt-5-codex",
        actModel: String? = nil,
        roleName: String = "ai",
        reasoningEffort: AIReasoning.Effort? = nil
    ) async -> UUID {
        let context = KeepTalkingContext(id: contextID)
        let preview = String(prompt.prefix(120))
        let preparedAttachmentsResult:
            Result<
                [KeepTalkingPreparedAttachment], KeepTalkingQueuedPromptPreparationError
            >
        do {
            preparedAttachmentsResult = .success(
                try await prepareLocalAttachments(attachments)
            )
        } catch {
            preparedAttachmentsResult = .failure(
                KeepTalkingQueuedPromptPreparationError(
                    message: error.localizedDescription
                )
            )
        }

        let agentTurnID = UUID()

        // The "AI-only" closure used by both the initial run (after we send
        // the user prompt) and by retry (where the prompt is already in chat
        // from the first attempt). Captures parameters so it stays callable
        // after the failed entry has been parked.
        let runAIClosure: @Sendable () async throws -> Void = {
            [self, preparedAttachmentsResult] in
            try Task.checkCancellation()
            let preparedAttachments = try preparedAttachmentsResult.get()
            try Task.checkCancellation()
            _ = try await runAI(
                prompt: prompt,
                in: context,
                model: model,
                actModel: actModel,
                roleName: roleName,
                preparedPromptAttachments: preparedAttachments,
                agentTurnID: agentTurnID,
                reasoningEffort: reasoningEffort
            )
        }

        let work: @Sendable () async throws -> Void = { [self, preparedAttachmentsResult] in
            try Task.checkCancellation()
            let preparedAttachments = try preparedAttachmentsResult.get()
            try Task.checkCancellation()
            // Tag the user's prompt message with this run's `agentTurnID` so
            // the UI can identify it as an AI prompt and apply the purple
            // stroke + shadow treatment — no in-band "@AI " text marker.
            try await persistAndBroadcastMessage(
                prompt,
                preparedAttachments: preparedAttachments,
                in: context,
                agentTurnID: agentTurnID
            )
            try await runAIClosure()
        }

        return await agentCoordinator.enqueue(
            contextID: contextID,
            agentTurnID: agentTurnID,
            promptPreview: preview,
            work: work,
            retryWork: runAIClosure,
            onCompleted: { [self] error in
                if let error {
                    let errorMessage = error.localizedDescription
                    Task { [self] in
                        await publishAgentRunFailure(
                            contextID: contextID,
                            roleName: roleName,
                            model: model,
                            message: errorMessage
                        )
                    }
                }
                // Cancel any pending continuation this turn was waiting on.
                Task { [self] in
                    await cancelStaleContinuations(agentTurnID: agentTurnID, in: contextID)
                }
                onAgentRunCompleted?(contextID, error)
            }
        )
    }

    /// Cancels a queued or running agent run by ID. The queue snapshot drops
    /// the run immediately; a `.haywire(.cancelled)` marker is published into
    /// the context so the conversation has a permanent record of where the
    /// run was cancelled.
    public func cancelAgentRun(_ runID: UUID) {
        Task { [self] in
            // Resolve the contextID from the current snapshots BEFORE
            // cancelling — once we cancel, the run vanishes from snapshots.
            let snapshots = await agentCoordinator.currentSnapshots
            let contextID = snapshots.first { $0.id == runID }?.contextID
            await agentCoordinator.cancel(runID: runID)
            if let contextID {
                await publishAgentRunCancellation(contextID: contextID)
            }
        }
    }

    /// Re-runs a previously failed agent run. The user-prompt message is
    /// already in the context from the first attempt, so retry only re-runs
    /// the AI side — no duplicate user message is appended.
    public func retryAgentRun(_ runID: UUID) {
        Task { await agentCoordinator.retry(runID: runID) }
    }

    /// Removes a failed agent run from the queue (no further side effects).
    public func dismissAgentRun(_ runID: UUID) {
        Task { await agentCoordinator.dismiss(runID: runID) }
    }

    /// Executes one already-dequeued durable app queue item.
    ///
    /// Unlike `enqueueAIPrompt`, this method does not add work to the
    /// SDK's in-memory `AgentCoordinator`; callers that need persistence across
    /// navigation, app switching, or process death should own the durable
    /// queue and call this only when the item reaches the head.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text. Persisted and broadcast as the prompt
    ///     message when `sendPromptMessage` is `true`, and handed to the model
    ///     as the current user message either way.
    ///   - attachments: Local files to attach to the prompt. Each is read from
    ///     its `sourceURL` into the blob store, attached to the prompt message
    ///     row, and included in the model's user message — images inline, other
    ///     types as a text fallback. An attachment larger than
    ///     `maxAINativeAttachmentBytes` is replaced by an omission note in the
    ///     model input.
    ///   - contextID: Identifies the context the prompt message and every
    ///     message the run publishes belong to.
    ///   - model: Model identifier driving the main agent loop. Also recorded
    ///     on the `.autonomous` sender of the messages the run publishes.
    ///   - actModel: Model for the ACT sub-agent that executes `kt_run_action`
    ///     calls. When `nil`, the ACT agent reuses the main loop's active
    ///     model.
    ///   - roleName: Sender name recorded on the `.autonomous` messages the run
    ///     publishes.
    ///   - reasoningEffort: Reasoning effort forwarded to the connector through
    ///     the turn configuration. `nil` leaves the choice to the connector.
    ///   - sendPromptMessage: When `true`, the prompt and its attachments are
    ///     persisted and broadcast into the context before the run starts. Pass
    ///     `false` when the prompt message is already in the context — the call
    ///     then runs the AI side only and appends no duplicate user message.
    ///   - promptType: Message type to stamp on the prompt row. Defaults to
    ///     `.message` (a typed prompt); the voice→AI bridge passes
    ///     `.transcript(source:)` so the prompt renders as a (fainter)
    ///     transcript bubble and skips wake-notifications, while the AI still
    ///     receives the same text.
    ///   - agentTurnID: Turn identifier stamped on the prompt message and on
    ///     every message the run publishes, tying them together as one turn.
    ///     It also scopes the stale-continuation cancellation performed once the
    ///     run returns, and — when `checkpoint` is non-`nil` — excludes this
    ///     turn's already-recorded messages from the rebuilt context transcript,
    ///     since the checkpoint already carries them.
    ///   - onPromptMessageSent: Invoked after the prompt message has been
    ///     persisted and broadcast and before the AI run begins. Not invoked
    ///     when `sendPromptMessage` is `false`.
    ///   - checkpoint: Durable progress from an earlier, interrupted attempt at
    ///     this same turn. When supplied, the orchestrator resumes from it
    ///     instead of starting a fresh transcript, and returns the recorded
    ///     assistant text immediately if the checkpoint is already complete.
    ///     `nil` starts a new run.
    ///   - onCheckpoint: Invoked with an updated checkpoint each time the run
    ///     makes durable progress — after each completed tool call and at every
    ///     turn boundary — so the caller can persist it. Errors thrown from it
    ///     propagate out of this call.
    /// - Returns: The agent run's final assistant text, so callers (e.g. the
    ///   voice bridge) can speak the reply. Empty string if the run produced
    ///   no text.
    /// - Throws: `CancellationError` if the surrounding task is cancelled
    ///   before or between phases, `KeepTalkingClientError.aiNotConfigured`
    ///   when no AI connector is configured, or any error raised while reading
    ///   and storing `attachments`, publishing the prompt message, or running
    ///   the agent loop.
    @discardableResult
    public func runDequeuedAIPrompt(
        _ prompt: String,
        attachments: [KeepTalkingLocalAttachmentInput] = [],
        in contextID: UUID,
        model: String = "gpt-5-codex",
        actModel: String? = nil,
        roleName: String = "ai",
        reasoningEffort: AIReasoning.Effort? = nil,
        sendPromptMessage: Bool = true,
        promptType: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID = UUID(),
        onPromptMessageSent: (@Sendable () async -> Void)? = nil,
        checkpoint: AIAgentCheckpoint? = nil,
        onCheckpoint: (@Sendable (AIAgentCheckpoint) async throws -> Void)? = nil
    ) async throws -> String {
        let context = KeepTalkingContext(id: contextID)
        let preparedAttachments = try await prepareLocalAttachments(attachments)
        try Task.checkCancellation()
        if sendPromptMessage {
            try await persistAndBroadcastMessage(
                prompt,
                preparedAttachments: preparedAttachments,
                in: context,
                type: promptType,
                agentTurnID: agentTurnID
            )
            await onPromptMessageSent?()
        }
        try Task.checkCancellation()
        let result = try await runAI(
            prompt: prompt,
            in: context,
            model: model,
            actModel: actModel,
            roleName: roleName,
            preparedPromptAttachments: preparedAttachments,
            agentTurnID: agentTurnID,
            reasoningEffort: reasoningEffort,
            checkpoint: checkpoint,
            onCheckpoint: onCheckpoint
        )
        await cancelStaleContinuations(agentTurnID: agentTurnID, in: contextID)
        return result
    }

    // MARK: - Direct execution (CLI / internal)

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: String = "gpt-5-codex",
        actModel: String? = nil,
        roleName: String = "ai",
        currentPromptAttachments: [KeepTalkingLocalAttachmentInput] = []
    ) async throws -> String {
        let preparedPromptAttachments = try await prepareLocalAttachments(
            currentPromptAttachments
        )
        return try await runAI(
            prompt: prompt,
            in: context,
            model: model,
            actModel: actModel,
            roleName: roleName,
            preparedPromptAttachments: preparedPromptAttachments
        )
    }

    private func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: String,
        actModel: String?,
        roleName: String,
        preparedPromptAttachments: [KeepTalkingPreparedAttachment],
        agentTurnID: UUID = UUID(),
        reasoningEffort: AIReasoning.Effort? = nil,
        checkpoint: AIAgentCheckpoint? = nil,
        onCheckpoint: ((AIAgentCheckpoint) async throws -> Void)? = nil
    ) async throws -> String {
        guard let aiConnector = try await resolveAIConnector() else {
            throw KeepTalkingClientError.aiNotConfigured
        }
        // The ACT sub-agent may target a different provider/endpoint than the
        // main agent; resolve its connector independently (falls back to the
        // main connector when no ACT-specific provider is configured).
        let actConnector = (try await resolveACTConnector()) ?? aiConnector

        await ensureMCPToolChangeObserverInstalled()

        let persistedContext = try await upsertContext(context)

        // Snapshot the latest message ID now (= user's prompt) before the AI
        // publishes any response messages.  Passed into the tool executors so
        // annotation tools act on the prompt, not the AI's own reply.
        let taggedPromptMessageID: UUID? = try? await KeepTalkingContextMessage
            .query(on: localStore.database)
            .filter(\.$context.$id == (try persistedContext.requireID()))
            .filter(\.$agentTurnID, .equal, agentTurnID)
            .sort(\.$timestamp, .ascending)
            .first()?.id
        let latestMessageID: UUID? = try? await KeepTalkingContextMessage
            .query(on: localStore.database)
            .filter(\.$context.$id == (try persistedContext.requireID()))
            .sort(\.$timestamp, .descending)
            .first()?.id
        let promptMessageID = taggedPromptMessageID ?? latestMessageID

        let runtimeCatalog = try await resolveActionRuntimeCatalog(
            in: persistedContext
        )
        onLog?(
            "[ai] catalog has \(runtimeCatalog.catalog.definitions.count) tool proxy definition(s)"
        )

        // TODO: be able to switch off in the configurations
        let webSearchTool = Self.makeWebSearchTool()
        let ktSkillMetainfoTool = makeKtSkillMetainfoTool()
        let attachmentListingTool = makeContextAttachmentListingTool()
        let attachmentReadTool = makeResourceReadTool()
        let markTurningPointTool = makeMarkTurningPointTool()
        let markChitterChatterTool = makeMarkChitterChatterTool()
        let attachmentUpdateMetadataTool =
            makeContextAttachmentUpdateMetadataTool()
        let searchThreadsTool = makeSearchThreadsTool()
        let createActionTool = makeCreateActionTool()
        let evaluateJSTool = makeEvaluateJSTool()

        // Layer 0: meta tools + primitives (static schemas, no server I/O).
        // kt_run_action is always available — the ACT agent handles action execution
        // end-to-end (tool discovery, argument construction, execution, distillation).
        // The primary loop does not receive direct action tools.
        let allTools: [KeepTalkingActionToolDefinition] = [
            Self.makeRunActionTool(),
            ktSkillMetainfoTool,
            attachmentListingTool,
            attachmentReadTool,
            attachmentUpdateMetadataTool,
            searchThreadsTool,
            createActionTool,
            evaluateJSTool,
            webSearchTool,
            markTurningPointTool,
            markChitterChatterTool,
            makeUpdateSideNoteTool(),
            makeArchiveSideNoteTool(),
            makeSendFileTool(),
        ]
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: runtimeCatalog.routesByFunctionName
        )
        let aliasLookup = try await aliasLookup()
            .scoped(to: try persistedContext.requireID())
        let contextTranscript = try await agentContextTranscript(
            persistedContext,
            actionStubs: runtimeCatalog.actionStubs
        )
        let contextMessages = try await agentContextMessages(
            persistedContext,
            excludingMessageID: promptMessageID,
            excludingAgentTurnID: checkpoint == nil ? nil : agentTurnID
        )
        let hasCurrentPromptAttachments = !preparedPromptAttachments.isEmpty
        let allowAutomaticToolUse = Self.shouldAllowAutomaticToolUse(
            prompt: prompt,
            hasCurrentPromptAttachments: hasCurrentPromptAttachments
        )
        let userMessage = try await currentPromptUserMessage(
            prompt: prompt,
            attachments: preparedPromptAttachments
        )

        logInjectedAITools(
            runtimeCatalog: runtimeCatalog,
            allCompletionTools: allTools,
            context: persistedContext,
            model: model
        )

        // Local wall-clock + timezone (not bare UTC ISO-8601, which misreports
        // "now" for the user's locale). Shared with the audio bridge so both
        // agents agree on the current time.
        let currentDate = KeepTalkingEnvironmentContext.localDateTimeDescription()
        let platform = KeepTalkingEnvironmentContext.platform

        let activeSideNotes =
            (try? await persistedContext.$sideNotes
                .query(on: localStore.database)
                .filter(\.$isArchived == false)
                .all()
                .map(KeepTalkingSideNoteDTO.init)) ?? []

        let systemPrompt = OpenAIConnector.keepTalkingSystemPrompt(
            ktRunActionToolFunctionName: Self.runActionToolFunctionName,
            ktSkillMetainfoToolFunctionName: Self.ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName: Self.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName: Self.resourceReadToolFunctionName,
            searchThreadsToolFunctionName: Self.searchThreadsToolFunctionName,
            markTurningPointToolFunctionName: Self.markTurningPointToolFunctionName,
            markChitterChatterToolFunctionName: Self.markChitterChatterToolFunctionName,
            currentPromptIncludesAttachments: hasCurrentPromptAttachments,
            currentPromptShouldAvoidAutomaticToolUse: hasCurrentPromptAttachments
                && !allowAutomaticToolUse,
            sideNotes: activeSideNotes,
            contextTranscript: contextTranscript,
            currentDate: currentDate,
            platform: platform,
            responseLanguages: responseLanguages
        )
        let messages: [AIMessage] =
            [AIMessage.system(systemPrompt)] + contextMessages + [userMessage]

        let assistantPublisher: AIOrchestrator.AssistantPublisher = { [self] payload in
            let (assistantText, messageType, speaker) = payload
            // A named speaker is a collaborating agent talking, not this
            // assistant — so it is not attributed to this assistant's model.
            try await send(
                assistantText,
                in: persistedContext,
                sender: .autonomous(
                    name: speaker ?? roleName,
                    node: config.node,
                    model: speaker == nil ? model : nil
                ),
                type: messageType,
                agentTurnID: agentTurnID,
                emitLocalEnvelope: true
            )
        }

        // The one place tool-call arguments get sealed before they become a
        // context message. The row's own `targetNodeID` names the recipient —
        // the peer being asked to run the thing — so caller and callee can open
        // it and the rest of the context sees the hint without the arguments.
        // A nil target is a built-in or local tool: sealed to this node, where
        // both ends of the call are us.
        let toolHintPublisher: AIOrchestrator.ToolHintPublisher = {
            [self] name, messageType, parameters in
            var sealedType = messageType
            if case .intermediate(let hint, let targetNodeID, let actionID, let actionName, _) =
                messageType,
                let parameters,
                !parameters.isEmpty
            {
                sealedType = .intermediate(
                    hint: hint,
                    targetNodeID: targetNodeID,
                    actionID: actionID,
                    actionName: actionName,
                    sealedParameters: await sealCallParameters(
                        parameters,
                        for: targetNodeID
                    )
                )
            }
            try await assistantPublisher((name, sealedType, nil))
        }

        let actAgent = AIOrchestrator.ACTAgent(
            canHandle: { $0.name == Self.runActionToolFunctionName },
            execute: { [self] toolCalls, activeModel in
                var executions: [AIOrchestrator.ToolExecution] = []
                for toolCall in toolCalls {
                    let toolCallID =
                        toolCall.id.isEmpty
                        ? UUID().uuidString.lowercased()
                        : toolCall.id
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: try await executeRunActionToolCall(
                                toolCallID: toolCallID,
                                rawArguments: toolCall.argumentsJSON,
                                runtimeCatalog: runtimeCatalog,
                                context: persistedContext,
                                actConnector: actConnector,
                                actModel: actModel ?? activeModel,
                                publisher: toolHintPublisher,
                                agentTurnID: agentTurnID,
                                assistantPublisher: assistantPublisher,
                                toolHintPublisher: toolHintPublisher
                            )
                        )
                    )
                }
                return executions
            }
        )

        let turnConfiguration = AITurnConfiguration(
            reasoning: reasoningEffort.map { AIReasoning(effort: $0) }
        )
        let orchestrator = AIOrchestrator(
            dependencies: .init(
                aiConnector: aiConnector,
                turnRunner: { [aiConnector] messages, tools, model, toolChoice, stage, configuration in
                    try await aiConnector.completeTurn(
                        messages: messages,
                        tools: tools,
                        model: model,
                        toolChoice: toolChoice,
                        stage: stage,
                        configuration: configuration,
                        toolExecutor: nil
                    )
                },
                assistantMessageBuilder: { [self] turn in
                    assistantMessage(from: turn)
                },
                toolExecutor: { [self] toolCalls in
                    try await executeAgentToolCalls(
                        toolCalls,
                        runtimeCatalog: runtimeCatalog,
                        promptMessageID: promptMessageID,
                        context: persistedContext,
                        agentTurnID: agentTurnID,
                        agentIntention: prompt,
                        assistantPublisher: assistantPublisher,
                        toolHintPublisher: toolHintPublisher
                    )
                },
                toolTranscriptAdapter: { [self] executions in
                    // Auto-inject produced resources (attachment/otb) so a file the
                    // agent just requested — e.g. via ask-for-file — is CONSUMED this
                    // turn, not handed back as a handle to optionally pull in later.
                    await KeepTalkingIOManager(client: self)
                        .transcriptMessagesForProducedResources(
                            from: executions, context: persistedContext)
                },
                actAgent: actAgent,
                assistantPublisher: assistantPublisher,
                toolHintPublisher: toolHintPublisher,
                toolNameResolver: { [self] toolCall in
                    publishedToolName(
                        for: toolCall,
                        runtimeCatalog: runtimeCatalog,
                        skillNameByActionID: skillNameByActionID,
                        aliasLookup: aliasLookup
                    )
                },
                toolHintResolver: { [self] toolCall, stage in
                    guard var ctx = publishedToolHint(for: toolCall, stage: stage) else {
                        return nil
                    }
                    // Patch actionName from the catalog stub when we have an actionID.
                    if let actionID = ctx.actionID,
                        let stub = runtimeCatalog.actionStubs.first(where: { $0.actionID == actionID })
                    {
                        ctx = .init(
                            hint: ctx.hint,
                            targetNodeID: ctx.targetNodeID ?? stub.ownerNodeID,
                            actionID: ctx.actionID,
                            actionName: stub.name,
                            parameters: ctx.parameters
                        )
                    }
                    return ctx
                }
            ),
            configuration: .init(maxTurns: Self.maxAgentTurns)
        )

        // Always send `.auto`. `tool_choice: "none"` has poor cross-provider
        // compatibility (some OpenAI-compatible backends reject or misroute
        // it, especially in the attachments path). When we want to discourage
        // automatic tool use we instead steer the model via the system prompt
        // — see `currentPromptShouldAvoidAutomaticToolUse` above, which
        // injects guidance into `keepTalkingSystemPrompt`.
        return try await orchestrator.run(
            messages: messages,
            tools: allTools,
            model: model,
            toolChoice: .auto,
            turnConfiguration: turnConfiguration,
            checkpoint: checkpoint,
            onCheckpoint: onCheckpoint
        )
    }

    // TODO: questionable...
    static func shouldAllowAutomaticToolUse(
        prompt: String,
        hasCurrentPromptAttachments: Bool
    ) -> Bool {
        guard hasCurrentPromptAttachments else {
            return true
        }

        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !normalizedPrompt.isEmpty else {
            return false
        }

        let explicitToolHints = [
            "use tool",
            "use tools",
            "call tool",
            "call tools",
            "run tool",
            "run tools",
            "use action",
            "run action",
            "search the web",
            "web search",
            "browse",
            "look up",
            "google",
            "available actions",
            "kt_list_",
            "kt_get_",
            "context attachment",
            "context file",
            "previous attachment",
            "previous file",
            "earlier attachment",
            "earlier file",
            "other attachment",
            "other file",
            "last attachment",
            "last file",
            "shared earlier",
            "sent earlier",
            "uploaded earlier",
            "from before",
        ]

        return explicitToolHints.contains(where: normalizedPrompt.contains)
    }

    func publishedToolName(
        for toolCall: AIToolCall,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        skillNameByActionID: [UUID: String],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        let name = toolCall.name
        if name == Self.markTurningPointToolFunctionName
            || name == Self.markChitterChatterToolFunctionName
            || name == Self.contextAttachmentUpdateMetadataToolFunctionName
            || name == Self.ktSkillMetainfoToolFunctionName
        {
            return ""
        }
        if name == Self.runActionToolFunctionName {
            let args =
                (try? decodeToolArguments(toolCall.argumentsJSON)) ?? [:]
            if let actionIDString = args["action_id"]?.stringValue,
                let actionID = UUID(uuidString: actionIDString),
                let stub = runtimeCatalog.actionStubs.first(where: {
                    $0.actionID == actionID
                })
            {
                return friendlyToolCallPhrase(
                    toolName: stub.name,
                    ownerNodeID: stub.ownerNodeID,
                    actionID: stub.actionID,
                    supportsWakeAssist: stub.supportsWakeAssist,
                    nodeAliasResolver: {
                        aliasLookup.alias(for: .node($0))
                    }
                )
            }
            return "calling action"
        }
        return toolNameForChatText(
            toolCall,
            routesByFunctionName: runtimeCatalog.routesByFunctionName,
            skillNameByActionID: skillNameByActionID,
            nodeAliasResolver: {
                aliasLookup.alias(for: .node($0))
            }
        )
    }

    func publishedToolHint(
        for toolCall: AIToolCall,
        stage: AIStage
    ) -> AIOrchestrator.ToolHintContext? {
        let name = toolCall.name
        if name == Self.markTurningPointToolFunctionName
            || name == Self.markChitterChatterToolFunctionName
        {
            return nil
        }

        if name == Self.runActionToolFunctionName {
            // Decode action metadata from the tool call arguments so it can be
            // stored in the intermediate message and surfaced in the UI.
            let args = (try? decodeToolArguments(toolCall.argumentsJSON)) ?? [:]
            let actionID: UUID? = args["action_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            let targetNodeID: UUID? = args["node_id"]?.stringValue.flatMap { UUID(uuidString: $0) }

            // Collect the remaining arguments (everything except the routing keys)
            let reservedKeys: Set<String> = ["action_id", "node_id"]
            var params: [String: String] = [:]
            for (key, value) in args where !reservedKeys.contains(key) {
                params[key] = value.stringValue ?? value.description
            }

            return .init(
                hint: .inspecting,
                targetNodeID: targetNodeID,
                actionID: actionID,
                actionName: nil,  // resolved by toolNameResolver; populated below by caller
                parameters: params.isEmpty ? nil : params
            )
        }

        if name == Self.ktSkillMetainfoToolFunctionName
            || name == Self.contextAttachmentUpdateMetadataToolFunctionName
        {
            return nil
        }

        if stage == .planning {
            return .init(hint: .reasoning)
        }

        switch name {
            case Self.searchThreadsToolFunctionName:
                let args = (try? decodeToolArguments(toolCall.argumentsJSON)) ?? [:]
                let query =
                    args["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let topK = args["top_k"]?.intValue
                var params: [String: String] = [:]
                if !query.isEmpty { params["query"] = query }
                if let topK { params["top_k"] = String(topK) }
                return .init(
                    hint: .searchingMemory,
                    actionName: query.isEmpty
                        ? nil : String(query.prefix(80)),
                    parameters: params.isEmpty ? nil : params
                )
            case Self.webSearchFunctionName:
                let args = (try? decodeToolArguments(toolCall.argumentsJSON)) ?? [:]
                let query =
                    args["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .init(
                    hint: .searchingWeb,
                    actionName: query.isEmpty
                        ? nil : String(query.prefix(80)),
                    parameters: query.isEmpty ? nil : ["query": query]
                )
            case Self.evaluateJSToolFunctionName:
                let args = (try? decodeToolArguments(toolCall.argumentsJSON)) ?? [:]
                let code =
                    args["code"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .init(
                    hint: .computing,
                    actionName: nil,
                    parameters: code.isEmpty ? nil : ["code": code]
                )
            default:
                return .init(hint: .toolUse)
        }
    }

    func currentPromptUserMessage(
        prompt: String,
        attachments: [KeepTalkingPreparedAttachment]
    ) async throws -> AIMessage {
        guard !attachments.isEmpty else {
            return .user(prompt)
        }

        var contentParts: [AIMessage.Part] = []
        let trimmedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedPrompt.isEmpty {
            contentParts.append(.text(trimmedPrompt))
        }
        let blobRecords = try await blobRecordsByBlobID(attachments.map(\.blobID))

        for attachment in attachments {
            guard attachment.byteCount <= Self.maxAINativeAttachmentBytes else {
                contentParts.append(
                    .text(
                        "Attachment '\(attachment.filename)' was omitted because it exceeds the native AI input budget."
                    )
                )
                continue
            }
            guard let blobRecord = blobRecords[attachment.blobID] else {
                throw KeepTalkingBlobStoreError.blobNotFound(attachment.blobID)
            }
            let data = try blobStore.read(
                relativePath: blobRecord.relativePath,
                blobID: attachment.blobID
            )

            contentParts.append(
                contentsOf: attachmentContentParts(
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    data: data
                )
            )
        }

        if contentParts.isEmpty {
            return .user(prompt)
        }
        return .user(parts: contentParts)
    }

    func attachmentContentParts(
        filename: String,
        mimeType: String,
        data: Data,
        leadText: String? = nil
    ) -> [AIMessage.Part] {
        if mimeType.hasPrefix("image/") {
            var parts: [AIMessage.Part] = []
            if let leadText = sanitizedAttachmentLeadText(leadText) {
                parts.append(.text(leadText))
            }
            if let inlined = Self.inlinedImagePart(mimeType: mimeType, data: data) {
                parts.append(inlined.part)
            }
            return parts
        }

        // Chat Completions doesn't support native PDF inputs — text-fallback only.
        let summary = attachmentTextFallback(
            filename: filename,
            mimeType: mimeType,
            data: data,
            leadText: leadText
        )
        return [.text(summary)]
    }

    /// Downscales an image (longest side capped at 4000px) and embeds it as a
    /// base64 data-URL image part — the ONE image-inlining pipeline, shared by
    /// context-attachment rendering above and plugin ACT resources
    /// (`KTPPActAttachmentRendering`). `byteCap` bounds the post-downscale
    /// payload; nil is uncapped. Returns the part plus the post-downscale MIME
    /// type (downscaling may transcode), or nil when the image cannot be
    /// inlined — still over the cap, or the data URL failed to form — so the
    /// caller renders its own too-large note.
    static func inlinedImagePart(
        mimeType: String, data: Data, byteCap: Int? = nil
    ) -> (part: AIMessage.Part, mimeType: String)? {
        let scaled = KeepTalkingImageDownscaler.downscaledIfNeeded(data, mimeType: mimeType)
        if let byteCap, scaled.data.count > byteCap { return nil }
        guard
            let url = URL(
                string: "data:\(scaled.mimeType);base64,\(scaled.data.base64EncodedString())")
        else { return nil }
        return (.imageURL(url), scaled.mimeType)
    }

    private func attachmentTextFallback(
        filename: String,
        mimeType: String,
        data: Data,
        leadText: String?
    ) -> String {
        let header =
            sanitizedAttachmentLeadText(leadText)
            ?? "Attached file '\(filename)'."
        if let preview = attachmentTextPreview(
            filename: filename,
            mimeType: mimeType,
            data: data
        ) {
            return "\(header)\n\n\(preview)"
        }
        return
            "\(header)\n\nBinary file '\(filename)' (\(mimeType), \(data.count) bytes) was not inlined natively for API compatibility."
    }

    private func attachmentTextPreview(
        filename: String,
        mimeType: String,
        data: Data
    ) -> String? {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension
            .lowercased()
        let knownTextExtensions: Set<String> = [
            "c", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
            "js", "json", "log", "md", "mjs", "py", "sh", "sql",
            "svelte", "swift", "toml", "ts", "txt", "xml", "yaml",
            "yml",
        ]
        let isTextLike =
            mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType == "application/xml"
            || knownTextExtensions.contains(pathExtension)

        guard isTextLike else {
            return nil
        }

        let preview = String(decoding: data.prefix(4_000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    private func sanitizedAttachmentLeadText(_ leadText: String?) -> String? {
        let trimmed = leadText?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Registers every granted local action with its executor (connecting HTTP
    /// MCP servers, spawning stdio processes, etc.).
    ///
    /// Decoupled from `connect()` on purpose and forgiving by design: a single
    /// executor that fails to register — an HTTP MCP endpoint needing re-auth, an
    /// offline stdio binary — is logged and skipped, never aborting the batch and
    /// never surfacing as a connection-level error that would pop a blocking auth
    /// prompt. Re-authentication happens on demand, when the tool is actually
    /// invoked. Call this explicitly after constructing a client (the App and CLI
    /// do; the daemon opts out).
    public func registerLocalActionsInExecutors() async throws {
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
        let grantedLocalActions = try await grantedActions(
            localActions,
            for: selfNode,
            context: context
        )

        for action in grantedLocalActions {
            do {
                try await registerLocalExecutor(action)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onLog?(
                    "[register] skipped action=\(action.id?.uuidString.lowercased() ?? "unknown") error=\(error.localizedDescription)"
                )
            }
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
                case .semanticRetrieval(let bundle):
                    return ("semantic_retrieval", bundle.name)
                case .actionCreation(let bundle):
                    return ("action_creation", bundle.name)
                case .filesystem(let bundle):
                    return ("filesystem", bundle.name)
                case .acp(let bundle):
                    return ("acp", bundle.name)
                case .plugin(let bundle):
                    return ("plugin", bundle.name)
            }
        }()

        do {
            // Patient registration: wait the grace period silently, then poll
            // executor liveness indefinitely instead of hard-failing. A genuinely
            // broken executor still surfaces — `registerIfNeeded` throws on real
            // failure (and MCP connect has its own inner timeout), and the
            // liveness probe bails if health flips to `.failed`.
            try await patientWait(
                label: "register \(source) executor action=\(actionID.uuidString.lowercased())",
                graceSeconds: 10,
                pollSeconds: 5,
                log: onLog,
                isAlive: { [weak self] in
                    guard let self else { return false }
                    guard source == "mcp" else { return true }
                    if case .failed = await self.mcpManager.actionHealth(
                        actionID: actionID
                    ) {
                        return false
                    }
                    return true
                },
                onDeath: {
                    KeepTalkingClientError.localExecutorRegistrationFailed(
                        actionID: actionID,
                        source: source,
                        actionName: actionName,
                        message: "executor became unavailable during registration"
                    )
                }
            ) { [self] in
                switch action.payload {
                    case .mcpBundle:
                        let actionID =
                            action.id?.uuidString.lowercased()
                            ?? "unknown"
                        onLog?("[mcp] registering local action=\(actionID)")
                        // Register metadata only — do NOT connect here. The
                        // connection (and any interactive OAuth, or a stdio
                        // server's own browser/loopback auth) happens lazily on
                        // first tool use, so opening a context never eagerly
                        // prompts or spawns every MCP server.
                        try await mcpManager.registerMCPAction(action)
                        onLog?("[mcp] registered local action=\(actionID)")
                    case .skill:
                        let actionID =
                            action.id?.uuidString.lowercased()
                            ?? "unknown"
                        onLog?("[skill] registering local action=\(actionID)")
                        try await skillManager.registerIfNeeded(action)
                        onLog?("[skill] registered local action=\(actionID)")
                    case .primitive:
                        let actionID =
                            action.id?.uuidString.lowercased()
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
                    case .semanticRetrieval:
                        // Handled app-side via semanticSearchCallback; no local executor.
                        return
                    case .actionCreation:
                        // Handled app-side via actionCreationHandler; no local executor.
                        return
                    case .filesystem:
                        let actionID =
                            action.id?.uuidString.lowercased()
                            ?? "unknown"
                        onLog?("[filesystem] registering local action=\(actionID)")
                        try await filesystemActionManager.registerIfNeeded(action)
                        onLog?("[filesystem] registered local action=\(actionID)")
                    case .acp:
                        #if os(macOS)
                        let actionID =
                            action.id?.uuidString.lowercased()
                            ?? "unknown"
                        onLog?("[acp] registering local action=\(actionID)")
                        try await acpManager.registerIfNeeded(action)
                        onLog?("[acp] registered local action=\(actionID)")
                        #endif
                    case .plugin:
                        // Nothing to register: the executor is a plugin process
                        // that attaches on its own and is already known to the
                        // host through pairing. Availability is the session,
                        // not a registration step.
                        return
                }
            }
        } catch let error as KeepTalkingClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KeepTalkingClientError.localExecutorRegistrationFailed(
                actionID: actionID,
                source: source,
                actionName: actionName,
                message: error.localizedDescription
            )
        }
    }

    func invalidateActionToolCatalog(
        contextID: UUID? = nil,
        reason: String
    ) async {
        await KeepTalkingActionCatalogCache.shared.invalidate(
            nodeID: config.node,
            contextID: contextID
        )
        onLog?(
            "[ai] catalog invalidated context=\(contextID?.uuidString.lowercased() ?? "all") reason=\(reason)"
        )
    }

    public func discoverActionToolCatalog(in context: KeepTalkingContext)
        async throws
        -> KeepTalkingActionToolCatalog
    {
        try await resolveActionRuntimeCatalog(in: context).catalog
    }

    func resolveAIConnector() async throws -> (any AIConnector)? {
        aiConnector
    }

    /// Connector the ACT (action/tool-calling) sub-agent should use. Falls back
    /// to the main connector when no ACT-specific connector was injected, so the
    /// ACT role only diverges when explicitly configured with its own provider.
    func resolveACTConnector() async throws -> (any AIConnector)? {
        actConnector ?? aiConnector
    }

    /// Builds a bound `AIOrchestrator.ACTAgent` for use inside `KeepTalkingSkillPlanner`
    /// when the planner is launched from within an existing conversation context.
    /// The returned agent captures the context's runtime catalog and a no-op publisher
    /// (planner turns don't emit intermediate trace rows to the conversation).
    public func makeSkillPlannerACTAgent(
        contextID: UUID,
        actModel: String?
    ) async throws -> AIOrchestrator.ACTAgent {
        let actResolved = try await resolveACTConnector()
        let mainResolved = try await resolveAIConnector()
        guard let connector = actResolved ?? mainResolved
        else { throw KeepTalkingClientError.aiNotConfigured }
        let db = localStore.database
        guard let context = try await KeepTalkingContext.find(contextID, on: db)
        else { throw KeepTalkingClientError.aiNotConfigured }
        let runtimeCatalog = try await resolveActionRuntimeCatalog(in: context)
        return AIOrchestrator.ACTAgent(
            canHandle: { $0.name == Self.runActionToolFunctionName },
            execute: { [self] toolCalls, activeModel in
                var executions: [AIOrchestrator.ToolExecution] = []
                for toolCall in toolCalls {
                    let toolCallID =
                        toolCall.id.isEmpty ? UUID().uuidString.lowercased() : toolCall.id
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: try await executeRunActionToolCall(
                                toolCallID: toolCallID,
                                rawArguments: toolCall.argumentsJSON,
                                runtimeCatalog: runtimeCatalog,
                                context: context,
                                actConnector: connector,
                                actModel: actModel ?? activeModel,
                                publisher: { @Sendable _, _, _ in },
                                agentTurnID: nil
                            )
                        )
                    )
                }
                return executions
            }
        )
    }

    func publishAgentRunFailure(
        contextID: UUID,
        roleName: String,
        model: String,
        message: String
    ) async {
        do {
            try await send(
                "AI error",
                in: contextID,
                sender: .autonomous(name: roleName, node: config.node, model: model),
                type: .haywire(reason: .failed),
                emitLocalEnvelope: true
            )
        } catch {
            onLog?(
                "[ai] failed to publish run failure context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
        // The detailed message stays in logs so it can be cross-referenced;
        // the UI surfaces it via the failed queue entry's localized message.
        onLog?(
            "[ai] run failed context=\(contextID.uuidString.lowercased()) message=\(message)"
        )
    }

    func publishAgentRunCancellation(contextID: UUID) async {
        do {
            try await send(
                "Cancelled",
                in: contextID,
                sender: .autonomous(name: "ai", node: config.node, model: ""),
                type: .haywire(reason: .cancelled),
                emitLocalEnvelope: true
            )
        } catch {
            onLog?(
                "[ai] failed to publish run cancellation context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
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
        allCompletionTools: [KeepTalkingActionToolDefinition],
        context: KeepTalkingContext,
        model: String
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
                    "[ai/tools] name=\(definition.functionName) action_name=\(actionName) source=\(definition.source.rawValue) route=\(routeKind(route)) action=\(definition.actionID.uuidString.lowercased()) owner=\(definition.ownerNodeID.uuidString.lowercased()) target=\(definition.targetName ?? "") display=\(definition.displayName ?? "") schema=\(schemaText)"
                )
            }
        }

        onLog?(
            "[ai/tools] meta_tools=\(Self.runActionToolFunctionName),\(Self.ktSkillMetainfoToolFunctionName)"
        )
        onLog?(
            "[ai/tools] built_ins=\(Self.contextAttachmentListingToolFunctionName),\(Self.resourceReadToolFunctionName),\(Self.contextAttachmentUpdateMetadataToolFunctionName),\(Self.searchThreadsToolFunctionName),\(Self.evaluateJSToolFunctionName),web_search_preview,\(Self.markTurningPointToolFunctionName),\(Self.markChitterChatterToolFunctionName)"
        )
    }
}
