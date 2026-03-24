import FluentKit
import Foundation
import MCP
import OpenAI
import UniformTypeIdentifiers

extension KeepTalkingClient {
    static let listingToolFunctionName = "kt_list_available_actions"
    static let contextAttachmentListingToolFunctionName =
        "kt_list_context_attachments"
    static let contextAttachmentReadToolFunctionName =
        "kt_get_context_attachment"
    static let maxAgentTurns = 32
    static let maxAINativeAttachmentBytes = 8 * 1024 * 1024
    static let skillManifestPreviewMaxCharacters = 20_000
    static let skillFileMaxCharacters = 30_000

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = "gpt-5-codex",
        roleName: String = "ai",
        currentPromptAttachments: [KeepTalkingLocalAttachmentInput] = []
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
        let attachmentListingTool = makeContextAttachmentListingTool()
        let attachmentReadTool = makeContextAttachmentReadTool()

        let allTools: [OpenAITool] = [
            listingTool,
            attachmentListingTool,
            attachmentReadTool,
            webSearchTool,
        ] + runtimeCatalog.catalog.openAITools
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: runtimeCatalog.routesByFunctionName
        )
        let contextTranscript = try await agentContextTranscript(
            persistedContext,
            skillSummaries: runtimeCatalog.skillSummaries
        )
        let hasCurrentPromptAttachments = !currentPromptAttachments.isEmpty
        let allowAutomaticToolUse = Self.shouldAllowAutomaticToolUse(
            prompt: prompt,
            hasCurrentPromptAttachments: hasCurrentPromptAttachments
        )
        let userMessage = try currentPromptUserMessage(
            prompt: prompt,
            attachments: currentPromptAttachments
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
                            attachmentListingToolFunctionName:
                                Self.contextAttachmentListingToolFunctionName,
                            attachmentReaderToolFunctionName:
                                Self.contextAttachmentReadToolFunctionName,
                            currentPromptIncludesAttachments:
                                hasCurrentPromptAttachments,
                            currentPromptShouldAvoidAutomaticToolUse:
                                hasCurrentPromptAttachments
                                && !allowAutomaticToolUse,
                            contextTranscript: contextTranscript
                        )
                    )
                )
            ),
            userMessage,
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
                assistantPublisher: { [self] (assistantText, messageType) in
                    try await send(
                        assistantText,
                        in: persistedContext,
                        sender: .autonomous(name: roleName),
                        type: messageType,
                        emitLocalEnvelope: true
                    )
                },
                toolNameResolver: { [self] toolCall in
                    toolNameForChatText(
                        toolCall,
                        routesByFunctionName: runtimeCatalog
                            .routesByFunctionName,
                        skillNameByActionID: skillNameByActionID
                    )
                }
            ),
            configuration: .init(maxTurns: Self.maxAgentTurns)
        )

        return try await orchestrator.run(
            messages: messages,
            tools: allTools,
            model: model,
            toolChoice: allowAutomaticToolUse ? .auto : .none
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

    func currentPromptUserMessage(
        prompt: String,
        attachments: [KeepTalkingLocalAttachmentInput]
    ) throws -> ChatQuery.ChatCompletionMessageParam {
        guard !attachments.isEmpty else {
            return .user(.init(content: .string(prompt)))
        }

        var contentParts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam
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

            if mimeType.hasPrefix("image/") {
                contentParts.append(
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
            } else {
                contentParts.append(
                    .file(
                        .init(
                            file: .init(
                                data: data,
                                filename: filename
                            )
                        )
                    )
                )
            }
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
                    throw KeepTalkingClientError
                        .localExecutorRegistrationTimedOut(
                            actionID: actionID,
                            source: source,
                            actionName: actionName,
                            timeoutSeconds: timeoutSeconds
                        )
                }

                guard try await group.next() != nil else {
                    throw KeepTalkingClientError
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
            "[ai/tools] built_ins=\(Self.listingToolFunctionName),\(Self.contextAttachmentListingToolFunctionName),\(Self.contextAttachmentReadToolFunctionName),web_search_preview"
        )
        onLog?(
            "[ai/tools] listing_tool_name=\(Self.listingToolFunctionName) injected=true"
        )
    }
}
