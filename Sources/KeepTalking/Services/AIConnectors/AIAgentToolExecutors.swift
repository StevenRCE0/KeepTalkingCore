import AIProxy
import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    func assistantMessage(
        from turn: AITurnResult
    ) -> AIMessage? {
        let text = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (text?.isEmpty == false)
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        if !hasText, toolCalls == nil {
            return nil
        }
        return AIMessage(
            role: .assistant,
            content: hasText ? .text(text!) : nil,
            toolCalls: toolCalls ?? []
        )
    }

    func executeAgentToolCalls(
        _ toolCalls: [AIToolCall],
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        promptMessageID: UUID?,
        context: KeepTalkingContext,
        agentTurnID: UUID? = nil,
        agentIntention: String? = nil,
        inputHandles: [UUID]? = nil,
        outputHandles: [KeepTalkingActionOutputHandle]? = nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
    ) async throws -> [AIOrchestrator.ToolExecution] {
        var executions: [AIOrchestrator.ToolExecution] = []

        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.name

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
                                rawArguments: toolCall.argumentsJSON,
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
                                        rawArguments: toolCall.argumentsJSON,
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
                                        rawArguments: toolCall.argumentsJSON,
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
                                        rawArguments: toolCall.argumentsJSON,
                                        runtimeCatalog: runtimeCatalog,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.createActionToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeCreateActionToolCall(
                                        rawArguments: toolCall.argumentsJSON,
                                        runtimeCatalog: runtimeCatalog,
                                        context: context,
                                        agentTurnID: agentTurnID
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.evaluateJSToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeEvaluateJSToolCall(
                                        rawArguments: toolCall.argumentsJSON
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
                                        rawArguments: toolCall.argumentsJSON
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
                                rawArguments: toolCall.argumentsJSON,
                                runtimeCatalog: runtimeCatalog,
                                context: context
                            )
                        )
                    )
                    continue
                } else if functionName == Self.updateSideNoteToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeUpdateSideNoteToolCall(
                                        toolCallID: toolCallID,
                                        rawArguments: toolCall.argumentsJSON,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.archiveSideNoteToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeArchiveSideNoteToolCall(
                                        toolCallID: toolCallID,
                                        rawArguments: toolCall.argumentsJSON,
                                        context: context
                                    ),
                                    toolCallID: toolCallID
                                )
                            ]
                        )
                    )
                    continue
                } else if functionName == Self.sendFileToolFunctionName {
                    executions.append(
                        .init(
                            toolCall: toolCall,
                            messages: [
                                toolMessage(
                                    payload: try await executeSendFileToolCall(
                                        rawArguments: toolCall.argumentsJSON,
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
                let route: KeepTalkingAgentToolRoute?
                if let staticRoute = runtimeCatalog.routesByFunctionName[functionName] {
                    route = staticRoute
                } else {
                    route = await runtimeCatalog.lazyRegistry.route(for: functionName)
                }
                var extraInlineMessages: [AIMessage] = []
                switch route {
                    case .actionProxy(let definition):
                        let proxyResult = try await executeActionProxyToolCall(
                            functionName: functionName,
                            definition: definition,
                            rawArguments: toolCall.argumentsJSON,
                            context: context,
                            agentTurnID: agentTurnID,
                            agentIntention: agentIntention,
                            inputHandles: inputHandles,
                            outputHandles: outputHandles,
                            assistantPublisher: assistantPublisher,
                            toolHintPublisher: toolHintPublisher
                        )
                        payload = proxyResult.payload
                        extraInlineMessages = proxyResult.inlineMessages
                    case .skillMetadata(let skillContext):
                        payload = renderSkillMetadataPayload(
                            functionName: functionName,
                            context: skillContext
                        )
                    case .skillFileLocal(let skillContext):
                        let rawArguments = try decodeToolArguments(toolCall.argumentsJSON)
                        let arguments = normalizedSkillFileArguments(rawArguments)
                        payload = renderSkillFilePayload(
                            functionName: functionName,
                            context: skillContext,
                            arguments: arguments
                        )
                    case .skillFileRemote(let actionID, let ownerNodeID, let skillName):
                        let rawArguments = try decodeToolArguments(toolCall.argumentsJSON)
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
                var resultMessages: [AIMessage] = [
                    toolMessage(
                        payload: payload,
                        toolCallID: toolCallID
                    )
                ]
                resultMessages.append(contentsOf: extraInlineMessages)
                executions.append(
                    .init(
                        toolCall: toolCall,
                        messages: resultMessages
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
    ) -> AIMessage {
        .tool(payload, toolCallID: toolCallID)
    }

    struct AgentToolProxyResult {
        let payload: String
        let inlineMessages: [AIMessage]
    }

    func executeActionProxyToolCall(
        functionName: String,
        definition: KeepTalkingActionToolDefinition,
        rawArguments: String,
        context: KeepTalkingContext,
        agentTurnID: UUID? = nil,
        agentIntention: String? = nil,
        inputHandles: [UUID]? = nil,
        outputHandles: [KeepTalkingActionOutputHandle]? = nil,
        assistantPublisher: AIOrchestrator.AssistantPublisher? = nil,
        toolHintPublisher: AIOrchestrator.ToolHintPublisher? = nil
    ) async throws -> AgentToolProxyResult {
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
        if let agentIntention {
            metadata.fields["agent_intention"] = .string(agentIntention)
        }
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

        var actionCall = KeepTalkingActionCall(
            action: definition.actionID,
            arguments: arguments,
            metadata: metadata
        )
        // Staged file inputs the orchestrator relayed for this delegation. They
        // ride on every proxy call the ACT loop makes for the action, so the
        // executor on the owner node resolves them caller-scoped into the
        // action's input staging area.
        if let inputHandles, !inputHandles.isEmpty {
            actionCall.inputHandles = inputHandles
        }
        // Caller-requested outputs the action should produce — round-trip with
        // caller-minted ids so the produced files are summoned/shipped per the
        // chosen persistence (see KeepTalkingIOManager binding / harvest / delivery).
        if let outputHandles, !outputHandles.isEmpty {
            actionCall.outputHandles = outputHandles
        }

        let result = try await dispatchActionCall(
            actionOwner: definition.ownerNodeID,
            call: actionCall,
            context: context,
            agentTurnID: agentTurnID,
            assistantPublisher: assistantPublisher,
            toolHintPublisher: toolHintPublisher
        )
        return renderAgentToolPayload(
            functionName: functionName,
            result: result
        )
    }

    /// Stages a local file onto another node via the OTB preflight and returns
    /// its caller-scoped handle, for the agent to reference in a later
    /// kt_run_action's `input_handles`. Errors are reported as a tool payload
    /// rather than thrown so the agent can react.
    func executeSendFileToolCall(
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        let args = try decodeToolArguments(rawArguments)
        guard
            let path = args["path"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return jsonString(["ok": false, "error": "missing_path"])
        }
        // `target_node` is the current name; `target_node_id` is still accepted
        // so a model working from a cached older schema keeps working.
        guard
            let targetString = (args["target_node"] ?? args["target_node_id"])?.stringValue
        else {
            return jsonString([
                "ok": false, "error": "missing_or_invalid_target_node",
            ])
        }
        // The agent reads nodes by name now, so it must be able to write one
        // back. A raw id still works; a name is resolved against the nodes this
        // node actually knows, and a near-miss is repaired rather than refused.
        //
        // The node list is only loaded when the caller actually passed a name.
        // A UUID resolves without candidates, so the common path — and every
        // existing caller — costs no query at all.
        let needsNameResolution = UUID(uuidString: targetString) == nil
        let knownNodeIDs: [UUID] =
            needsNameResolution ? ((try? await knownNodeIDs()) ?? []) : []
        let target: UUID
        switch UUIDFriendlyName.resolve(targetString, among: knownNodeIDs) {
            case .resolved(let id):
                target = id
            case .corrected(let id, let from, let to):
                target = id
                onLog?("[send-file/target] repaired '\(from)' -> '\(to)'")
            case .ambiguous(let ids):
                return jsonString([
                    "ok": false,
                    "error": "ambiguous_target_node",
                    "candidates": ids.map { $0.friendlyNameToken },
                ])
            case .unknown:
                // Fall back to a bare id for a node we have no row for yet.
                guard let id = UUID(uuidString: targetString) else {
                    return jsonString([
                        "ok": false,
                        "error": "missing_or_invalid_target_node",
                        "hint": "Use a node's name or id exactly as the node listing shows it.",
                        "known_nodes": knownNodeIDs.prefix(20).map { $0.friendlyNameToken },
                    ])
                }
                target = id
        }
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let trimmedName = args["filename"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename =
            (trimmedName?.isEmpty == false)
            ? trimmedName! : fileURL.lastPathComponent
        let mimeType =
            MIMEType.preferredMIMEType(forExtension: fileURL.pathExtension)
            ?? "application/octet-stream"
        do {
            let handle = try await sendFile(
                fileURL: fileURL, filename: filename, mimeType: mimeType,
                to: target, contextID: try context.requireID())
            return jsonString([
                "ok": true,
                "handle": KTResourceManifest.agentHandle(kind: .otb, id: handle),
                "filename": filename,
                "target_node": target.friendlyNameToken,
                "note":
                    "Pass this handle in `input_handles` of a kt_run_action targeting an action on this node.",
            ])
        } catch {
            return jsonString([
                "ok": false,
                "error": "stage_failed",
                "error_message": error.localizedDescription,
            ])
        }
    }

    func parsedActionCallArguments(
        definition: KeepTalkingActionToolDefinition,
        rawArguments: String
    ) throws -> [String: Value] {
        var arguments = try decodeToolArguments(rawArguments)
        if definition.source == .mcp || definition.source == .filesystem,
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
    ) -> AgentToolProxyResult {
        var inlineMessages: [AIMessage] = []
        var renderedContent: [String] = []
        renderedContent.reserveCapacity(result.content.count)
        for (index, content) in result.content.enumerated() {
            switch content {
                case .text(let text, _, _):
                    renderedContent.append(text)
                case .image(let data, let mimeType, _, _):
                    if let part = imagePart(base64: data, mimeType: mimeType) {
                        inlineMessages.append(
                            inlineUserMessage(
                                lead:
                                    "Tool result image #\(index + 1) from \(functionName) (\(mimeType)):",
                                imagePart: part
                            )
                        )
                        renderedContent.append(
                            "<image:\(mimeType) attached as user message>")
                    } else {
                        renderedContent.append("<image:\(mimeType) (failed to inline)>")
                    }
                case .audio(_, let mimeType, _, _):
                    renderedContent.append(
                        "<audio:\(mimeType) (not inlined; provider does not accept audio in tool results)>"
                    )
                case .resource(let resource, _, _):
                    renderedContent.append(
                        renderEmbeddedResource(
                            resource,
                            functionName: functionName,
                            index: index,
                            inlineMessages: &inlineMessages
                        )
                    )
                case .resourceLink(let uri, let name, _, let description, let mimeType, _):
                    var parts: [String] = ["<resource_link uri=\"\(uri)\" name=\"\(name)\""]
                    if let mimeType { parts.append("mime=\"\(mimeType)\"") }
                    if let description, !description.isEmpty {
                        parts.append("description=\"\(description)\"")
                    }
                    renderedContent.append(parts.joined(separator: " ") + ">")
            }
        }

        var payloadObject: [String: Any] = [
            "ok": !result.isError,
            "function_name": functionName,
            "request_id": result.requestID.uuidString.lowercased(),
            "action_id": result.actionID.uuidString.lowercased(),
            "caller_node_id": result.callerNodeID.uuidString.lowercased(),
            "target_node_id": result.targetNodeID.uuidString.lowercased(),
            "error_message": result.errorMessage ?? "",
            "content": renderedContent,
        ]
        // Resources this call PRODUCED, in the unified resource-manifest format —
        // the same vocabulary as the context-attachment listing, so the agent can
        // reference a produced attachment by its `handle` exactly as it references
        // a listed one.
        if let produced = result.producedResources, !produced.isEmpty {
            payloadObject["produced_resources"] = produced.map { $0.jsonObject() }
        }
        // Backfeed: notes a plugin executor narrated while running — the ACT
        // distillation summarizes from the plugin's own account of the work,
        // not just its final content string.
        if let elucidations = result.elucidations, !elucidations.isEmpty {
            payloadObject["elucidations"] = elucidations
        }
        let payload = jsonString(payloadObject)
        return AgentToolProxyResult(payload: payload, inlineMessages: inlineMessages)
    }

    private func imagePart(base64: String, mimeType: String) -> AIMessage.Part? {
        // Extract the raw base64 + mime (input may be a `data:` URL or bare base64),
        // then cap the longest side at 4000px before handing the image to a model.
        var rawBase64 = base64
        var effectiveMime = mimeType
        if base64.hasPrefix("data:") {
            let body = base64.dropFirst("data:".count)
            if let range = body.range(of: ";base64,") {
                effectiveMime = String(body[body.startIndex..<range.lowerBound])
                rawBase64 = String(body[range.upperBound...])
            } else if let url = URL(string: base64) {
                return .imageURL(url)  // unparseable data URL — pass through unchanged
            } else {
                return nil
            }
        }
        let cleaned = rawBase64.replacingOccurrences(of: "\n", with: "")
        // If we can decode the bytes, downscale; otherwise fall back to the raw payload.
        let (outData, outMime): (String, String)
        if let data = Data(base64Encoded: cleaned) {
            let scaled = KeepTalkingImageDownscaler.downscaledIfNeeded(
                data, mimeType: effectiveMime)
            outData = scaled.data.base64EncodedString()
            outMime = scaled.mimeType
        } else {
            outData = cleaned
            outMime = effectiveMime
        }
        guard let url = URL(string: "data:\(outMime);base64,\(outData)") else {
            return nil
        }
        return .imageURL(url)
    }

    private func inlineUserMessage(
        lead: String,
        imagePart: AIMessage.Part
    ) -> AIMessage {
        .user(parts: [.text(lead), imagePart])
    }

    private func renderEmbeddedResource(
        _ resource: MCP.Resource.Content,
        functionName: String,
        index: Int,
        inlineMessages: inout [AIMessage]
    ) -> String {
        let mime = resource.mimeType ?? "application/octet-stream"
        if let text = resource.text, !text.isEmpty {
            return text
        }
        if let blob = resource.blob, !blob.isEmpty {
            if mime.hasPrefix("image/"),
                let part = imagePart(base64: blob, mimeType: mime)
            {
                inlineMessages.append(
                    inlineUserMessage(
                        lead:
                            "Tool result resource #\(index + 1) from \(functionName) (\(resource.uri), \(mime)):",
                        imagePart: part
                    )
                )
                return "<resource uri=\"\(resource.uri)\" mime=\"\(mime)\" attached as user message>"
            }
            let bytes = (Data(base64Encoded: blob)?.count) ?? 0
            return
                "<resource uri=\"\(resource.uri)\" mime=\"\(mime)\" size=\(bytes) (binary, not inlined)>"
        }
        return "<resource uri=\"\(resource.uri)\" mime=\"\(mime)\" (empty)>"
    }

    func renderSkillMetadataPayload(
        functionName: String,
        context: KeepTalkingSkillCatalogContext
    ) -> String {
        // Expose parameter names (not values) so the outer AI knows what's configured.
        // Required-directory / required-env *names* are intentionally surfaced;
        // their *values* (paths and secrets) stay local to the action host and
        // are never serialized into this payload.
        let dirParams = context.bundle.parameters.keys
            .filter { context.bundle.parameters[$0]?.hasPrefix("/") == true }
            .sorted()
        let otherParams = context.bundle.parameters.keys
            .filter { context.bundle.parameters[$0]?.hasPrefix("/") != true }
            .sorted()

        // `context.manifestPath` is the action host's absolute on-disk path
        // (e.g. /Users/alice/Library/Application Support/KeepTalking/Skills/foo/manifest.yaml).
        // Remote callers must not see it — strip to the leaf filename so they
        // still know how the manifest is named without learning where it lives.
        let safeManifestPath: String = {
            guard !context.manifestPath.isEmpty else { return "" }
            return (context.manifestPath as NSString).lastPathComponent
        }()

        // Analysed sandbox scope from the planner. Only field NAMES are surfaced —
        // the actual env values and directory paths live in `bundle.parameters` and
        // stay local to the action host. Network hosts are not secret (already part
        // of the skill manifest) so they're exposed verbatim.
        return jsonString([
            "ok": context.loadError == nil,
            "function_name": functionName,
            "route_kind": "skill_metadata",
            "action_id": context.actionID.uuidString.lowercased(),
            "owner_node_id": context.ownerNodeID.uuidString.lowercased(),
            "skill_name": context.bundle.name,
            "manifest_path": safeManifestPath,
            "manifest_metadata": context.manifestMetadata,
            "references_files": context.referencesFiles,
            "scripts": context.scripts,
            "assets": context.assets,
            "manifest_preview": context.manifestPreview,
            "configured_directories": dirParams,
            "configured_parameters": otherParams,
            "tools_analysed": context.bundle.toolsAnalysed,
            "required_env": context.bundle.requiredEnv.sorted(),
            "required_directories": context.bundle.requiredDirectories.sorted(),
            "required_files": context.bundle.requiredFiles.sorted(),
            "required_network_hosts": context.bundle.requiredNetworkHosts.sorted(),
            "granted_network_hosts": context.bundle.grantedNetworkHosts.sorted(),
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

            let rootPath = context.bundle.directory?.standardizedFileURL.path ?? ""
            let path = fileURL.standardizedFileURL.path
            let relativePath: String
            if !rootPath.isEmpty && path.hasPrefix(rootPath + "/") {
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
    ) async throws -> [AIMessage] {
        let args = try decodeToolArguments(rawArguments)

        guard let actionToken = args["action_id"]?.stringValue else {
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

        // The catalog lists actions by word-name (`amber-swift-koala`), so this
        // tool must accept the exact identifier the listing teaches — the same
        // resolution discipline as kt_run_action: a raw UUID still works, a
        // single mistyped word is repaired, anything ambiguous is refused.
        let candidates = runtimeCatalog.actionStubs.map(\.actionID)
        let actionID: UUID
        switch UUIDFriendlyName.resolve(actionToken, among: candidates) {
            case .resolved(let id):
                actionID = id
            case .corrected(let id, let from, let to):
                actionID = id
                onLog?("[skill-metainfo/action-id] repaired '\(from)' -> '\(to)'")
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
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": false,
                            "error": "unknown_action_id",
                            "action_id": actionToken,
                            "hint": "No action matches that name. Copy an `action:` value "
                                + "from available_actions exactly — the same identifier "
                                + "kt_run_action takes.",
                            "available_skill_actions": runtimeCatalog.actionStubs
                                .filter { $0.kind == .skill }
                                .prefix(40)
                                .map { ["action": $0.actionID.friendlyNameToken, "name": $0.name] },
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
                        "action_id": actionToken,
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
                            "action_id": actionToken,
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

            // Metadata only. kt_skill_metainfo exposes the skill's manifest and
            // instructions to the main agent so it can frame a precise task; it
            // does NOT register the skill's file/metadata/execution tools. Those
            // belong to the ACT agent, which resolves them itself when the main
            // agent delegates via kt_run_action.
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
                            "action_id": actionToken,
                            "error_message": result.errorMessage ?? "no metadata returned",
                        ]),
                        toolCallID: toolCallID
                    )
                ]
            }

            // Metadata only — the remote skill's file/metadata/execution tools
            // are resolved by the ACT agent when the main agent delegates via
            // kt_run_action, not surfaced to the main agent here.
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
        // Materialise the split from the mark just stored. Peers reproduce the
        // same threading from the projection this derivation also feeds, so the
        // marking node and its peers cannot disagree.
        try await applyLocalTurningPointMarkThreading(in: contextID)
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

    // MARK: - Side note handlers

    func executeUpdateSideNoteToolCall(
        toolCallID: String,
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        guard
            let data = rawArguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let key = args["key"],
            let value = args["value"],
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: missing or invalid arguments. Expected {\"key\": string, \"value\": string}."
        }

        // Routed through the client API so the version pair is allocated and
        // the change is pushed — a raw `save()` here would skip both.
        do {
            _ = try await upsertSideNote(
                key: key,
                value: value,
                in: try context.requireID()
            )
        } catch {
            return "Error: could not update side note '\(key)': \(error.localizedDescription)"
        }
        return "Side note '\(key)' updated."
    }

    func executeArchiveSideNoteToolCall(
        toolCallID: String,
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        guard
            let data = rawArguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let key = args["key"],
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: missing or invalid arguments. Expected {\"key\": string}."
        }

        do {
            guard
                try await archiveSideNote(key: key, in: try context.requireID())
                    != nil
            else {
                return "Side note '\(key)' not found."
            }
        } catch {
            return "Error: could not archive side note '\(key)': \(error.localizedDescription)"
        }
        return "Side note '\(key)' archived."
    }
}
