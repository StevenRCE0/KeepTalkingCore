import FluentKit
import Foundation

extension KeepTalkingClient {

    /// Re-indexes all threads for `contextID` and prunes any store entries that no
    /// longer correspond to a known thread. Fire-and-forget.
    public static func autoEmbedContext(
        _ contextID: UUID,
        on database: any Database,
        semanticStore: any KeepTalkingSemanticStore
    ) {
        Task.detached(priority: .background) {
            let contextThreads = (try? await KeepTalkingThread.query(on: database)
                .filter(\.$context.$id == contextID)
                .all()) ?? []
            let knownIDs = Set(
                ((try? await KeepTalkingThread.query(on: database).all()) ?? []).compactMap(\.id)
            )
            let indexed = (try? await semanticStore.allDocuments()) ?? []
            let indexedIDs = Set(indexed.map(\.id))

            for staleID in indexedIDs.subtracting(knownIDs) {
                try? await semanticStore.removeThread(id: staleID)
            }
            for thread in contextThreads {
                guard let threadID = thread.id else { continue }
                let text = (try? await threadDocumentText(for: thread, on: database)) ?? ""
                guard !text.isEmpty else { continue }
                if indexedIDs.contains(threadID) {
                    try? await semanticStore.updateThread(id: threadID, text: text)
                } else {
                    try? await semanticStore.indexThread(id: threadID, text: text)
                }
            }
        }
    }

    /// Removes a single thread from the semantic store. Fire-and-forget.
    public static func autoDeindex(
        _ threadID: UUID,
        semanticStore: any KeepTalkingSemanticStore
    ) {
        Task.detached(priority: .background) {
            try? await semanticStore.removeThread(id: threadID)
        }
    }

    /// Builds the indexable text content for a thread.
    /// Prefers the summary if available; otherwise concatenates
    /// non-chitter-chatter message content within the thread's range,
    /// plus attachment metadata for any attachments in that range.
    public static func threadDocumentText(
        for thread: KeepTalkingThread,
        on database: any Database
    ) async throws -> String {
        if let summary = thread.summary,
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return summary
        }

        let db = database
        let contextID = thread.$context.id

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        let chitterSet = Set(thread.chitterChatter)

        guard
            let range = thread.resolvedMessageRange(in: messages)
        else {
            return ""
        }

        let rangeMessages = messages[range]
        let messageIDs = Set(rangeMessages.compactMap(\.id))

        let messageText = rangeMessages
            .filter { msg in
                guard let msgID = msg.id else { return true }
                return !chitterSet.contains(msgID)
            }
            .filter { $0.type == .message }
            .map(\.content)
            .joined(separator: "\n")

        // Append attachment metadata for attachments parented to messages
        // in this range. Uses metadata only — never touches blob data.
        let attachments = try await KeepTalkingContextAttachment.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
            .filter { attachment in
                guard let parentID = attachment.$parentMessage.id else {
                    return false
                }
                return messageIDs.contains(parentID)
            }

        guard !attachments.isEmpty else {
            return messageText
        }

        let attachmentLines = attachments.map { attachment in
            attachmentMetadataLine(attachment)
        }

        return messageText + "\n\n[Attachments]\n"
            + attachmentLines.joined(separator: "\n")
    }

    private static func attachmentMetadataLine(
        _ attachment: KeepTalkingContextAttachment
    ) -> String {
        var parts = ["\(attachment.filename) (\(attachment.mimeType))"]
        if let desc = attachment.metadata.imageDescription,
            !desc.isEmpty
        {
            parts.append("description: \(desc)")
        }
        if let preview = attachment.metadata.textPreview,
            !preview.isEmpty
        {
            let truncated =
                preview.count > 200
                ? String(preview.prefix(200)) + "…" : preview
            parts.append("preview: \(truncated)")
        }
        if !attachment.metadata.tags.isEmpty {
            parts.append(
                "tags: \(attachment.metadata.tags.joined(separator: ", "))")
        }
        return "- " + parts.joined(separator: " | ")
    }
}
