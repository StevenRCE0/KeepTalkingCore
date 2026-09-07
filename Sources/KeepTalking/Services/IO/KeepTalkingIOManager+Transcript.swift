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
        guard let contextID = context.id else {
            return failedToolResult(
                "invalid_handle",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: ["handle": handleText])
        }

        let handle: UUID
        switch await resolveResourceHandle(handleText, contextID: contextID) {
            case .resolved(let id):
                handle = id
            case .corrected(let id, let from, let to):
                client.onLog?("[io/read] repaired handle \(from) -> \(to)")
                handle = id
            case .ambiguous(let ids):
                return failedToolResult(
                    "ambiguous_handle",
                    functionName: functionName,
                    toolCallID: toolCallID,
                    fields: [
                        "handle": handleText,
                        "match_count": ids.count,
                        "error_message":
                            "That handle matches \(ids.count) live resources. Re-read it from "
                            + "the attachment listing or from the producing call's "
                            + "produced_resources and pass it back exactly.",
                    ])
            case .unknown:
                return unresolvedHandleResult(
                    handleText: handleText,
                    functionName: functionName,
                    toolCallID: toolCallID)
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
            return await unavailableResourceResult(
                handle: handle,
                handleText: handleText,
                functionName: functionName,
                toolCallID: toolCallID)
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

    /// A handle that matched nothing live.
    ///
    /// For an OTB handle that is a NORMAL end of life — private one-time blobs
    /// are reaped on a short TTL — so name that precisely instead of the generic
    /// "not found" that sends the agent hunting through the attachment listing
    /// for something that was never in it.
    private func unresolvedHandleResult(
        handleText: String,
        functionName: String,
        toolCallID: String
    ) -> [AIMessage] {
        let kind = KTResourceManifest.parseAgentHandleCode(handleText)?.kind
        if kind == .otb {
            return failedToolResult(
                "otb_unavailable",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: [
                    "handle": handleText,
                    "ttl_seconds": Int(KeepTalkingStagingIOStore.defaultTTL),
                    "error_message":
                        "This one-time blob is no longer readable on this node. It expired "
                        + "(they are kept about \(Int(KeepTalkingStagingIOStore.defaultTTL / 60)) "
                        + "minutes after they are produced), was never staged here, or belongs "
                        + "to another peer. Ask for the file again, or re-run the producing "
                        + "action with outputs[].persistence = \"attachment\" so it lands as a "
                        + "durable context attachment instead.",
                ])
        }
        // A well-formed attachment handle, or a bare UUID: it named something,
        // there is just nothing here under it.
        let trimmed = handleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != nil || UUID(uuidString: trimmed) != nil {
            return failedToolResult(
                "attachment_not_found",
                functionName: functionName,
                toolCallID: toolCallID,
                fields: [
                    "handle": handleText,
                    "error_message":
                        "No attachment with that handle in this conversation. "
                        + "Re-read the handle from the attachment listing.",
                ])
        }
        return failedToolResult(
            "invalid_handle",
            functionName: functionName,
            toolCallID: toolCallID,
            fields: [
                "handle": handleText,
                "error_message":
                    "Not a resource handle. A handle looks like "
                    + "KT_ATTACHMENT_<WORD_WORD_WORD> or KT_OTB_<WORD_WORD_WORD> — "
                    + "never a filename and never a path.",
            ])
    }

    /// The handle named something concrete, but nothing here can serve it. The
    /// staging store knows which of the three it is, so say which — a leaked
    /// handle from another peer and an expired one are different problems and
    /// only one of them is worth retrying.
    private func unavailableResourceResult(
        handle: UUID,
        handleText: String,
        functionName: String,
        toolCallID: String
    ) async -> [AIMessage] {
        switch await stagedHandleStatus(handle) {
            case .foreign(let owner):
                return failedToolResult(
                    "otb_foreign_handle",
                    functionName: functionName,
                    toolCallID: toolCallID,
                    fields: [
                        "handle": handleText,
                        "owner_node": owner.uuidString.lowercased(),
                        "error_message":
                            "That one-time blob belongs to a different peer and cannot be read "
                            + "from here. OTB handles are private and point-to-point — having "
                            + "the handle does not grant access. Ask the peer that holds it to "
                            + "send the file, or re-run the producing action with "
                            + "outputs[].persistence = \"attachment\".",
                    ])
            case .bytesVanished:
                return failedToolResult(
                    "otb_bytes_vanished",
                    functionName: functionName,
                    toolCallID: toolCallID,
                    fields: [
                        "handle": handleText,
                        "error_message":
                            "That one-time blob is registered but its bytes are gone from disk "
                            + "(cleaned up underneath us). Ask for the file again.",
                    ])
            case .absent, .present:
                return unresolvedHandleResult(
                    handleText: handleText,
                    functionName: functionName,
                    toolCallID: toolCallID)
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
        // `jsonObject()` does not carry resourceID, so a resource parsed back out
        // of a tool payload (`init(jsonObject:)`) arrives with ONLY its word-code
        // handle — which the candidate-less resolver is documented to refuse.
        // Resolving against the live candidate set is what makes a produced OTB
        // injectable at all; without it every one was logged "unreadable" while
        // its bytes sat staged on disk.
        var resolved = resource.resourceID
        if resolved == nil {
            resolved = await resolveResourceHandle(
                resource.handle, contextID: contextID
            ).settledID
        }
        guard let handle = resolved else { return nil }
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
