import Foundation

extension KTResourceManifest {
    static func contextAttachmentJSONObject(
        _ attachment: KeepTalkingContextAttachment,
        blobRecord: KeepTalkingBlobRecord?,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> [String: Any] {
        let attachmentUUID = attachment.id ?? UUID()
        return [
            "handle": agentHandle(kind: .attachment, id: attachmentUUID),
            "kind": "attachment",
            "direction": "read",
            "origin": "context",
            "attachment_id": attachmentUUID.uuidString.lowercased(),
            "parent_message_id":
                attachment.$parentMessage.id?.uuidString.lowercased()
                ?? NSNull(),
            "sender": KeepTalkingActionToolDefinition.conversationSenderTag(
                attachment.sender,
                nodeAliasResolver: nodeAliasResolver),
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

    static func attachmentMetadataJSONObject(
        _ metadata: KeepTalkingContextAttachmentMetadata
    ) -> [String: Any] {
        var object: [String: Any] = ["tags": metadata.tags]
        if let textPreview = metadata.textPreview, !textPreview.isEmpty {
            object["text_preview"] = textPreview
        }
        if let imageDescription = metadata.imageDescription, !imageDescription.isEmpty {
            object["image_description"] = imageDescription
        }
        if let width = metadata.width { object["width"] = width }
        if let height = metadata.height { object["height"] = height }
        if let pageCount = metadata.pageCount { object["page_count"] = pageCount }
        return object
    }

    static func attachmentPreviewText(
        from attachment: KeepTalkingContextAttachment,
        maxCharacters: Int,
        clip: (String, Int) -> String
    ) -> String? {
        let rawPreview =
            attachment.isImage
            ? attachment.metadata.imageDescription ?? attachment.metadata.textPreview
            : attachment.metadata.textPreview ?? attachment.metadata.imageDescription
        guard
            let trimmed = rawPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return clip(trimmed, maxCharacters)
    }

    static func voiceTranscriptVirtualAttachmentJSON(
        _ summary: KeepTalkingVoiceTranscriptSessionSummary,
        aliasLookup: KeepTalkingAliasLookup
    ) -> [String: Any] {
        // Handles, never aliases — an alias cannot be resolved back to a node.
        let names = summary.authors.map(\.friendlyNameToken)
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        let sessionID = summary.sessionID.uuidString.lowercased()
        return [
            "handle": agentHandle(kind: .attachment, id: summary.sessionID),
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
}
