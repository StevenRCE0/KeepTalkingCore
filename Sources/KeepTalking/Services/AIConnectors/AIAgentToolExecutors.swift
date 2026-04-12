import FluentKit
import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    func assistantMessage(
        from turn: AITurnResult
    ) -> ChatQuery.ChatCompletionMessageParam? {
        let text = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? =
            (text?.isEmpty == false) ? .textContent(text!) : nil
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        if content == nil, toolCalls == nil {
            return nil
        }
        return .assistant(
            .init(
                content: content,
                toolCalls: toolCalls
            )
        )
    }

    func executeAgentToolCalls(
        _ toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam],
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        promptMessageID: UUID?,
        context: KeepTalkingContext
    ) async throws -> [AIOrchestrator.ToolExecution] {
        var executions: [AIOrchestrator.ToolExecution] = []

        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.function.name

            do {
                if functionName
                    == Self.contextAttachmentListingToolFunctionName
                {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await renderContextAttachmentListingPayload(
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName
                    == Self.contextAttachmentReadToolFunctionName
                {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: try await executeContextAttachmentReadToolCall(
                                toolCallID: toolCallID,
                                rawArguments: toolCall.function.arguments,
                                context: context
                            )
                        )
                    )
                    continue
                } else if functionName == Self.markTurningPointToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeMarkTurningPointToolCall(
                                        rawArguments: toolCall.function.arguments,
                                        promptMessageID: promptMessageID,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.markChitterChatterToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeMarkChitterChatterToolCall(
                                        promptMessageID: promptMessageID,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName
                    == Self.contextAttachmentUpdateMetadataToolFunctionName
                {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeContextAttachmentUpdateMetadataToolCall(
                                        toolCallID: toolCallID,
                                        rawArguments: toolCall.function.arguments,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.searchThreadsToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeSearchThreadsToolCall(
                                        rawArguments: toolCall.function.arguments,
                                        runtimeCatalog: runtimeCatalog,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.webSearchFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeWebSearchToolCall(
                                        rawArguments: toolCall.function.arguments
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.ktSkillMetainfoToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: try await executeKtSkillMetainfoToolCall(
                                toolCallID: toolCallID,
                                rawArguments: toolCall.function.arguments,
                                runtimeCatalog: runtimeCatalog,
                                context: context
                            )
                        )
                    )
                    continue
                }

                let payload: String
                let route: KeepTalkingAgentToolRoute?
                if let staticRoute = runtimeCatalog.routesByFunctionName[functionName] {
                    route = staticRoute
                } else {
                    route = await runtimeCatalog.lazyRegistry.route(for: functionName)
                }
                switch route {
                    case .actionProxy(let definition):
                        payload = try await executeActionProxyToolCall(
                            functionName: functionName,
                            definition: definition,
                            rawArguments: toolCall.function.arguments,
                            context: context
                        )
                    case .skillMetadata(let skillContext):
                        payload = renderSkillMetadataPayload(
                            functionName: functionName,
                            context: skillContext
                        )
                    case .skillFileLocal(let skillContext):
                        let rawArguments = try decodeToolArguments(
                            toolCall.function.arguments
                        )
                        let arguments = normalizedSkillFileArguments(rawArguments)
                        payload = renderSkillFilePayload(
                            functionName: functionName,
                            context: skillContext,
                            arguments: arguments
                        )
                    case .skillFileRemote(let actionID, let ownerNodeID, let skillName):
                        let rawArguments = try decodeToolArguments(
                            toolCall.function.arguments
                        )
                        let arguments = normalizedSkillFileArguments(rawArguments)
                        payload = try await renderRemoteSkillFilePayload(
                            functionName: functionName,
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            skillName: skillName,
                            arguments: arguments,
                            context: context
                        )
                    case .none:
                        payload = jsonString([
                            "ok": false,
                            "error": "unknown_tool",
                            "function_name": functionName,
                        ])
                }
                executions.append(
                    .init(
                        toolCall: toolCall,
                        messages: [
                            toolMessage(
                                payload: payload,
                                toolCallID: toolCallID
                            )
                        ]
                    )
                )
            } catch {
                executions.append(
                    .init(
                        toolCall: toolCall,
                        messages: [
                            toolMessage(
                                payload: jsonString([
                                    "ok": false,
                                    "function_name": functionName,
                                    "error": "tool_execution_failed",
                                    "error_message": error.localizedDescription,
                                ]),
                                toolCallID: toolCallID
                            )
                        ]
                    )
                )
            }
        }

        return executions
    }

    func toolMessage(
        payload: String,
        toolCallID: String
    ) -> ChatQuery.ChatCompletionMessageParam {
        .tool(
            .init(
                content: .textContent(payload),
                toolCallId: toolCallID
            )
        )
    }

    func executeActionProxyToolCall(
        functionName: String,
        definition: KeepTalkingActionToolDefinition,
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        let arguments = try parsedActionCallArguments(
            definition: definition,
            rawArguments: rawArguments
        )
        let contextID = try context.requireID()
        var metadata = Metadata()
        metadata.fields["context_id"] = .string(
            contextID.uuidString.lowercased()
        )
        metadata.fields["tool_name"] = .string(functionName)
        if let targetName = definition.targetName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !targetName.isEmpty
        {
            metadata.fields["action_target_name"] = .string(targetName)
        }
        if let displayName = definition.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        {
            metadata.fields["display_name"] = .string(displayName)
        }

        let actionCall = KeepTalkingActionCall(
            action: definition.actionID,
            arguments: arguments,
            metadata: metadata
        )

        let result = try await dispatchActionCall(
            actionOwner: definition.ownerNodeID,
            call: actionCall,
            context: context
        )
        return renderAgentToolPayload(
            functionName: functionName,
            result: result
        )
    }

    func parsedActionCallArguments(
        definition: KeepTalkingActionToolDefinition,
        rawArguments: String
    ) throws -> [String: Value] {
        var arguments = try decodeToolArguments(rawArguments)
        if (definition.source == .mcp || definition.source == .filesystem),
            let targetName = definition.targetName,
            arguments["tool"] == nil
        {
            arguments = [
                "tool": .string(targetName),
                "arguments": .object(arguments),
            ]
        }
        return arguments
    }

    func renderAgentToolPayload(
        functionName: String,
        result: KeepTalkingActionCallResult
    ) -> String {
        let renderedContent = result.content.map { content -> String in
            switch content {
                case .text(let text, _, _):
                    // TODO: we'll probably add metadata support here
                    return text
                default:
                    if let data = try? JSONEncoder().encode(content),
                        let json = String(data: data, encoding: .utf8)
                    {
                        return json
                    }
                    return "<non-text content>"
            }
        }

        return jsonString([
            "ok": !result.isError,
            "function_name": functionName,
            "request_id": result.requestID.uuidString.lowercased(),
            "action_id": result.actionID.uuidString.lowercased(),
            "caller_node_id": result.callerNodeID.uuidString.lowercased(),
            "target_node_id": result.targetNodeID.uuidString.lowercased(),
            "error_message": result.errorMessage ?? "",
            "content": renderedContent,
        ])
    }

    func renderSkillMetadataPayload(
        functionName: String,
        context: KeepTalkingSkillCatalogContext
    ) -> String {
        jsonString([
            "ok": context.loadError == nil,
            "function_name": functionName,
            "route_kind": "skill_metadata",
            "action_id": context.actionID.uuidString.lowercased(),
            "owner_node_id": context.ownerNodeID.uuidString.lowercased(),
            "skill_name": context.bundle.name,
            "manifest_path": context.manifestPath,
            "manifest_metadata": context.manifestMetadata,
            "references_files": context.referencesFiles,
            "scripts": context.scripts,
            "assets": context.assets,
            "manifest_preview": context.manifestPreview,
            "error_message": context.loadError ?? "",
        ])
    }

    func renderSkillFilePayload(
        functionName: String,
        context: KeepTalkingSkillCatalogContext,
        arguments: [String: Value]
    ) -> String {
        guard context.loadError == nil else {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": context.actionID.uuidString.lowercased(),
                "error": "skill_context_unavailable",
                "error_message": context.loadError ?? "unknown",
            ])
        }

        let requestedPath =
            arguments["path"]?.stringValue
            ?? arguments["file"]?.stringValue
            ?? ""
        let defaultLimit = Self.skillFileMaxCharacters
        let limitFromArguments =
            arguments["max_characters"]?.intValue
            ?? arguments["limit"]?.intValue
            ?? arguments["max_characters"]?.doubleValue.map { Int($0) }
        let maxCharacters = min(
            max(limitFromArguments ?? defaultLimit, 128),
            defaultLimit
        )

        do {
            let fileURL = try resolveSkillFileURL(
                requestedPath,
                skillDirectory: context.bundle.directory
            )
            let rawData = try Data(contentsOf: fileURL)
            let fileText =
                String(data: rawData, encoding: .utf8)
                ?? String(decoding: rawData, as: UTF8.self)
            let content = clipped(fileText, maxCharacters: maxCharacters)

            let rootPath = context.bundle.directory.standardizedFileURL.path
            let path = fileURL.standardizedFileURL.path
            let relativePath: String
            if path.hasPrefix(rootPath + "/") {
                relativePath = String(path.dropFirst(rootPath.count + 1))
            } else {
                relativePath = path
            }

            return jsonString([
                "ok": true,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": context.actionID.uuidString.lowercased(),
                "owner_node_id": context.ownerNodeID.uuidString.lowercased(),
                "skill_name": context.bundle.name,
                "path": relativePath,
                "max_characters": maxCharacters,
                "truncated": fileText.count > maxCharacters,
                "content": content,
            ])
        } catch {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": context.actionID.uuidString.lowercased(),
                "owner_node_id": context.ownerNodeID.uuidString.lowercased(),
                "skill_name": context.bundle.name,
                "path": requestedPath,
                "error": "file_read_failed",
                "error_message": error.localizedDescription,
            ])
        }
    }

    func renderRemoteSkillFilePayload(
        functionName: String,
        actionID: UUID,
        ownerNodeID: UUID,
        skillName: String,
        arguments: [String: Value],
        context: KeepTalkingContext
    ) async throws -> String {
        let result = try await dispatchActionCatalogRequest(
            targetNodeID: ownerNodeID,
            queries: [
                KeepTalkingActionCatalogQuery(
                    actionID: actionID,
                    kind: .skillFile,
                    arguments: arguments
                )
            ],
            context: context
        )

        if result.isError {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": actionID.uuidString.lowercased(),
                "owner_node_id": ownerNodeID.uuidString.lowercased(),
                "skill_name": skillName,
                "error": "catalog_request_failed",
                "error_message": result.errorMessage ?? "unknown",
            ])
        }

        guard
            let item = result.items.first(where: {
                $0.actionID == actionID && $0.kind == .skillFile
            })
        else {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": actionID.uuidString.lowercased(),
                "owner_node_id": ownerNodeID.uuidString.lowercased(),
                "skill_name": skillName,
                "error": "missing_skill_file_result",
                "error_message": "No skill_file item returned from remote node.",
            ])
        }

        if item.isError {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": actionID.uuidString.lowercased(),
                "owner_node_id": ownerNodeID.uuidString.lowercased(),
                "skill_name": skillName,
                "error": "remote_skill_file_failed",
                "error_message": item.errorMessage ?? "unknown",
            ])
        }

        guard let skillFile = item.skillFile else {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "route_kind": "skill_file",
                "action_id": actionID.uuidString.lowercased(),
                "owner_node_id": ownerNodeID.uuidString.lowercased(),
                "skill_name": skillName,
                "error": "missing_skill_file_payload",
                "error_message": "Remote node returned no skill file payload.",
            ])
        }

        return jsonString([
            "ok": true,
            "function_name": functionName,
            "route_kind": "skill_file",
            "action_id": actionID.uuidString.lowercased(),
            "owner_node_id": ownerNodeID.uuidString.lowercased(),
            "skill_name": skillName,
            "path": skillFile.path,
            "max_characters": skillFile.maxCharacters,
            "truncated": skillFile.truncated,
            "content": skillFile.content,
        ])
    }

    func executeKtSkillMetainfoToolCall(
        toolCallID: String,
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        let args = try decodeToolArguments(rawArguments)

        guard let actionIDString = args["action_id"]?.stringValue,
            let actionID = UUID(uuidString: actionIDString)
        else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "error": "missing_or_invalid_action_id",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        guard
            let stub = runtimeCatalog.actionStubs.first(where: {
                $0.actionID == actionID && $0.kind == .skill
            })
        else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "error": "action_not_found_or_not_a_skill",
                        "action_id": actionIDString,
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        if stub.isCurrentNode {
            guard
                let action = try? await KeepTalkingAction.find(
                    actionID, on: localStore.database
                ),
                case .skill(let bundle) = action.payload
            else {
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": false,
                            "error": "skill_action_not_found",
                            "action_id": actionIDString,
                        ]),
                        toolCallID: toolCallID
                    )
                ]
            }

            let skillContext = loadSkillCatalogContext(
                actionID: actionID,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle
            )

            // Register file + metadata tools into lazy registry on first access
            if await !runtimeCatalog.lazyRegistry.isInitialized(actionID) {
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
                let skillRoutes: [String: KeepTalkingAgentToolRoute] = [
                    fileToolDef.functionName: .skillFileLocal(skillContext),
                    metaToolDef.functionName: .skillMetadata(skillContext),
                ]
                await runtimeCatalog.lazyRegistry.register(
                    routes: skillRoutes,
                    for: actionID
                )
                runtimeCatalog.append(
                    definitions: [fileToolDef, metaToolDef],
                    routes: skillRoutes
                )
            }

            return [
                toolMessage(
                    payload: renderSkillMetadataPayload(
                        functionName: Self.ktSkillMetainfoToolFunctionName,
                        context: skillContext
                    ),
                    toolCallID: toolCallID
                )
            ]
        } else {
            // Remote skill: dispatch catalog request on demand
            let result: KeepTalkingActionCatalogResult
            do {
                result = try await dispatchActionCatalogRequest(
                    targetNodeID: stub.ownerNodeID,
                    queries: [
                        KeepTalkingActionCatalogQuery(
                            actionID: actionID,
                            kind: .skillMetadata
                        )
                    ],
                    context: context
                )
            } catch {
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": false,
                            "error": "remote_catalog_request_failed",
                            "error_message": error.localizedDescription,
                        ]),
                        toolCallID: toolCallID
                    )
                ]
            }

            guard
                let item = result.items.first(where: {
                    $0.actionID == actionID && $0.kind == .skillMetadata
                }),
                !item.isError,
                let metadata = item.skillMetadata
            else {
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": false,
                            "error": "remote_skill_metadata_unavailable",
                            "action_id": actionIDString,
                            "error_message": result.errorMessage ?? "no metadata returned",
                        ]),
                        toolCallID: toolCallID
                    )
                ]
            }

            // Register remote skill file tool into lazy registry on first access
            if await !runtimeCatalog.lazyRegistry.isInitialized(actionID) {
                let fileToolDef = KeepTalkingActionToolDefinition(
                    functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                        ownerNodeID: stub.ownerNodeID,
                        actionID: actionID,
                        targetName: "skill_file"
                    ),
                    actionID: actionID,
                    ownerNodeID: stub.ownerNodeID,
                    source: .skill,
                    targetName: "skill_file",
                    displayName: metadata.name,
                    description:
                        "Read a file from skill bundle \(metadata.name). Paths must stay within the skill directory.",
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([
                            "path": JSONSchema(
                                .type(.string),
                                .description("Relative path inside the skill bundle.")
                            ),
                            "max_characters": JSONSchema(
                                .type(.integer),
                                .description("Optional maximum characters to return.")
                            ),
                        ]),
                        .additionalProperties(.boolean(true))
                    )
                )
                let remoteSkillRoutes: [String: KeepTalkingAgentToolRoute] = [
                    fileToolDef.functionName: .skillFileRemote(
                        actionID: actionID,
                        ownerNodeID: stub.ownerNodeID,
                        skillName: metadata.name
                    ),
                ]
                await runtimeCatalog.lazyRegistry.register(
                    routes: remoteSkillRoutes,
                    for: actionID
                )
                runtimeCatalog.append(definitions: [fileToolDef], routes: remoteSkillRoutes)
            }

            return [
                toolMessage(
                    payload: jsonString([
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
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }
    }

    @discardableResult
    func ensureLocalMCPToolsRegistered(
        actionID: UUID,
        stub: KeepTalkingActionStub,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog
    ) async -> [KeepTalkingActionToolDefinition] {
        guard await !runtimeCatalog.lazyRegistry.isInitialized(actionID) else { return [] }
        guard
            let action = try? await KeepTalkingAction.find(
                actionID, on: localStore.database
            ),
            case .mcpBundle(let bundle) = action.payload
        else {
            return []
        }
        do {
            try await preflightHTTPMCPAuthentication(action: action)
            let definitions = try await mcpProxyDefinitions(
                for: action,
                ownerNodeID: stub.ownerNodeID,
                bundle: bundle,
                remoteTools: []
            )
            var routes: [String: KeepTalkingAgentToolRoute] = [:]
            for def in definitions {
                routes[def.functionName] = .actionProxy(def)
                // Also register the original MCP tool name so the ACT model
                // can call it by its real name (e.g. "XcodeListWindows") rather
                // than the opaque normalized ID.
                if let targetName = def.targetName, !targetName.isEmpty {
                    routes[targetName] = .actionProxy(def)
                }
            }
            await runtimeCatalog.lazyRegistry.register(
                routes: routes,
                for: actionID
            )
            runtimeCatalog.append(definitions: definitions, routes: routes)
            return definitions
        } catch {
            onLog?(
                "[ai] lazy MCP init failed action=\(actionID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            return []
        }
    }

    func executeMarkTurningPointToolCall(
        rawArguments: String,
        promptMessageID: UUID?,
        context: KeepTalkingContext
    ) async throws -> String {
        let contextID = try context.requireID()
        guard let messageID = promptMessageID else {
            return jsonString(["ok": false, "error": "no_prompt_message"])
        }
        let args = try decodeToolArguments(rawArguments)
        let previousTopicName =
            args["previous_topic_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentTopicName =
            args["current_topic_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !currentTopicName.isEmpty else {
            return jsonString(["ok": false, "error": "missing_current_topic_name"])
        }
        let created = try await storeContextMark(
            .markTurningPoint(
                messageID: messageID,
                previousTopicName: previousTopicName.isEmpty
                    ? nil
                    : previousTopicName,
                currentTopicName: currentTopicName
            ),
            in: context
        )
        guard created else {
            return jsonString([
                "ok": true,
                "created": false,
                "reason": "duplicate_mark_message_id",
            ])
        }
        try await consumePendingMarks(in: contextID)
        return jsonString(["ok": true, "created": true])
    }

    func executeMarkChitterChatterToolCall(
        promptMessageID: UUID?,
        context: KeepTalkingContext
    ) async throws -> String {
        let contextID = try context.requireID()
        guard let messageID = promptMessageID else {
            return jsonString(["ok": false, "error": "no_prompt_message"])
        }
        let created = try await storeContextMark(
            .markChitterChatter(messageID: messageID),
            in: context
        )
        guard created else {
            return jsonString([
                "ok": true,
                "created": false,
                "reason": "duplicate_mark_message_id",
            ])
        }
        try await consumePendingMarks(in: contextID)
        return jsonString(["ok": true, "created": true])
    }

    func executeWebSearchToolCall(rawArguments: String) async throws -> String {
        let args = try decodeToolArguments(rawArguments)
        guard let query = args["query"]?.stringValue,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return jsonString(["ok": false, "error": "missing_query"])
        }
        guard let provider = webSearchProvider else {
            return jsonString([
                "ok": false,
                "error": "web_search_not_configured",
                "message":
                    "No web search provider is set. Call setWebSearchProvider(_:) on the KeepTalkingClient.",
            ])
        }
        let result = try await provider(query)
        return result
    }

    func decodeToolArguments(_ raw: String) throws -> [String: Value] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeepTalkingClientError.invalidToolArguments(raw)
        }
        do {
            return try JSONDecoder().decode([String: Value].self, from: data)
        } catch {
            throw KeepTalkingClientError.invalidToolArguments(raw)
        }
    }

    func normalizedSkillFileArguments(_ arguments: [String: Value])
        -> [String: Value]
    {
        if let nested = arguments["arguments"]?.objectValue {
            return nested
        }
        if let nested = arguments["params"]?.objectValue {
            return nested
        }
        return arguments
    }
}
