import Crypto
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
        Task(priority: .background) {
            try? await reconcileContextThreads(
                contextID,
                on: database,
                semanticStore: semanticStore
            )
        }
    }

    /// Removes a single thread from the semantic store. Fire-and-forget.
    public static func autoDeindex(
        _ threadID: UUID,
        semanticStore: any KeepTalkingSemanticStore
    ) {
        Task(priority: .background) {
            try? await semanticStore.removeThread(id: threadID)
        }
    }

    /// Reconciles one context from its current persisted thread rows.
    ///
    /// Every document is attempted even if another one fails. The first error
    /// is rethrown after the pass so a caller can retry the whole idempotent
    /// reconciliation later. A retry always reloads thread state and therefore
    /// incorporates edits made after the event that requested reconciliation.
    public static func reconcileContextThreads(
        _ contextID: UUID,
        on database: any Database,
        semanticStore: any KeepTalkingSemanticStore
    ) async throws {
        SemanticIndexTrace.info("context reconcile started context=\(contextID)")
        let contextThreads = try await KeepTalkingThread.query(on: database)
            .filter(\.$context.$id == contextID)
            .all()
        let knownIDs = Set(
            try await KeepTalkingThread.query(on: database).all().compactMap(\.id)
        )
        let indexed = try await semanticStore.allDocuments()
        let indexedTextByID = Dictionary(
            indexed.map { ($0.id, $0.text) },
            uniquingKeysWith: { _, latest in latest }
        )
        var firstFailure: (any Error)?

        for staleID in Set(indexedTextByID.keys).subtracting(knownIDs) {
            do {
                SemanticIndexTrace.info("context reconcile remove stale id=\(staleID)")
                try await semanticStore.removeThread(id: staleID)
            } catch {
                firstFailure = firstFailure ?? error
                SemanticIndexTrace.error(
                    "context reconcile remove failed id=\(staleID) error=\(error)"
                )
            }
        }

        for thread in contextThreads {
            guard let threadID = thread.id else { continue }
            do {
                let text = try await threadDocumentText(for: thread, on: database)
                let digest = semanticDocumentDigest(for: text)
                let indexedText = indexedTextByID[threadID]
                if thread.semanticDocumentDigest == digest, indexedText == text {
                    continue
                }

                if text.isEmpty {
                    if indexedText != nil {
                        SemanticIndexTrace.info("context reconcile remove empty id=\(threadID)")
                        try await semanticStore.removeThread(id: threadID)
                    }
                } else if indexedText == text {
                    SemanticIndexTrace.info("context reconcile repair marker id=\(threadID)")
                } else if indexedText != nil {
                    SemanticIndexTrace.info(
                        "context reconcile update id=\(threadID) characters=\(text.count)"
                    )
                    try await semanticStore.updateThread(id: threadID, text: text)
                } else {
                    SemanticIndexTrace.info(
                        "context reconcile index id=\(threadID) characters=\(text.count)"
                    )
                    try await semanticStore.indexThread(id: threadID, text: text)
                }
                try await recordSemanticDocumentDigest(
                    digest,
                    for: threadID,
                    on: database
                )
            } catch {
                firstFailure = firstFailure ?? error
                SemanticIndexTrace.error(
                    "context reconcile document failed id=\(threadID) error=\(error)"
                )
            }
        }

        if let firstFailure {
            SemanticIndexTrace.error(
                "context reconcile incomplete context=\(contextID) error=\(firstFailure)"
            )
            throw firstFailure
        }
        SemanticIndexTrace.info("context reconcile completed context=\(contextID)")
    }

    /// Reconciles the entire semantic index against the thread store across all
    /// contexts: indexes any thread that's missing (e.g. one committed before the
    /// store finished loading), refreshes the text of already-indexed threads, and
    /// prunes documents whose thread no longer exists.
    ///
    /// Unlike ``autoEmbedContext(_:on:semanticStore:)`` this awaits completion, so
    /// a caller (e.g. a "Reindex" button) can report progress and refresh counts.
    /// - Parameter onProgress: invoked after each thread with `(completed, total)`.
    ///   Use it to surface progress and to drain the embedder's memory between
    ///   documents — bulk embedding is the heaviest part and benefits from a
    ///   periodic cache release.
    public static func reindexAllThreads(
        on database: any Database,
        semanticStore: any KeepTalkingSemanticStore,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws {
        SemanticIndexTrace.info("manual reindex database read started")
        let allThreads = try await KeepTalkingThread.query(on: database).all()
        let knownIDs = Set(allThreads.compactMap(\.id))
        SemanticIndexTrace.info("manual reindex database read completed threads=\(allThreads.count)")

        let indexed = try await semanticStore.allDocuments()
        let indexedIDs = Set(indexed.map(\.id))
        let staleIDs = indexedIDs.subtracting(knownIDs)
        SemanticIndexTrace.info(
            "manual reindex index read completed indexed=\(indexed.count) stale=\(staleIDs.count)"
        )

        for staleID in staleIDs {
            SemanticIndexTrace.info("manual reindex remove id=\(staleID)")
            try await semanticStore.removeThread(id: staleID)
        }

        // Sequential on purpose: embedding is GPU-bound, so parallelism would
        // spike memory. Yield + onProgress between documents lets the caller keep
        // the footprint flat (drain the embedder cache) and report progress.
        let total = allThreads.count
        var completed = 0
        for thread in allThreads {
            completed += 1
            if let threadID = thread.id {
                let text = try await threadDocumentText(for: thread, on: database)
                let digest = semanticDocumentDigest(for: text)
                if !text.isEmpty {
                    let action = indexedIDs.contains(threadID) ? "update" : "index"
                    SemanticIndexTrace.info(
                        "manual reindex \(action) id=\(threadID) characters=\(text.count) progress=\(completed)/\(total)"
                    )
                    if indexedIDs.contains(threadID) {
                        try await semanticStore.updateThread(id: threadID, text: text)
                    } else {
                        try await semanticStore.indexThread(id: threadID, text: text)
                    }
                } else {
                    SemanticIndexTrace.info(
                        "manual reindex skipped empty id=\(threadID) progress=\(completed)/\(total)"
                    )
                    if indexedIDs.contains(threadID) {
                        try await semanticStore.removeThread(id: threadID)
                    }
                }
                try await recordSemanticDocumentDigest(
                    digest,
                    for: threadID,
                    on: database
                )
            }
            await Task.yield()
            await onProgress?(completed, total)
        }
        SemanticIndexTrace.info("manual reindex completed total=\(total)")
    }

    /// Builds the indexable text content for a thread.
    /// Includes the full thread transcript, prefixed by the thread summary when
    /// available, plus attachment metadata for any attachments in range.
    public static func threadDocumentText(
        for thread: KeepTalkingThread,
        on database: any Database
    ) async throws -> String {
        let db = database
        let contextID = thread.$context.id
        let topic = normalizedDocumentSummary(for: thread)

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

        let messageText =
            rangeMessages
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

        let attachmentText: String
        if attachments.isEmpty {
            attachmentText = ""
        } else {
            let attachmentLines = attachments.map { attachment in
                attachmentMetadataLine(attachment)
            }
            attachmentText = "[Attachments]\n" + attachmentLines.joined(separator: "\n")
        }

        let body = [messageText, attachmentText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if let topic {
            guard !body.isEmpty else { return topic }
            return "Topic: \(topic)\n\n" + body
        }

        return body
    }

    private static func normalizedDocumentSummary(for thread: KeepTalkingThread) -> String? {
        guard let summary = thread.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty
        else {
            return nil
        }
        return summary
    }

    private static func semanticDocumentDigest(for text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }

    private static func recordSemanticDocumentDigest(
        _ digest: String,
        for threadID: UUID,
        on database: any Database
    ) async throws {
        try await KeepTalkingThread.query(on: database)
            .filter(\.$id == threadID)
            .set(\.$semanticDocumentDigest, to: digest)
            .update()
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
