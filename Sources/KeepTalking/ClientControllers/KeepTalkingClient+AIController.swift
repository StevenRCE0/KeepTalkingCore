import FluentKit
import Foundation
import MCP
import OpenAI
import UniformTypeIdentifiers

extension KeepTalkingClient {
    static let ktSkillMetainfoToolFunctionName = "kt_skill_metainfo"
    static let contextAttachmentListingToolFunctionName =
        "kt_list_context_attachments"
    static let contextAttachmentReadToolFunctionName =
        "kt_get_context_attachment"
    static let markTurningPointToolFunctionName = "kt_mark_turning_point"
    static let markChitterChatterToolFunctionName = "kt_mark_chitter_chatter"
    static let contextAttachmentUpdateMetadataToolFunctionName =
        "kt_update_context_attachment_metadata"
    static let searchThreadsToolFunctionName = "kt_search_threads"
    /// Function name used for web search in chat-completions mode (e.g. OpenRouter).
    /// In Responses API mode the built-in webSearchPreview tool is used instead.
    static let webSearchFunctionName = "web_search"
    static let maxAgentTurns = 32
    static let maxAINativeAttachmentBytes = 8 * 1024 * 1024
    static let skillManifestPreviewMaxCharacters = 20_000
    static let skillFileMaxCharacters = 30_000

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = "gpt-5-codex",
        actModel: OpenAIModel? = nil,
        roleName: String = "ai",
        currentPromptAttachments: [KeepTalkingLocalAttachmentInput] = []
    ) async throws -> String {
        guard let aiConnector = try await resolveAIConnector() else {
            throw KeepTalkingClientError.aiNotConfigured
        }

        await ensureMCPToolChangeObserverInstalled()

        let persistedContext = try await upsertContext(context)

        // Snapshot the latest message ID now (= user's prompt) before the AI
        // publishes any response messages.  Passed into the tool executors so
        // annotation tools act on the prompt, not the AI's own reply.
        let promptMessageID: UUID? = try? await KeepTalkingContextMessage
            .query(on: localStore.database)
            .filter(\.$context.$id == (try persistedContext.requireID()))
            .sort(\.$timestamp, .descending)
            .first()?.id

        let runtimeCatalog = try await resolveActionRuntimeCatalog(
            in: persistedContext
        )
        onLog?(
            "[ai] catalog has \(runtimeCatalog.catalog.definitions.count) tool proxy definition(s)"
        )

        // TODO: be able to switch off in the configurations
        let webSearchTool = makeWebSearchTool(apiMode: aiConnector.apiMode)
        let ktSkillMetainfoTool = makeKtSkillMetainfoTool()
        let attachmentListingTool = makeContextAttachmentListingTool()
        let attachmentReadTool = makeContextAttachmentReadTool()
        let markTurningPointTool = makeMarkTurningPointTool()
        let markChitterChatterTool = makeMarkChitterChatterTool()
        let attachmentUpdateMetadataTool =
            makeContextAttachmentUpdateMetadataTool()
        let searchThreadsTool = makeSearchThreadsTool()

        // Layer 0: meta tools + primitives (static schemas, no server I/O).
        // kt_run_action is always available — the ACT agent handles action execution
        // end-to-end (tool discovery, argument construction, execution, distillation).
        // The primary loop does not receive direct action tools.
        let allTools: [OpenAITool] =
            [
                makeRunActionTool(),
                ktSkillMetainfoTool,
                attachmentListingTool,
                attachmentReadTool,
                attachmentUpdateMetadataTool,
                searchThreadsTool,
                webSearchTool,
                markTurningPointTool,
                markChitterChatterTool,
            ].compactMap { $0 }
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: runtimeCatalog.routesByFunctionName
        )
        let aliasLookup = try await aliasLookup()
        let contextTranscript = try await agentContextTranscript(
            persistedContext,
            actionStubs: runtimeCatalog.actionStubs
        )
        let contextMessages = try await agentContextMessages(
            persistedContext,
            excludingMessageID: promptMessageID
        )
        let hasCurrentPromptAttachments = !currentPromptAttachments.isEmpty
        let allowAutomaticToolUse = Self.shouldAllowAutomaticToolUse(
            prompt: prompt,
            hasCurrentPromptAttachments: hasCurrentPromptAttachments
        )
        let userMessage = try currentPromptUserMessage(
            prompt: prompt,
            attachments: currentPromptAttachments,
            apiMode: aiConnector.apiMode
        )

        logInjectedAITools(
            runtimeCatalog: runtimeCatalog,
            allCompletionTools: allTools,
            context: persistedContext,
            model: model
        )

        let currentDate = ISO8601DateFormatter().string(from: Date())
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #elseif os(visionOS)
        let platform = "visionOS"
        #else
        let platform = "unknown"
        #endif

        let messages: [ChatQuery.ChatCompletionMessageParam] =
            [
                .system(
                    .init(
                        content: .textContent(
                            OpenAIConnector.keepTalkingSystemPrompt(
                                ktRunActionToolFunctionName:
                                    Self.runActionToolFunctionName,
                                ktSkillMetainfoToolFunctionName:
                                    Self.ktSkillMetainfoToolFunctionName,
                                attachmentListingToolFunctionName:
                                    Self.contextAttachmentListingToolFunctionName,
                                attachmentReaderToolFunctionName:
                                    Self.contextAttachmentReadToolFunctionName,
                                searchThreadsToolFunctionName:
                                    Self.searchThreadsToolFunctionName,
                                markTurningPointToolFunctionName:
                                    Self.markTurningPointToolFunctionName,
                                markChitterChatterToolFunctionName:
                                    Self.markChitterChatterToolFunctionName,
                                currentPromptIncludesAttachments:
                                    hasCurrentPromptAttachments,
                                currentPromptShouldAvoidAutomaticToolUse:
                                    hasCurrentPromptAttachments
                                    && !allowAutomaticToolUse,
                                contextTranscript: contextTranscript,
                                currentDate: currentDate,
                                platform: platform
                            )
                        )
                    )
                )
            ] + contextMessages + [
                userMessage
            ]

        let assistantPublisher: AIOrchestrator.AssistantPublisher = { [self] payload in
            let (assistantText, messageType) = payload
            try await send(
                assistantText,
                in: persistedContext,
                sender: .autonomous(name: roleName),
                type: messageType,
                emitLocalEnvelope: true
            )
        }

        let actAgent = AIOrchestrator.ACTAgent(
            canHandle: { $0.function.name == Self.runActionToolFunctionName },
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
                                rawArguments: toolCall.function.arguments,
                                runtimeCatalog: runtimeCatalog,
                                context: persistedContext,
                                actConnector: aiConnector,
                                actModel: actModel ?? activeModel,
                                publisher: assistantPublisher
                            )
                        )
                    )
                }
                return executions
            }
        )

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                aiConnector: aiConnector,
                assistantMessageBuilder: { [self] turn in
                    assistantMessage(from: turn)
                },
                toolExecutor: { [self] toolCalls in
                    try await executeAgentToolCalls(
                        toolCalls,
                        runtimeCatalog: runtimeCatalog,
                        promptMessageID: promptMessageID,
                        context: persistedContext
                    )
                },
                toolTranscriptAdapter: { [self] executions in
                    try await adaptMidTurnInjectionMessages(
                        executions,
                        runtimeCatalog: runtimeCatalog,
                        context: persistedContext
                    )
                },
                actAgent: actAgent,
                assistantPublisher: assistantPublisher,
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
            ),
            configuration: .init(maxTurns: Self.maxAgentTurns)
        )

        let resolvedToolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam =
            allowAutomaticToolUse ? .auto : .none
        return try await orchestrator.run(
            messages: messages,
            tools: allTools,
            model: model,
            toolChoice: resolvedToolChoice
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
        for toolCall: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        skillNameByActionID: [UUID: String],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        let name = toolCall.function.name
        if name == Self.markTurningPointToolFunctionName
            || name == Self.markChitterChatterToolFunctionName
            || name == Self.contextAttachmentUpdateMetadataToolFunctionName
            || name == Self.ktSkillMetainfoToolFunctionName
        {
            return ""
        }
        if name == Self.runActionToolFunctionName {
            let args =
                (try? decodeToolArguments(toolCall.function.arguments)) ?? [:]
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
        for toolCall: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam,
        stage: AIStage
    ) -> AIOrchestrator.IntermediateMessageHints? {
        let name = toolCall.function.name
        if name == Self.markTurningPointToolFunctionName
            || name == Self.markChitterChatterToolFunctionName
        {
            return nil
        }

        if name == Self.runActionToolFunctionName {
            return .inspecting
        }

        if name == Self.ktSkillMetainfoToolFunctionName
            || name == Self.contextAttachmentUpdateMetadataToolFunctionName
        {
            return nil
        }

        if stage == .planning {
            return .reasoning
        }

        switch name {
            case Self.searchThreadsToolFunctionName:
                return .searchingMemory
            case Self.webSearchFunctionName:
                return .searchingWeb
            default:
                return .toolUse
        }
    }

    func currentPromptUserMessage(
        prompt: String,
        attachments: [KeepTalkingLocalAttachmentInput],
        apiMode: OpenAIAPIMode
    ) throws -> ChatQuery.ChatCompletionMessageParam {
        guard !attachments.isEmpty else {
            return .user(.init(content: .string(prompt)))
        }

        var contentParts:
            [ChatQuery.ChatCompletionMessageParam.UserMessageParam
                .Content.ContentPart] = []
        let trimmedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedPrompt.isEmpty {
            contentParts.append(.text(.init(text: trimmedPrompt)))
        }

        for attachment in attachments {
            let filename = currentPromptAttachmentFilename(attachment)
            let mimeType = currentPromptAttachmentMimeType(
                attachment,
                filename: filename
            )
            let data = try Data(contentsOf: attachment.sourceURL)

            guard data.count <= Self.maxAINativeAttachmentBytes else {
                contentParts.append(
                    .text(
                        .init(
                            text:
                                "Attachment '\(filename)' was omitted because it exceeds the native AI input budget."
                        )
                    )
                )
                continue
            }

            contentParts.append(
                contentsOf: attachmentContentParts(
                    filename: filename,
                    mimeType: mimeType,
                    data: data,
                    apiMode: apiMode
                )
            )
        }

        if contentParts.isEmpty {
            return .user(.init(content: .string(prompt)))
        }

        return .user(
            .init(content: .contentParts(contentParts))
        )
    }

    private func currentPromptAttachmentFilename(
        _ attachment: KeepTalkingLocalAttachmentInput
    ) -> String {
        let filename = attachment.filename?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let filename, !filename.isEmpty {
            return filename
        }
        return attachment.sourceURL.lastPathComponent
    }

    private func currentPromptAttachmentMimeType(
        _ attachment: KeepTalkingLocalAttachmentInput,
        filename: String
    ) -> String {
        if let mimeType = attachment.mimeType?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !mimeType.isEmpty {
            return mimeType
        }

        let pathExtension = attachment.sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedExtension =
            pathExtension.isEmpty
            ? URL(fileURLWithPath: filename).pathExtension
            : pathExtension
        if let type = UTType(filenameExtension: resolvedExtension),
            let mimeType = type.preferredMIMEType
        {
            return mimeType
        }
        return "application/octet-stream"
    }

    func attachmentContentParts(
        filename: String,
        mimeType: String,
        data: Data,
        apiMode: OpenAIAPIMode,
        leadText: String? = nil
    ) -> [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] {
        if mimeType.hasPrefix("image/") {
            var parts:
                [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content
                    .ContentPart] = []
            if let leadText = sanitizedAttachmentLeadText(leadText) {
                parts.append(.text(.init(text: leadText)))
            }
            parts.append(
                .image(
                    .init(
                        imageUrl: .init(
                            url:
                                "data:\(mimeType);base64,\(data.base64EncodedString())",
                            detail: .auto
                        )
                    )
                )
            )
            return parts
        }

        if apiMode != .responses || mimeType != "application/pdf" {
            let summary = attachmentTextFallback(
                filename: filename,
                mimeType: mimeType,
                data: data,
                leadText: leadText
            )
            return [.text(.init(text: summary))]
        }

        var parts:
            [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content
                .ContentPart] = []
        if let leadText = sanitizedAttachmentLeadText(leadText) {
            parts.append(.text(.init(text: leadText)))
        }
        parts.append(
            .file(
                .init(
                    file: .init(
                        data: data,
                        filename: filename
                    )
                )
            )
        )
        return parts
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
        let grantedLocalActions = try await grantedActions(
            localActions,
            for: selfNode,
            context: context
        )

        for action in grantedLocalActions {
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
                case .semanticRetrieval(let bundle):
                    return ("semantic_retrieval", bundle.name)
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
                            let actionID =
                                action.id?.uuidString.lowercased()
                                ?? "unknown"
                            onLog?("[mcp] registering local action=\(actionID)")
                            try await mcpManager.registerIfNeeded(action)
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
                    }
                }
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    self.onLog?(
                        "[\(source)] registration timeout action=\(actionIDLabel) after=\(Int(timeoutSeconds))s"
                    )
                    throw
                        KeepTalkingClientError
                        .localExecutorRegistrationTimedOut(
                            actionID: actionID,
                            source: source,
                            actionName: actionName,
                            timeoutSeconds: timeoutSeconds
                        )
                }

                guard try await group.next() != nil else {
                    throw
                        KeepTalkingClientError
                        .localExecutorRegistrationTimedOut(
                            actionID: actionID,
                            source: source,
                            actionName: actionName,
                            timeoutSeconds: timeoutSeconds
                        )
                }
                group.cancelAll()
            }
        } catch let error as KeepTalkingClientError {
            throw error
        } catch {
            throw KeepTalkingClientError.localExecutorRegistrationFailed(
                actionID: actionID,
                source: source,
                actionName: actionName,
                message: error.localizedDescription
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

    func resolveAIConnector() async throws -> (any AIConnector)? {
        aiConnector
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
                    "[ai/tools] name=\(definition.functionName) action_name=\(actionName) source=\(definition.source.rawValue) route=\(routeKind(route)) action=\(definition.actionID.uuidString.lowercased()) owner=\(definition.ownerNodeID.uuidString.lowercased()) target=\(definition.targetName ?? "") display=\(definition.displayName ?? "") schema=\(schemaText)"
                )
            }
        }

        onLog?(
            "[ai/tools] meta_tools=\(Self.runActionToolFunctionName),\(Self.ktSkillMetainfoToolFunctionName)"
        )
        onLog?(
            "[ai/tools] built_ins=\(Self.contextAttachmentListingToolFunctionName),\(Self.contextAttachmentReadToolFunctionName),\(Self.contextAttachmentUpdateMetadataToolFunctionName),\(Self.searchThreadsToolFunctionName),web_search_preview,\(Self.markTurningPointToolFunctionName),\(Self.markChitterChatterToolFunctionName)"
        )
    }
}
