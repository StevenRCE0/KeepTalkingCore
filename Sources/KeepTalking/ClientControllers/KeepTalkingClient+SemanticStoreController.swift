import Crypto
import FluentKit
import Foundation

extension KeepTalkingClient {

    /// Re-indexes all threads for `contextID` and prunes any store entries that no
    /// longer correspond to a known thread. Fire-and-forget.
    ///
    /// The work is detached onto a background-priority `Task` and any thrown error
    /// is discarded; use `reconcileContextThreads(_:on:semanticStore:)` directly
    /// when the caller needs to await completion or observe failures.
    /// - Parameters:
    ///   - contextID: Context whose threads are reconciled against the index.
    ///   - database: Database the thread, message and attachment rows are read
    ///     from, and where each thread's semantic document digest is recorded.
    ///   - semanticStore: Store that receives the resulting index, update and
    ///     remove calls.
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
    ///
    /// The removal is detached onto a background-priority `Task` and any thrown
    /// error is discarded.
    /// - Parameters:
    ///   - threadID: Thread to remove. A thread's UUID is also its document ID in
    ///     the store.
    ///   - semanticStore: Store the document is removed from.
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
    /// - Parameters:
    ///   - contextID: Context whose threads are rebuilt. Only threads belonging to
    ///     this context are re-indexed, but stale-document pruning is evaluated
    ///     against every known thread ID, so documents for threads deleted in any
    ///     context are removed by this pass.
    ///   - database: Database the thread, message and attachment rows are read
    ///     from, and where each thread's semantic document digest is written back
    ///     once its document has been committed to the store.
    ///   - semanticStore: Store that is brought in line with the loaded rows via
    ///     `indexThread`, `updateThread` and `removeThread`. Its current contents
    ///     are read first, so a thread whose digest and indexed text already match
    ///     the freshly built document is skipped.
    /// - Throws: The first error raised while pruning or rebuilding a document.
    ///   Every document is still attempted, and the error is rethrown only after
    ///   the pass finishes.
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
    /// - Parameters:
    ///   - database: Database every thread is read from — along with the messages
    ///     and attachments that make up each document — and where each thread's
    ///     semantic document digest is written back after its document is
    ///     committed to the store.
    ///   - semanticStore: Store that is rebuilt. Its current document list is read
    ///     first to decide, per thread, between `indexThread`, `updateThread` and
    ///     `removeThread`.
    ///   - onProgress: invoked after each thread with `(completed, total)`.
    ///     Use it to surface progress and to drain the embedder's memory between
    ///     documents — bulk embedding is the heaviest part and benefits from a
    ///     periodic cache release.
    /// - Throws: Any error raised by the database queries or the semantic store.
    ///   Unlike `reconcileContextThreads(_:on:semanticStore:)` the pass stops at
    ///   the first failure, leaving the remaining threads untouched.
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
    /// - Parameters:
    ///   - thread: Thread to render. Its resolved message range selects the
    ///     messages, its `chitterChatter` IDs are dropped, rows whose type is not
    ///     `.message` are dropped, and its trimmed `summary` — when non-empty —
    ///     becomes the `Topic:` prefix.
    ///   - database: Database the context's messages and attachments are loaded
    ///     from. Attachment blobs are never read, only metadata.
    /// - Returns: The document text, or an empty string when the thread's message
    ///   range cannot be resolved or the range yields no summary, message or
    ///   attachment content.
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
