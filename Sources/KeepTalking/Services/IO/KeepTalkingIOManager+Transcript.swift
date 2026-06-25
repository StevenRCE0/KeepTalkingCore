import AIProxy
import FluentKit
import Foundation

extension KeepTalkingIOManager {
    private func clipped(_ text: String, maxCharacters: Int) -> String {
        client.clipped(text, maxCharacters: maxCharacters)
    }

    private func tool(_ fields: [String: Any], _ toolCallID: String) -> AIMessage {
        client.toolMessage(payload: client.jsonString(fields), toolCallID: toolCallID)
    }

    private func toolResult(_ fields: [String: Any], _ toolCallID: String) -> [AIMessage] {
        [tool(fields, toolCallID)]
    }

    private func failedToolResult(
        _ error: String,
        functionName: String,
        toolCallID: String,
        fields: [String: Any] = [:]
    ) -> [AIMessage] {
        var payload = fields
        payload["ok"] = false
        payload["function_name"] = functionName
        payload["error"] = error
        return toolResult(payload, toolCallID)
    }

    private func readTool(
        functionName: String,
        mode: ReadMode,
        toolCallID: String,
        fields: [String: Any]
    ) -> AIMessage {
        var payload = fields
        payload["ok"] = true
        payload["function_name"] = functionName
        payload["mode"] = mode.rawValue
        return tool(payload, toolCallID)
    }

    private func readToolResult(
        functionName: String,
        mode: ReadMode,
        toolCallID: String,
        fields: [String: Any]
    ) -> [AIMessage] {
        [readTool(functionName: functionName, mode: mode, toolCallID: toolCallID, fields: fields)]
    }

    private func nativeUserMessage(
        filename: String,
        mimeType: String,
        data: Data,
        leadText: String
    ) -> AIMessage {
        .user(
            parts: client.attachmentContentParts(
                filename: filename,
                mimeType: mimeType,
                data: data,
                leadText: leadText))
    }

    private func nativeAttachmentUserMessage(
        attachment: KeepTalkingContextAttachment,
        data: Data
    ) -> AIMessage {
        nativeUserMessage(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            data: data,
            leadText: AIPromptPresets.attachmentInjectionLeadText(
                filename: attachment.filename,
                isImage: attachment.isImage))
    }

    func readContextResource(
        handleText: String,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String,
        context: KeepTalkingContext
    ) async throws -> [AIMessage] {
        guard let contextID = context.id,
            let handle = KTResourceManifest.resolveAgentHandle(handleText)?.id
        else {
            return failedToolResult(
                "invalid_attachment_id",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: ["attachment_id": handleText])
        }

        guard let attachment = try await client.contextAttachment(handle, in: contextID)
        else {
            if let transcriptResult = try await voiceTranscriptReadResult(
                sessionID: handle,
                contextID: contextID,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return transcriptResult
            }
            if let stagedResult = await stagedFileReadResult(
                handle: handle,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return stagedResult
            }
            return failedToolResult(
                "attachment_not_found",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: ["attachment_id": handleText])
        }

        let blobRecord = try await KeepTalkingBlobRecord.query(on: client.localStore.database)
            .filter(\.$id, .equal, attachment.blobID)
            .first()
        let aliasLookup = try await client.aliasLookup()
        let attachmentJSON = KTResourceManifest.contextAttachmentJSONObject(
            attachment,
            blobRecord: blobRecord,
            nodeAliasResolver: { aliasLookup.alias(for: .node($0)) }
        )

        switch mode {
            case .metadata:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: client.localStore.database)
                }
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON
                    ])

            case .previewText:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: client.localStore.database)
                }
                let preview = KTResourceManifest.attachmentPreviewText(
                    from: attachment,
                    maxCharacters: maxCharacters,
                    clip: clipped)
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON,
                        "has_preview": preview != nil,
                        "max_characters": maxCharacters,
                        "preview_text": preview ?? "",
                    ])

            case .native:
                guard let blobRecord else {
                    return failedToolResult(
                        "blob_unavailable",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": "Attachment bytes are not available locally yet.",
                        ])
                }
                guard blobRecord.availability == .ready else {
                    return failedToolResult(
                        "blob_not_ready",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message":
                                "Attachment bytes exist in metadata but are not ready locally.",
                        ])
                }
                guard attachment.byteCount <= KeepTalkingClient.maxAINativeAttachmentBytes else {
                    return failedToolResult(
                        "attachment_too_large",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": "Attachment exceeds the native AI input budget.",
                            "max_native_bytes": KeepTalkingClient.maxAINativeAttachmentBytes,
                        ])
                }

                let data: Data
                do {
                    data = try client.blobStore.read(
                        relativePath: blobRecord.relativePath,
                        blobID: attachment.blobID
                    )
                } catch {
                    return failedToolResult(
                        "blob_read_failed",
                        functionName: functionName,
                        toolCallID: toolCallID,
                        fields: [
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "error_message": error.localizedDescription,
                        ])
                }

                let now = Date()
                blobRecord.lastAccessedAt = now
                blobRecord.aiLastNativeIncludeAt = now
                try await blobRecord.save(on: client.localStore.database)

                return [
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                    nativeAttachmentUserMessage(
                        attachment: attachment,
                        data: data
                    ),
                ]
        }
    }

    private func voiceTranscriptReadResult(
        sessionID: UUID,
        contextID: UUID,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async throws -> [AIMessage]? {
        let aliasLookup = try await client.aliasLookup()
        guard
            let summary = try await client.voiceTranscriptSessionSummaries(in: contextID)
                .first(where: { $0.sessionID == sessionID })
        else { return nil }

        let attachmentJSON = KTResourceManifest.voiceTranscriptVirtualAttachmentJSON(
            summary, aliasLookup: aliasLookup)

        switch mode {
            case .metadata:
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON
                    ])

            case .previewText:
                let text =
                    (try await client.renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: maxCharacters
                    )) ?? ""
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "attachment": attachmentJSON,
                        "has_preview": !text.isEmpty,
                        "max_characters": maxCharacters,
                        "preview_text": text,
                    ])

            case .native:
                let full =
                    (try await client.renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: 24_000
                    )) ?? ""
                let lead =
                    "Voice call transcript you requested (session \(sessionID.uuidString.prefix(8))) — included below. Use it directly."
                return [
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                    .user("\(lead)\n\n\(full)"),
                ]
        }
    }

    private func stagedFileReadResult(
        handle: UUID,
        mode: ReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async -> [AIMessage]? {
        guard let staged = await stagedResource(handle: handle) else { return nil }

        switch mode {
            case .metadata:
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "resource": staged.manifestJSON
                    ])
            case .previewText:
                let data = (try? Data(contentsOf: staged.url)) ?? Data()
                let text =
                    String(data: data, encoding: .utf8)
                    .map { clipped($0, maxCharacters: maxCharacters) }
                    ?? "<binary file, \(staged.byteCount) bytes — use native mode>"
                return readToolResult(
                    functionName: functionName, mode: mode, toolCallID: toolCallID,
                    fields: [
                        "handle": staged.handleText,
                        "name": staged.filename,
                        "content": text,
                    ])
            case .native:
                guard let data = try? Data(contentsOf: staged.url) else { return nil }
                let leadText = AIPromptPresets.attachmentInjectionLeadText(
                    filename: staged.filename,
                    isImage: staged.mimeType.hasPrefix("image/"))
                return [
                    nativeUserMessage(
                        filename: staged.filename,
                        mimeType: staged.mimeType,
                        data: data,
                        leadText: leadText),
                    readTool(
                        functionName: functionName, mode: mode, toolCallID: toolCallID,
                        fields: [
                            "handle": staged.handleText,
                            "name": staged.filename,
                            "note": "file content attached as a user message",
                        ]),
                ]
        }
    }

    func transcriptMessagesForProducedResources(
        from executions: [AIOrchestrator.ToolExecution],
        context: KeepTalkingContext
    ) async -> [AIMessage] {
        guard let contextID = try? context.requireID() else { return [] }
        var messages: [AIMessage] = []
        for resource in producedResources(from: executions) {
            if let byteCount = resource.byteCount,
                byteCount > KeepTalkingClient.maxAINativeAttachmentBytes
            {
                client.rtcClient.debug(
                    "[io/inject] skipped oversized produced resource handle=\(resource.handle) bytes=\(byteCount)"
                )
                continue
            }
            if let message = await transcriptMessage(for: resource, contextID: contextID) {
                messages.append(message)
            } else {
                client.rtcClient.debug(
                    "[io/inject] skipped unreadable produced resource handle=\(resource.handle) kind=\(resource.kind)"
                )
            }
        }
        return messages
    }

    private func producedResources(
        from executions: [AIOrchestrator.ToolExecution]
    ) -> [KTResourceManifest.AgentResource] {
        executions.flatMap { execution -> [KTResourceManifest.AgentResource] in
            guard let text = ACTAgentResultExtractor.text(from: execution.messages),
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let resources = json["produced_resources"] as? [[String: Any]]
            else { return [] }
            return resources.compactMap(KTResourceManifest.AgentResource.init(jsonObject:))
        }
    }

    private func transcriptMessage(
        for resource: KTResourceManifest.AgentResource,
        contextID: UUID
    ) async -> AIMessage? {
        guard let handle = KTResourceManifest.resolveAgentHandle(resource.handle)?.id
        else { return nil }
        let leadText = resource.injectedContentLeadText

        switch resource.kind {
            case "attachment":
                guard let attachment = try? await client.contextAttachment(handle, in: contextID),
                    let blobRecord = try? await KeepTalkingBlobRecord.query(
                        on: client.localStore.database
                    )
                    .filter(\.$id, .equal, attachment.blobID).first(),
                    blobRecord.availability == .ready,
                    let data = try? client.blobStore.read(
                        relativePath: blobRecord.relativePath, blobID: attachment.blobID)
                else { return nil }
                return nativeUserMessage(
                    filename: resource.name,
                    mimeType: attachment.mimeType,
                    data: data,
                    leadText: leadText)

            case "otb":
                guard
                    let staged = await stagedResource(handle: handle, filename: resource.name),
                    let data = try? Data(contentsOf: staged.url)
                else { return nil }
                return nativeUserMessage(
                    filename: staged.filename,
                    mimeType: resource.mimeType ?? staged.mimeType,
                    data: data,
                    leadText: leadText)

            default:
                return nil
        }
    }
}
