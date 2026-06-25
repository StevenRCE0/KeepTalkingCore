import AIProxy
import FluentKit
import Foundation

extension KeepTalkingClient {
    func renderContextAttachmentListingPayload(
        context: KeepTalkingContext
    ) async throws -> String {
        let contextID = try context.requireID()
        let attachments = try await contextAttachments(in: contextID)
        let blobRecords = try await blobRecordsByBlobID(attachments.map(\.blobID))
        let aliasLookup = try await aliasLookup()
        let rows = attachments.map { attachment in
            KTResourceManifest.contextAttachmentJSONObject(
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
            .map { KTResourceManifest.voiceTranscriptVirtualAttachmentJSON($0, aliasLookup: aliasLookup) }

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
            let mode = KeepTalkingIOManager.ReadMode(rawValue: modeText)
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
        return try await KeepTalkingIOManager(client: self).readContextResource(
            handleText: attachmentIDText,
            mode: mode,
            maxCharacters: maxCharacters,
            toolCallID: toolCallID,
            functionName: functionName,
            context: context)
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
            "metadata": KTResourceManifest.attachmentMetadataJSONObject(metadata),
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

}
