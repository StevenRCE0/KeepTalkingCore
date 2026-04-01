import FluentKit
import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    func assistantMessage(
        from turn: OpenAIConnector.ToolPlanningResult
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
        let contextID = try context.requireID()
        let aliasLookup = try await aliasLookup()

        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.function.name

            do {
                if functionName == Self.listingToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: renderCatalogListing(
                                        runtimeCatalog.catalog,
                                        routesByFunctionName: runtimeCatalog
                                            .routesByFunctionName,
                                        contextID: contextID,
                                        nodeAliasResolver: {
                                            aliasLookup.alias(for: .node($0))
                                        }
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName
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
                }

                let payload: String
                if let route = runtimeCatalog.routesByFunctionName[
                    functionName
                ] {
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
                            let arguments = normalizedSkillFileArguments(
                                rawArguments
                            )
                            payload = renderSkillFilePayload(
                                functionName: functionName,
                                context: skillContext,
                                arguments: arguments
                            )
                        case .skillFileRemote(
                            let actionID,
                            let ownerNodeID,
                            let skillName
                        ):
                            let rawArguments = try decodeToolArguments(
                                toolCall.function.arguments
                            )
                            let arguments = normalizedSkillFileArguments(
                                rawArguments
                            )
                            payload = try await renderRemoteSkillFilePayload(
                                functionName: functionName,
                                actionID: actionID,
                                ownerNodeID: ownerNodeID,
                                skillName: skillName,
                                arguments: arguments,
                                context: context
                            )
                    }
                } else {
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
        if definition.source == .mcp,
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
                case .text(let text):
                    // TODO: we'll probably add metadata support here
                    return text.text
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
        let name = args["previous_topic_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return jsonString(["ok": false, "error": "missing_previous_topic_name"])
        }
        try await storeContextMark(
            .markTurningPoint(messageID: messageID, previousTopicName: name),
            in: context
        )
        try await consumePendingMarks(in: contextID)
        return jsonString(["ok": true])
    }

    func executeMarkChitterChatterToolCall(
        promptMessageID: UUID?,
        context: KeepTalkingContext
    ) async throws -> String {
        let contextID = try context.requireID()
        guard let messageID = promptMessageID else {
            return jsonString(["ok": false, "error": "no_prompt_message"])
        }
        try await storeContextMark(
            .markChitterChatter(messageID: messageID),
            in: context
        )
        try await consumePendingMarks(in: contextID)
        return jsonString(["ok": true])
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
