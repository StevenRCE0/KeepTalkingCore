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
        semanticStore: any KeepTalkingSemanticStore,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws {
        SemanticIndexTrace.info("context reconcile started context=\(contextID)")
        let contextThreads = try await KeepTalkingThread.query(on: database)
            .filter(\.$context.$id == contextID)
            .all()
        let knownIDs = Set(
            try await KeepTalkingThread.query(on: database).all().compactMap(\.id)
        )
        try await reconcile(
            contextThreads,
            knownIDs: knownIDs,
            on: database,
            semanticStore: semanticStore,
            label: "context reconcile",
            onProgress: onProgress
        )
        SemanticIndexTrace.info("context reconcile completed context=\(contextID)")
    }

    /// Reconciles the whole index in a single pass: one thread query, one read of
    /// the index, then a digest-guarded rebuild of every thread across every
    /// context.
    ///
    /// This exists because reconciling context-by-context is quadratic in the
    /// wrong place. ``reconcileContextThreads(_:on:semanticStore:onProgress:)``
    /// reads *every* document out of the store to build its comparison map, and
    /// re-queries *every* thread for stale-pruning — so running it once per
    /// context repeats both N times. The store's read materialises each
    /// document's embedding as well as its text, so that repetition is measured
    /// in megabytes of churn per launch, and it is paid even when the digest
    /// check goes on to skip every thread.
    ///
    /// Unlike ``reindexAllThreads(on:semanticStore:onProgress:)`` this respects
    /// the per-thread digest, so an already-current index costs no embedding at
    /// all — which is what makes it safe to run on every launch.
    public static func reconcileAllThreads(
        on database: any Database,
        semanticStore: any KeepTalkingSemanticStore,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws {
        SemanticIndexTrace.info("index reconcile started")
        let allThreads = try await KeepTalkingThread.query(on: database).all()
        let knownIDs = Set(allThreads.compactMap(\.id))
        try await reconcile(
            allThreads,
            knownIDs: knownIDs,
            on: database,
            semanticStore: semanticStore,
            label: "index reconcile",
            onProgress: onProgress
        )
        SemanticIndexTrace.info("index reconcile completed threads=\(allThreads.count)")
    }

    /// Shared body of the two reconcile entry points.
    ///
    /// - Parameters:
    ///   - threads: The threads to bring in line with the store.
    ///   - knownIDs: Every thread ID that exists anywhere. Documents outside this
    ///     set are pruned, so a caller reconciling a subset must still pass the
    ///     full set or this will delete live documents.
    private static func reconcile(
        _ threads: [KeepTalkingThread],
        knownIDs: Set<UUID>,
        on database: any Database,
        semanticStore: any KeepTalkingSemanticStore,
        label: String,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)?
    ) async throws {
        let indexed = try await semanticStore.allDocuments()
        let indexedTextByID = Dictionary(
            indexed.map { ($0.id, $0.text) },
            uniquingKeysWith: { _, latest in latest }
        )
        var firstFailure: (any Error)?
        var completed = 0
        let total = threads.count

        for staleID in Set(indexedTextByID.keys).subtracting(knownIDs) {
            do {
                SemanticIndexTrace.info("\(label) remove stale id=\(staleID)")
                try await semanticStore.removeThread(id: staleID)
            } catch {
                firstFailure = firstFailure ?? error
                SemanticIndexTrace.error(
                    "\(label) remove failed id=\(staleID) error=\(error)"
                )
            }
        }

        for thread in threads {
            guard let threadID = thread.id else { continue }
            do {
                let text = try await threadDocumentText(for: thread, on: database)
                let digest = semanticDocumentDigest(for: text)
                let indexedText = indexedTextByID[threadID]
                // Phrased as a positive guard rather than an early `continue` so
                // that every thread — skipped or rebuilt — reaches the progress
                // callback below. A `continue` here would hide skipped threads
                // from a caller draining embedder memory on a cadence.
                if thread.semanticDocumentDigest != digest || indexedText != text {
                    if !isIndexable(text) {
                        if indexedText != nil {
                            SemanticIndexTrace.info(
                                "\(label) remove unindexable id=\(threadID) characters=\(text.count)"
                            )
                            try await semanticStore.removeThread(id: threadID)
                        }
                    } else if indexedText == text {
                        SemanticIndexTrace.info("\(label) repair marker id=\(threadID)")
                    } else if indexedText != nil {
                        SemanticIndexTrace.info(
                            "\(label) update id=\(threadID) characters=\(text.count)"
                        )
                        try await semanticStore.updateThread(id: threadID, text: text)
                    } else {
                        SemanticIndexTrace.info(
                            "\(label) index id=\(threadID) characters=\(text.count)"
                        )
                        try await semanticStore.indexThread(id: threadID, text: text)
                    }
                    try await recordSemanticDocumentDigest(
                        digest,
                        for: threadID,
                        on: database
                    )
                }
            } catch {
                firstFailure = firstFailure ?? error
                SemanticIndexTrace.error(
                    "\(label) document failed id=\(threadID) error=\(error)"
                )
            }
            completed += 1
            await onProgress?(completed, total)
        }

        if let firstFailure {
            SemanticIndexTrace.error("\(label) incomplete error=\(firstFailure)")
            throw firstFailure
        }
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
                if isIndexable(text) {
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
                        "manual reindex skipped unindexable id=\(threadID) characters=\(text.count) progress=\(completed)/\(total)"
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
    /// Upper bound on the transcript portion of a thread document, in *estimated
    /// tokens* rather than characters.
    ///
    /// Sized to the embedding model rather than to taste. The sentence-transformer
    /// family KT embeds with tops out at 512 positions, and nothing in the path
    /// truncates for us: `MLXEmbedder` tokenizes the full string and pads each
    /// batch to its longest member, so one oversized thread sets the tensor width
    /// — and therefore the attention cost — for everything batched alongside it.
    /// Past the model's limit the extra text is not merely wasted, it is text the
    /// model has no positions to represent.
    ///
    /// Counted in tokens because a character budget cannot be correct across
    /// scripts: Latin text runs about four characters per token, CJK about one.
    /// A budget tuned for English silently admits several times the model's limit
    /// once a thread is written in Chinese — which is not hypothetical here, the
    /// longest document in the local corpus is ~39% CJK.
    ///
    /// The remainder of the 512 is headroom for special tokens, the topic prefix
    /// and the attachment lines appended below.
    public static let documentTokenBudget = 400

    /// Shortest document worth indexing, in estimated tokens.
    ///
    /// Below this a document is mostly ceremony — a bare topic line, a one-word
    /// reply — and its embedding lands in a dense, meaningless region of the
    /// space where it dilutes every search it survives. Skipping these also keeps
    /// them out of the store entirely, which is the cheapest memory saving
    /// available.
    ///
    /// In tokens for the same reason as the budget: 32 Latin characters and 8
    /// Chinese characters carry comparable content, and a character threshold
    /// would treat one as substantial and the other as noise.
    public static let minimumDocumentTokens = 8

    /// Rough token cost of a character, without running a tokenizer.
    ///
    /// The tokenizer lives behind the app's embedder, several layers above this
    /// code, and loading one here to measure text we may be about to discard
    /// would cost more than the guess saves. Subword vocabularies land near four
    /// Latin characters per token, while CJK is close to one character per token
    /// — the two cases that actually differ by enough to matter.
    ///
    /// Deliberately biased to over-estimate: over-estimating truncates a little
    /// early, under-estimating hands the model more positions than it has.
    private static func estimatedTokenCost(of character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 0.25 }
        switch scalar.value {
            // CJK Unified Ideographs (and Extension A), Hiragana, Katakana,
            // Hangul syllables — scripts whose characters are roughly one token.
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
                return 1.0
            default:
                return 0.25
        }
    }

    /// Estimated token length of a string, by the same measure as the budgets.
    private static func estimatedTokenCount(of text: some StringProtocol) -> Double {
        text.reduce(0) { $0 + estimatedTokenCost(of: $1) }
    }

    /// The longest prefix of `text` fitting within `budget` estimated tokens,
    /// along with what it cost.
    ///
    /// Walks characters rather than slicing at an index, because the budget is
    /// script-dependent: there is no character offset that corresponds to a token
    /// count without inspecting what those characters are.
    private static func truncated(
        _ text: some StringProtocol,
        toTokens budget: Double
    ) -> (text: String, tokens: Double) {
        var spent: Double = 0
        var kept = String()
        for character in text {
            let cost = estimatedTokenCost(of: character)
            if spent + cost > budget { break }
            spent += cost
            kept.append(character)
        }
        return (kept, spent)
    }

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

        // Accumulated with a budget rather than joined-then-truncated: a long
        // thread's transcript can run to hundreds of kilobytes, and building the
        // whole string first would pay the peak this cap exists to avoid.
        //
        // The newest messages are the ones worth keeping when a thread overflows
        // — a stale opening exchange describes the thread far less well than what
        // it has become — so this fills from the end and restores order after.
        var budget = Double(documentTokenBudget)
        var selected: [String] = []
        for message in rangeMessages.reversed() {
            guard budget > 0 else { break }
            if let messageID = message.id, chitterSet.contains(messageID) { continue }
            guard message.type == .message else { continue }
            let content = message.content
            let cost = estimatedTokenCount(of: content)
            if cost <= budget {
                selected.append(content)
                // The newline this will be joined with costs a token too.
                budget -= cost + 0.25
            } else {
                // A single message can exceed the whole budget. Keep its tail for
                // the same reason: recency. Reversed twice so the *end* of the
                // message survives while its characters stay in order.
                let (tail, spent) = truncated(
                    String(content.reversed()),
                    toTokens: budget
                )
                selected.append(String(tail.reversed()))
                budget -= spent
            }
        }
        let messageText = selected.reversed().joined(separator: "\n")

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

    /// Whether a built document is worth an embedding.
    ///
    /// Measures non-whitespace only, so a document padded out by newlines between
    /// empty messages does not clear the bar on formatting alone.
    private static func isIndexable(_ text: String) -> Bool {
        estimatedTokenCount(of: text.filter { !$0.isWhitespace })
            >= Double(minimumDocumentTokens)
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
