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

        return jsonString([
            "ok": true,
            "context_id": contextID.uuidString.lowercased(),
            "count": rows.count,
            "attachments": rows,
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
            let attachmentID = UUID(uuidString: attachmentIDText)
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
            let attachmentID = UUID(uuidString: attachmentIDText),
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

    func contextAttachmentJSONObject(
        _ attachment: KeepTalkingContextAttachment,
        blobRecord: KeepTalkingBlobRecord?,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> [String: Any] {
        [
            "attachment_id": attachment.id?.uuidString.lowercased() ?? "",
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
}
