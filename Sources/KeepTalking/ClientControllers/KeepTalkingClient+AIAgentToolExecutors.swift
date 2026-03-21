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
        context: KeepTalkingContext
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        let contextID = try context.requireID()

        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.function.name

            let payload: String
            do {
                if functionName == Self.listingToolFunctionName {
                    payload = renderCatalogListing(
                        runtimeCatalog.catalog,
                        routesByFunctionName: runtimeCatalog.routesByFunctionName,
                        contextID: contextID
                    )
                } else if let route = runtimeCatalog.routesByFunctionName[
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
            } catch {
                payload = jsonString([
                    "ok": false,
                    "function_name": functionName,
                    "error": "tool_execution_failed",
                    "error_message": error.localizedDescription,
                ])
            }

            messages.append(
                .tool(
                    .init(
                        content: .textContent(payload),
                        toolCallId: toolCallID
                    )
                )
            )
        }

        return messages
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

        let actionCall = KeepTalkingActionCall(
            action: definition.actionID,
            arguments: arguments
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
            let mcpToolName = definition.mcpToolName,
            arguments["tool"] == nil
        {
            arguments = [
                "tool": .string(mcpToolName),
                "arguments": .object(arguments),
            ]
        }
        return arguments
    }

    func toolNameForChatText(
        _ toolCall: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam,
        routesByFunctionName: [String: KeepTalkingAgentToolRoute],
        skillNameByActionID: [UUID: String]
    ) -> String {
        let functionName = toolCall.function.name
        guard functionName != Self.listingToolFunctionName else {
            return "list available actions"
        }
        guard let route = routesByFunctionName[functionName] else {
            return friendlyToolCallPhrase(
                toolName: functionName,
                ownerNodeID: nil,
                actionID: nil,
                supportsWakeAssist: false
            )
        }

        switch route {
            case .actionProxy(let definition):
                let routedToolName: String
                if definition.source == .mcp,
                    let arguments = try? parsedActionCallArguments(
                        definition: definition,
                        rawArguments: toolCall.function.arguments
                    ),
                    let selectedTool = arguments["tool"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !selectedTool.isEmpty
                {
                    routedToolName = KeepTalkingActionToolDefinition
                        .routedActionName(
                        selectedTool,
                        actionID: definition.actionID
                    )
                } else {
                    routedToolName = actionDisplayName(
                        for: definition,
                        route: route,
                        skillNameByActionID: skillNameByActionID
                    )
                }

                return friendlyToolCallPhrase(
                    toolName: routedToolName,
                    ownerNodeID: definition.ownerNodeID,
                    actionID: definition.actionID,
                    supportsWakeAssist: definition.supportsWakeAssist
                )
            case .skillMetadata(let context):
                return friendlyToolCallPhrase(
                    toolName: "skill metadata \(context.bundle.name)",
                    ownerNodeID: context.ownerNodeID,
                    actionID: context.actionID,
                    supportsWakeAssist: false
                )
            case .skillFileLocal(let context):
                return friendlyToolCallPhrase(
                    toolName: "skill file \(context.bundle.name)",
                    ownerNodeID: context.ownerNodeID,
                    actionID: context.actionID,
                    supportsWakeAssist: false
                )
            case .skillFileRemote(let actionID, _, let skillName):
                return friendlyToolCallPhrase(
                    toolName: "skill file \(skillName)",
                    ownerNodeID: nil,
                    actionID: actionID,
                    supportsWakeAssist: false
                )
        }
    }

    func friendlyToolCallPhrase(
        toolName: String,
        ownerNodeID: UUID?,
        actionID: UUID?,
        supportsWakeAssist: Bool
    ) -> String {
        let unroutedName: String
        if let actionID {
            unroutedName = KeepTalkingActionToolDefinition.unroutedActionName(
                toolName,
                actionID: actionID
            )
        } else {
            unroutedName = toolName
        }

        let collapsed = unroutedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "[_\\-]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )

        guard !collapsed.isEmpty else {
            return "using tool"
        }
        guard let ownerNodeID else {
            return collapsed
        }

        if ownerNodeID == config.node {
            return "\(collapsed) on local node"
        }
        let wakeSuffix: String
        if supportsWakeAssist && !onlineNodeIDs().contains(ownerNodeID) {
            wakeSuffix = " while waking the node"
        } else {
            wakeSuffix = ""
        }
        return
            "\(collapsed) on node \(KeepTalkingActionToolDefinition.shortNodeID(ownerNodeID))\(wakeSuffix)"
    }

    func renderCatalogListing(
        _ catalog: KeepTalkingActionToolCatalog,
        routesByFunctionName: [String: KeepTalkingAgentToolRoute],
        contextID: UUID
    ) -> String {
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: routesByFunctionName
        )
        let rows = catalog.definitions.sorted {
            $0.functionName < $1.functionName
        }.map { definition in
            let route = routesByFunctionName[definition.functionName]
            let taggedToolName = actionDisplayName(
                for: definition,
                route: route,
                skillNameByActionID: skillNameByActionID
            )
            return [
                "function_name": definition.functionName,
                "route_kind": routeKind(
                    route
                ),
                "source": definition.source.rawValue,
                "action_id": definition.actionID.uuidString.lowercased(),
                "owner_node_id": definition.ownerNodeID.uuidString.lowercased(),
                "tool_name": taggedToolName,
                "description": definition.description,
            ]
        }

        return jsonString([
            "ok": true,
            "context_id": contextID.uuidString.lowercased(),
            "count": rows.count,
            "tools": rows,
        ])
    }

    func routeKind(_ route: KeepTalkingAgentToolRoute?) -> String {
        guard let route else {
            return "unknown"
        }
        switch route {
            case .actionProxy:
                return "action_proxy"
            case .skillMetadata:
                return "skill_metadata"
            case .skillFileLocal, .skillFileRemote:
                return "skill_file"
        }
    }

    func actionDisplayName(
        for definition: KeepTalkingActionToolDefinition,
        route: KeepTalkingAgentToolRoute?,
        skillNameByActionID: [UUID: String]
    ) -> String {
        if let mcpToolName = definition.mcpToolName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !mcpToolName.isEmpty
        {
            return KeepTalkingActionToolDefinition.routedActionName(
                mcpToolName,
                actionID: definition.actionID
            )
        }

        switch route {
            case .skillMetadata(let context):
                return KeepTalkingActionToolDefinition.routedActionName(
                    context.bundle.name,
                    actionID: definition.actionID
                )
            case .skillFileLocal(let context):
                return KeepTalkingActionToolDefinition.routedActionName(
                    context.bundle.name,
                    actionID: definition.actionID
                )
            case .skillFileRemote(_, _, let skillName):
                return KeepTalkingActionToolDefinition.routedActionName(
                    skillName,
                    actionID: definition.actionID
                )
            case .actionProxy:
                if let skillName = skillNameByActionID[definition.actionID] {
                    return KeepTalkingActionToolDefinition.routedActionName(
                        skillName,
                        actionID: definition.actionID
                    )
                }
                return KeepTalkingActionToolDefinition.routedActionName(
                    "",
                    actionID: definition.actionID,
                    fallbackPrefix: "action"
                )
            case .none:
                return KeepTalkingActionToolDefinition.routedActionName(
                    "",
                    actionID: definition.actionID,
                    fallbackPrefix: "action"
                )
        }
    }

    func skillNamesByActionID(
        routesByFunctionName: [String: KeepTalkingAgentToolRoute]
    ) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for route in routesByFunctionName.values {
            switch route {
                case .skillMetadata(let context):
                    names[context.actionID] = context.bundle.name
                case .skillFileLocal(let context):
                    names[context.actionID] = context.bundle.name
                case .skillFileRemote(let actionID, _, let skillName):
                    names[actionID] = skillName
                default:
                    continue
            }
        }
        return names
    }

    func renderAgentToolPayload(
        functionName: String,
        result: KeepTalkingActionCallResult
    ) -> String {
        let renderedContent = result.content.map { content -> String in
            switch content {
                case .text(let text):
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
