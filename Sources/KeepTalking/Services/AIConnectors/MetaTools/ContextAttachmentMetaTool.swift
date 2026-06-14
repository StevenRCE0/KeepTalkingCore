import AIProxy
import FluentKit
import Foundation

private enum ContextAttachmentReadMode: String {
    case metadata
    case previewText = "preview_text"
    case native
}

extension KeepTalkingClient {
    func renderContextAttachmentListingPayload(
        context: KeepTalkingContext
    ) async throws -> String {
        let contextID = try context.requireID()
        let attachments = try await contextAttachments(in: contextID)
        let blobRecords = try await blobRecordsByBlobID(attachments.map(\.blobID))
        let aliasLookup = try await aliasLookup()
        let rows = attachments.map { attachment in
            contextAttachmentJSONObject(
                attachment,
                blobRecord: blobRecords[attachment.blobID],
                nodeAliasResolver: {
                    aliasLookup.alias(for: .node($0))
                }
            )
        }

        // Voice-call transcripts are surfaced as virtual attachments resolved
        // live from the transcript table (no rows, no blobs) — each one's
        // attachment_id is the call's session id.
        let transcriptRows = try await voiceTranscriptSessionSummaries(in: contextID)
            .map { voiceTranscriptVirtualAttachmentJSON($0, aliasLookup: aliasLookup) }

        return jsonString([
            "ok": true,
            "context_id": contextID.uuidString.lowercased(),
            "count": rows.count + transcriptRows.count,
            "attachments": rows + transcriptRows,
        ])
    }

    func executeContextAttachmentReadToolCall(
        toolCallID: String,
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> [AIMessage] {
        let functionName = Self.contextAttachmentReadToolFunctionName
        let arguments = try decodeToolArguments(rawArguments)
        let attachmentIDText = arguments["attachment_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modeText = arguments["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxCharacters = min(
            max(
                arguments["max_characters"]?.intValue
                    ?? arguments["max_characters"]?.doubleValue.map(Int.init)
                    ?? 4_000,
                128
            ),
            12_000
        )

        guard let attachmentIDText, !attachmentIDText.isEmpty else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "function_name": functionName,
                        "error": "missing_attachment_id",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }
        guard let modeText,
            let mode = ContextAttachmentReadMode(rawValue: modeText)
        else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "function_name": functionName,
                        "attachment_id": attachmentIDText,
                        "error": "invalid_mode",
                        "error_message":
                            "Mode must be one of metadata, preview_text, or native.",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }
        guard let contextID = context.id,
            let attachmentID = KTResourceManifest.resolveAgentHandle(attachmentIDText)?.id
        else {
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "function_name": functionName,
                        "attachment_id": attachmentIDText,
                        "error": "invalid_attachment_id",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        guard let attachment = try await contextAttachment(attachmentID, in: contextID)
        else {
            // Not a stored attachment — it may be a virtual voice-call transcript
            // whose attachment_id is the session id; resolve it from the database.
            if let transcriptResult = try await voiceTranscriptReadResult(
                sessionID: attachmentID,
                contextID: contextID,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return transcriptResult
            }
            // Not a stored/synced attachment — it may be a PRIVATE `.otb` resource
            // in the staged-file store (never broadcast). Resolve it by handle.
            if let stagedResult = await stagedFileReadResult(
                handle: attachmentID,
                mode: mode,
                maxCharacters: maxCharacters,
                toolCallID: toolCallID,
                functionName: functionName
            ) {
                return stagedResult
            }
            return [
                toolMessage(
                    payload: jsonString([
                        "ok": false,
                        "function_name": functionName,
                        "attachment_id": attachmentIDText,
                        "error": "attachment_not_found",
                    ]),
                    toolCallID: toolCallID
                )
            ]
        }

        let blobRecord = try await KeepTalkingBlobRecord.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, attachment.blobID)
        .first()
        let aliasLookup = try await aliasLookup()
        let attachmentJSON = contextAttachmentJSONObject(
            attachment,
            blobRecord: blobRecord,
            nodeAliasResolver: {
                aliasLookup.alias(for: .node($0))
            }
        )

        switch mode {
            case .metadata:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: localStore.database)
                }
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                        ]),
                        toolCallID: toolCallID
                    )
                ]

            case .previewText:
                if let blobRecord {
                    blobRecord.lastAccessedAt = Date()
                    try await blobRecord.save(on: localStore.database)
                }
                let preview = attachmentPreviewText(
                    from: attachment,
                    maxCharacters: maxCharacters
                )
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "has_preview": preview != nil,
                            "max_characters": maxCharacters,
                            "preview_text": preview ?? "",
                        ]),
                        toolCallID: toolCallID
                    )
                ]

            case .native:
                guard let blobRecord else {
                    return [
                        toolMessage(
                            payload: jsonString([
                                "ok": false,
                                "function_name": functionName,
                                "mode": mode.rawValue,
                                "attachment": attachmentJSON,
                                "error": "blob_unavailable",
                                "error_message":
                                    "Attachment bytes are not available locally yet.",
                            ]),
                            toolCallID: toolCallID
                        )
                    ]
                }
                guard blobRecord.availability == .ready else {
                    return [
                        toolMessage(
                            payload: jsonString([
                                "ok": false,
                                "function_name": functionName,
                                "mode": mode.rawValue,
                                "attachment": attachmentJSON,
                                "error": "blob_not_ready",
                                "error_message":
                                    "Attachment bytes exist in metadata but are not ready locally.",
                            ]),
                            toolCallID: toolCallID
                        )
                    ]
                }
                guard attachment.byteCount <= Self.maxAINativeAttachmentBytes else {
                    return [
                        toolMessage(
                            payload: jsonString([
                                "ok": false,
                                "function_name": functionName,
                                "mode": mode.rawValue,
                                "attachment": attachmentJSON,
                                "error": "attachment_too_large",
                                "error_message":
                                    "Attachment exceeds the native AI input budget.",
                                "max_native_bytes":
                                    Self.maxAINativeAttachmentBytes,
                            ]),
                            toolCallID: toolCallID
                        )
                    ]
                }

                let data: Data
                do {
                    data = try blobStore.read(
                        relativePath: blobRecord.relativePath,
                        blobID: attachment.blobID
                    )
                } catch {
                    return [
                        toolMessage(
                            payload: jsonString([
                                "ok": false,
                                "function_name": functionName,
                                "mode": mode.rawValue,
                                "attachment": attachmentJSON,
                                "error": "blob_read_failed",
                                "error_message": error.localizedDescription,
                            ]),
                            toolCallID: toolCallID
                        )
                    ]
                }

                let now = Date()
                blobRecord.lastAccessedAt = now
                blobRecord.aiLastNativeIncludeAt = now
                try await blobRecord.save(on: localStore.database)

                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                        toolCallID: toolCallID
                    ),
                    nativeContextAttachmentUserMessage(
                        attachment: attachment,
                        data: data
                    ),
                ]
        }
    }

    func executeContextAttachmentUpdateMetadataToolCall(
        toolCallID: String,
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        let functionName = Self.contextAttachmentUpdateMetadataToolFunctionName
        let arguments = try decodeToolArguments(rawArguments)

        guard
            let attachmentIDText = arguments["attachment_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !attachmentIDText.isEmpty,
            let attachmentID = KTResourceManifest.resolveAgentHandle(attachmentIDText)?.id,
            let contextID = context.id
        else {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "error": "invalid_attachment_id",
            ])
        }

        guard
            let attachment = try await contextAttachment(
                attachmentID, in: contextID)
        else {
            return jsonString([
                "ok": false,
                "function_name": functionName,
                "attachment_id": attachmentIDText,
                "error": "attachment_not_found",
            ])
        }

        var metadata = attachment.metadata

        if let imageDescription = arguments["image_description"]?.stringValue {
            metadata.imageDescription =
                imageDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let textPreview = arguments["text_preview"]?.stringValue {
            metadata.textPreview =
                textPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let tagsValue = arguments["tags"] {
            if let tags = tagsValue.arrayValue?.compactMap(\.stringValue) {
                metadata.tags = tags
            }
        }

        attachment.metadata = metadata
        try await attachment.save(on: localStore.database)

        return jsonString([
            "ok": true,
            "function_name": functionName,
            "attachment_id": attachmentIDText,
            "metadata": attachmentMetadataJSONObject(metadata),
        ])
    }

    func contextAttachments(
        in contextID: UUID
    ) async throws -> [KeepTalkingContextAttachment] {
        try await KeepTalkingContextAttachment.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)
            .sort(\.$createdAt, .ascending)
            .sort(\.$sortIndex, .ascending)
            .all()
    }

    func contextAttachment(
        _ attachmentID: UUID,
        in contextID: UUID
    ) async throws -> KeepTalkingContextAttachment? {
        try await KeepTalkingContextAttachment.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)
            .filter(\.$id, .equal, attachmentID)
            .first()
    }

    func blobRecordsByBlobID(
        _ blobIDs: [String]
    ) async throws -> [String: KeepTalkingBlobRecord] {
        let uniqueBlobIDs = Array(Set(blobIDs))
        guard !uniqueBlobIDs.isEmpty else {
            return [:]
        }

        let records = try await KeepTalkingBlobRecord.query(
            on: localStore.database
        )
        .filter(\.$id ~~ uniqueBlobIDs)
        .all()

        return Dictionary(
            uniqueKeysWithValues: records.compactMap { record in
                guard let blobID = record.id else {
                    return nil
                }
                return (blobID, record)
            }
        )
    }

    /// Reads a PRIVATE `.otb` resource from the staged-file store by handle (never
    /// an attachment, never synced). Mirrors the attachment read modes so the agent
    /// reads any resource — attachment or otb — by handle through one tool. Returns
    /// nil when the handle isn't a staged file this node owns.
    /// Native user messages for the resources a turn's tool calls PRODUCED, so the
    /// agent CONSUMES them immediately instead of being handed a handle and asking
    /// whether to pull them in. Unified across attachment + otb resources (one
    /// vocabulary): parses `produced_resources` from each execution payload and
    /// injects each readable resource (under the native size cap) as a user message.
    func nativeMessagesForProducedResources(
        from executions: [AIOrchestrator.ToolExecution],
        context: KeepTalkingContext
    ) async -> [AIMessage] {
        guard let contextID = try? context.requireID() else { return [] }
        var messages: [AIMessage] = []
        for execution in executions {
            guard let text = ACTAgentResultExtractor.text(from: execution.messages),
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let resources = json["produced_resources"] as? [[String: Any]]
            else { continue }
            for dict in resources {
                guard let resource = KTResourceManifest.AgentResource(jsonObject: dict)
                else { continue }
                // Skip oversize content — it stays referenceable by handle.
                if let byteCount = resource.byteCount,
                    byteCount > Self.maxAINativeAttachmentBytes
                {
                    continue
                }
                if let message = await nativeMessageForResource(resource, in: contextID) {
                    messages.append(message)
                }
            }
        }
        return messages
    }

    /// Reads a produced resource by handle and renders it as a native user message
    /// whose lead carries the resource's manifest IDENTITY (handle/kind/name) — so
    /// the injected content is bound to its handle, not just a filename. Resolves
    /// attachment handles (synced) and otb handles (private staged store).
    private func nativeMessageForResource(
        _ resource: KTResourceManifest.AgentResource, in contextID: UUID
    ) async -> AIMessage? {
        guard let handle = KTResourceManifest.resolveAgentHandle(resource.handle)?.id
        else { return nil }
        let leadText =
            "[\(resource.transcriptDescription())] — content of this resource follows; "
            + "reference it by its handle (filenames may repeat; the handle is the identity):"
        switch resource.kind {
            case "attachment":
                guard let attachment = try? await contextAttachment(handle, in: contextID),
                    let blobRecord = try? await KeepTalkingBlobRecord.query(
                        on: localStore.database
                    )
                    .filter(\.$id, .equal, attachment.blobID).first(),
                    blobRecord.availability == .ready,
                    let data = try? blobStore.read(
                        relativePath: blobRecord.relativePath, blobID: attachment.blobID)
                else { return nil }
                return .user(
                    parts: attachmentContentParts(
                        filename: resource.name, mimeType: attachment.mimeType, data: data,
                        leadText: leadText))
            case "otb":
                guard
                    let staged = await stagedFileStore.file(
                        handle: handle, callerNodeID: config.node),
                    let data = try? Data(contentsOf: staged.url)
                else { return nil }
                let mime =
                    resource.mimeType
                    ?? MIMEType.preferredMIMEType(
                        forExtension: (resource.name as NSString).pathExtension)
                    ?? "application/octet-stream"
                return .user(
                    parts: attachmentContentParts(
                        filename: resource.name, mimeType: mime, data: data,
                        leadText: leadText))
            default:
                return nil
        }
    }

    fileprivate func stagedFileReadResult(
        handle: UUID,
        mode: ContextAttachmentReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async -> [AIMessage]? {
        guard let staged = await stagedFileStore.file(handle: handle, callerNodeID: config.node)
        else { return nil }
        let handleText = KTResourceManifest.agentHandle(kind: .otb, id: handle)
        let ext = (staged.filename as NSString).pathExtension
        let mime = MIMEType.preferredMIMEType(forExtension: ext) ?? "application/octet-stream"

        switch mode {
            case .metadata:
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "resource": [
                                "handle": handleText,
                                "kind": "otb",
                                "direction": "read",
                                "name": staged.filename,
                                "mime_type": mime,
                                "byte_count": staged.byteCount,
                                "origin": "produced",
                            ],
                        ]),
                        toolCallID: toolCallID)
                ]
            case .previewText:
                let data = (try? Data(contentsOf: staged.url)) ?? Data()
                let text =
                    String(data: data, encoding: .utf8)
                    .map { clipped($0, maxCharacters: maxCharacters) }
                    ?? "<binary file, \(staged.byteCount) bytes — use native mode>"
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "handle": handleText,
                            "name": staged.filename,
                            "content": text,
                        ]),
                        toolCallID: toolCallID)
                ]
            case .native:
                guard let data = try? Data(contentsOf: staged.url) else { return nil }
                let leadText = AIPromptPresets.attachmentInjectionLeadText(
                    filename: staged.filename, isImage: mime.hasPrefix("image/"))
                return [
                    .user(
                        parts: attachmentContentParts(
                            filename: staged.filename, mimeType: mime, data: data,
                            leadText: leadText)),
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "handle": handleText,
                            "name": staged.filename,
                            "note": "file content attached as a user message",
                        ]),
                        toolCallID: toolCallID),
                ]
        }
    }

    func contextAttachmentJSONObject(
        _ attachment: KeepTalkingContextAttachment,
        blobRecord: KeepTalkingBlobRecord?,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> [String: Any] {
        let attachmentUUID = attachment.id ?? UUID()
        let attachmentID = attachmentUUID.uuidString.lowercased()
        return [
            // Unified resource-manifest vocabulary (shared with produced_resources):
            // the agent references the resource by its canonical `KT_<KIND>_<HEX>`
            // handle — the SAME value kt_get_context_attachment / input_handles
            // accept — with a consistent kind / direction / origin across the
            // listing and action-output surfacing.
            "handle": KTResourceManifest.agentHandle(kind: .attachment, id: attachmentUUID),
            "kind": "attachment",
            "direction": "read",
            "origin": "context",
            "attachment_id": attachmentID,
            "parent_message_id":
                attachment.$parentMessage.id?.uuidString.lowercased()
                ?? NSNull(),
            "sender": KeepTalkingActionToolDefinition.conversationSenderTag(
                attachment.sender,
                nodeAliasResolver: nodeAliasResolver
            ),
            "blob_id": attachment.blobID,
            "filename": attachment.filename,
            "mime_type": attachment.mimeType,
            "byte_count": attachment.byteCount,
            "created_at": attachment.createdAt.ISO8601Format(),
            "sort_index": attachment.sortIndex,
            "availability": blobRecord?.availability.rawValue ?? "missing",
            "metadata": attachmentMetadataJSONObject(attachment.metadata),
        ]
    }

    func attachmentMetadataJSONObject(
        _ metadata: KeepTalkingContextAttachmentMetadata
    ) -> [String: Any] {
        var object: [String: Any] = ["tags": metadata.tags]
        if let textPreview = metadata.textPreview, !textPreview.isEmpty {
            object["text_preview"] = textPreview
        }
        if let imageDescription = metadata.imageDescription,
            !imageDescription.isEmpty
        {
            object["image_description"] = imageDescription
        }
        if let width = metadata.width {
            object["width"] = width
        }
        if let height = metadata.height {
            object["height"] = height
        }
        if let pageCount = metadata.pageCount {
            object["page_count"] = pageCount
        }
        return object
    }

    func attachmentPreviewText(
        from attachment: KeepTalkingContextAttachment,
        maxCharacters: Int
    ) -> String? {
        let rawPreview =
            attachment.isImage
            ? attachment.metadata.imageDescription
                ?? attachment.metadata.textPreview
            : attachment.metadata.textPreview
                ?? attachment.metadata.imageDescription
        guard let rawPreview else {
            return nil
        }
        let trimmed = rawPreview.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        return clipped(trimmed, maxCharacters: maxCharacters)
    }

    func nativeContextAttachmentUserMessage(
        attachment: KeepTalkingContextAttachment,
        data: Data
    ) -> AIMessage {
        let leadText = AIPromptPresets.attachmentInjectionLeadText(
            filename: attachment.filename,
            isImage: attachment.isImage
        )

        return .user(
            parts: attachmentContentParts(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: data,
                leadText: leadText
            )
        )
    }

    // MARK: - Voice transcript virtual attachments

    /// JSON row describing a voice-call transcript as a virtual attachment — same
    /// shape as `contextAttachmentJSONObject`, but synthesized from a session
    /// summary (no `KeepTalkingContextAttachment` exists). `attachment_id` is the
    /// session id, which the read tool resolves back to live transcript text.
    func voiceTranscriptVirtualAttachmentJSON(
        _ summary: KeepTalkingVoiceTranscriptSessionSummary,
        aliasLookup: KeepTalkingAliasLookup
    ) -> [String: Any] {
        let names = summary.authors.map {
            aliasLookup.resolve(.node($0)).primary(.uppercase)
        }
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        let sessionID = summary.sessionID.uuidString.lowercased()
        return [
            // Unified resource-manifest vocabulary (shared with the listing +
            // produced_resources). `kind` is the distinct "voice_transcript" family
            // for display; the canonical `handle` carries the session id (the read
            // tool resolves it back to live transcript text via its fallback chain).
            "handle": KTResourceManifest.agentHandle(
                kind: .attachment, id: summary.sessionID),
            "direction": "read",
            "origin": "context",
            "attachment_id": sessionID,
            "parent_message_id": NSNull(),
            "sender": "voice_call",
            "blob_id": NSNull(),
            "filename":
                "Voice call transcript — \(date.string(from: summary.firstAt)) (\(summary.lineCount) lines).txt",
            "mime_type": "text/plain",
            "byte_count": summary.textByteCount,
            "created_at": summary.firstAt.ISO8601Format(),
            "sort_index": 0,
            "availability": "ready",
            "kind": "voice_transcript",
            "metadata": [
                "line_count": summary.lineCount,
                "participants": names,
                "started_at": summary.firstAt.ISO8601Format(),
                "ended_at": summary.lastAt.ISO8601Format(),
            ],
        ]
    }

    /// Resolve a `kt_get_context_attachment` read whose `attachment_id` is a voice
    /// session id. Returns nil when no transcript exists for that session in the
    /// context, so the caller falls through to `attachment_not_found`.
    fileprivate func voiceTranscriptReadResult(
        sessionID: UUID,
        contextID: UUID,
        mode: ContextAttachmentReadMode,
        maxCharacters: Int,
        toolCallID: String,
        functionName: String
    ) async throws -> [AIMessage]? {
        let aliasLookup = try await aliasLookup()
        guard
            let summary = try await voiceTranscriptSessionSummaries(in: contextID)
                .first(where: { $0.sessionID == sessionID })
        else { return nil }

        let attachmentJSON = voiceTranscriptVirtualAttachmentJSON(
            summary, aliasLookup: aliasLookup)

        switch mode {
            case .metadata:
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                        ]),
                        toolCallID: toolCallID
                    )
                ]

            case .previewText:
                let text =
                    (try await renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: maxCharacters
                    )) ?? ""
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "has_preview": !text.isEmpty,
                            "max_characters": maxCharacters,
                            "preview_text": text,
                        ]),
                        toolCallID: toolCallID
                    )
                ]

            case .native:
                let full =
                    (try await renderVoiceTranscript(
                        forSession: sessionID,
                        in: contextID,
                        aliasLookup: aliasLookup,
                        maxCharacters: 24_000
                    )) ?? ""
                let lead =
                    "Voice call transcript you requested (session \(sessionID.uuidString.prefix(8))) — included below. Use it directly."
                return [
                    toolMessage(
                        payload: jsonString([
                            "ok": true,
                            "function_name": functionName,
                            "mode": mode.rawValue,
                            "attachment": attachmentJSON,
                            "native_injected": true,
                        ]),
                        toolCallID: toolCallID
                    ),
                    .user("\(lead)\n\n\(full)"),
                ]
        }
    }
}
