import FluentKit
import Foundation

// MARK: - What a search found

/// One hit of `kt_search_threads`, here or on a peer that shares its thread
/// memory.
struct ThreadSearchHit: Sendable {
    let threadID: String
    let label: String
    let score: Double
    /// The ranker's excerpt: all a caller gets of a peer's thread in a
    /// context it doesn't hold.
    let excerpt: String
    let nodeID: String
    let nodeLabel: String
}

/// One thread read here: every row of a context this node holds opens here.
struct RetrievedThread: Sendable {
    let thread: OrchestratedThread
    let score: Double
    /// False when its oldest rows were past the read ceiling and left unread.
    let complete: Bool

    /// What its substantive rows cost verbatim.
    var tokens: Int {
        thread.substantiveRows.reduce(24) { $0 + AIMessage.approximateTokens($1.line) + 1 }
    }

    static func chronological(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.thread.rows.first?.timestamp ?? .distantPast) < (rhs.thread.rows.first?.timestamp ?? .distantPast)
    }
}

// MARK: - The hand-over

struct ThreadSearchHandOver: Sendable {
    enum Delivery: String, Sendable {
        case answered
        case listed
        case excerpt
    }

    let consultant: ThreadConsultant
    let userPrompt: String?
    let consultTokens: Int
}

extension ThreadSearchHandOver {
    init(
        strategy: KeepTalkingOrchestrationStrategy, profile: AIModelProfile?, consultant: ThreadConsultant,
        userPrompt: String?
    ) {
        self.init(
            consultant: consultant, userPrompt: userPrompt, consultTokens: strategy.searchConsultTokens(for: profile))
    }

    func split(_ ranked: [RetrievedThread]) -> (consulted: [RetrievedThread], listed: [RetrievedThread]) {
        var left = consultTokens
        var consulted: [RetrievedThread] = []
        var listed: [RetrievedThread] = []
        for thread in ranked {
            guard consulted.isEmpty || thread.tokens <= left else {
                listed.append(thread)
                continue
            }
            left -= thread.tokens
            consulted.append(thread)
        }
        return (consulted, listed)
    }

    func consult(
        _ threads: [RetrievedThread], query: String, on client: KeepTalkingClient
    ) async -> ThreadConsultResolution? {
        guard !threads.isEmpty else { return nil }
        // Chronological labels, so a chunk's text depends only on its threads.
        let labelled = threads.sorted(by: RetrievedThread.chronological).enumerated()
            .map { (label: "t\($0.offset + 1)", thread: $0.element.thread) }
        return await client.consult(
            KeepTalkingClient.consultChunks(labelled, targetTokens: consultant.chunkTokens),
            brief: .search(query: query, userPrompt: userPrompt),
            with: consultant
        )
    }

    func toolResult(
        query: String,
        hits: [ThreadSearchHit],
        read: [String: RetrievedThread],
        consulted: [RetrievedThread],
        listed: [RetrievedThread],
        resolution: ThreadConsultResolution?
    ) -> (payload: [String: Any], log: String) {
        let findings = resolution?.findings ?? []
        let answeredIDs = Set(findings.map(\.thread.threadID))
        let unread = consulted.filter {
            resolution?.unread.contains($0.thread.threadID) == true && !answeredIDs.contains($0.thread.threadID)
        }
        let listedIDs = Set((listed + unread).map(\.thread.threadID))
        let irrelevant = consulted.filter {
            !answeredIDs.contains($0.thread.threadID) && !listedIDs.contains($0.thread.threadID)
        }
        func names(_ threads: [RetrievedThread]) -> String {
            threads.map { "\"\($0.thread.name)\"" }.joined(separator: ", ")
        }

        var payload: [String: Any] = ["ok": true, "query": query]
        var notes: [String] = []
        let consultedTokens = consulted.reduce(0) { $0 + $1.tokens }
        var log = "consulted=\(consulted.count) (≈\(consultedTokens)/\(consultTokens) tok)"

        if let resolution {
            payload["answers"] = findings.map { finding -> [String: Any] in
                var answer: [String: Any] = ["thread": finding.thread.name, "facts": finding.facts]
                if !finding.constraints.isEmpty { answer["must_honour"] = finding.constraints }
                return answer
            }
            let cited = PresentedTranscripts.window(
                resolution.citedEntries, budget: consultant.citationTokens, cap: consultant.citationTokens)
            if !cited.text.isEmpty { payload["evidence"] = cited.text }
            let summary =
                "Consultants read \(consulted.count) matching thread(s) in full (\(resolution.consultedChunks) chunk(s))"
            if findings.isEmpty {
                notes.append(summary + " and found nothing that answers the query.")
            } else {
                notes.append(summary + ": see answers, with the rows they cite in evidence.")
                if !irrelevant.isEmpty {
                    notes.append("\(irrelevant.count) other match(es) held nothing for it and are left out.")
                }
            }
            if !resolution.failures.isEmpty {
                notes.append(
                    "Some consults failed (\(resolution.failures.joined(separator: "; ")))"
                        + (unread.isEmpty ? "." : "; not read: \(names(unread))."))
            }
            log +=
                " chunks=\(resolution.consultedChunks) → \(findings.count) answered/\(irrelevant.count) left out, \(cited.tokens) tok cited"
                + (resolution.failures.isEmpty ? "" : " failures=[\(resolution.failures.joined(separator: "; "))]")
        }
        if !listed.isEmpty {
            notes.append("Not read (past what one search consults): \(names(listed)).")
            log += " listed=\(listed.count)"
        }

        let leftOut = Set(irrelevant.map(\.thread.threadID))
        payload["results"] = hits.compactMap { hit -> [String: Any]? in
            let thread = read[hit.threadID]
            if let thread, leftOut.contains(thread.thread.threadID) { return nil }
            var result: [String: Any] = [
                "thread_id": hit.threadID,
                "label": thread?.thread.name ?? hit.label,
                "score": hit.score,
                "node_id": hit.nodeID,
                "node_label": hit.nodeLabel,
            ]
            if let thread {
                result["delivery"] =
                    (answeredIDs.contains(thread.thread.threadID) ? Delivery.answered : .listed).rawValue
            } else {
                result["delivery"] = Delivery.excerpt.rawValue
                result["excerpt"] = hit.excerpt
            }
            return result
        }
        payload["count"] = (payload["results"] as? [Any])?.count ?? 0
        if !notes.isEmpty { payload["note"] = notes.joined(separator: " ") }
        log += " excerpts=\(hits.count - read.count)"
        return (payload, log)
    }
}

// MARK: - Reading, and remembering what was revealed

extension KeepTalkingClient {
    /// A thread's `.message` rows, read by key from its newest edge until
    /// `ceilingTokens` — never the whole context. Nil when the thread is not
    /// stored here (a peer's, in a context this node doesn't hold).
    func retrievedThread(
        _ threadID: UUID,
        score: Double,
        aliasLookup: KeepTalkingAliasLookup,
        ceilingTokens: Int
    ) async throws -> RetrievedThread? {
        let database = localStore.database
        guard let thread = try await KeepTalkingThread.find(threadID, on: database),
            let range = try await Self.threadRange(threadID, on: database)
        else { return nil }
        let contextID = thread.$context.id
        var newestFirst: [KeepTalkingContextMessage] = []
        var spent = 0
        var complete = true
        var cursor = range
        pages: while true {
            let page = try await Self.messagePage(
                in: contextID, range: cursor, direction: .backward,
                limit: Self.documentPageSize, attachments: .none, on: database
            )
            for message in page.messages.reversed() {
                guard spent < ceilingTokens else {
                    complete = false
                    break pages
                }
                newestFirst.append(message)
                if message.type == .message { spent += AIMessage.approximateTokens(message.content) + 8 }
            }
            guard page.hasMore, let first = page.firstKey else { break }
            cursor = cursor.before(first)
        }
        let messages = Array(newestFirst.reversed())
        let chitter = Set(thread.chitterChatter)
        let rows = messages.compactMap { message -> OrchestratedRow? in
            guard let id = message.id, message.type == .message else { return nil }
            return OrchestratedRow(
                id: id,
                timestamp: message.timestamp,
                sender: message.sender,
                content: message.content,
                agentTurnID: message.agentTurnID,
                isChitterChatter: chitter.contains(id)
            )
        }
        guard !rows.isEmpty else { return nil }
        return RetrievedThread(
            thread: OrchestratedThread(
                threadID: threadID,
                state: thread.state,
                startMessageID: thread.$startMessage.id ?? rows.first?.id,
                name: threadTopicName(for: thread, messages: messages, aliasLookup: aliasLookup),
                rows: rows
            ),
            score: score,
            complete: complete
        )
    }

    /// Threads as a transcript: oldest first, each under its name, rows
    /// `[speaker] text`.
    static func verbatimTranscript(_ threads: [RetrievedThread]) -> String {
        threads.sorted(by: RetrievedThread.chronological)
            .map { retrieved in
                var header =
                    "— thread \"\(retrieved.thread.name)\" · \(retrieved.thread.rows.count) messages · \(dateRange(of: retrieved.thread))"
                if !retrieved.complete { header += " · newest rows only, older ones not read" }
                return ([header] + retrieved.thread.substantiveRows.map(\.line)).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    /// A search's Output row: the threads it revealed, sealed to this node,
    /// right after the search's own row — so the next turn's first pass
    /// carries them again. The parameter holds comma-separated thread ids.
    public static let revealedThreadsParameter = "revealed_threads"

    func publishRevealedThreads(
        _ threadIDs: [UUID], query: String, publisher: AIOrchestrator.ToolHintPublisher?
    ) async {
        guard let publisher, !threadIDs.isEmpty else { return }
        let name = String(query.prefix(80))
        do {
            try await publisher(
                name,
                .intermediate(
                    hint: "Output", targetNodeID: nil, actionID: nil, actionName: name, sealedParameters: nil),
                [
                    "query": query,
                    Self.revealedThreadsParameter: threadIDs.map { $0.uuidString.lowercased() }.joined(separator: ","),
                ]
            )
        } catch {
            onLog?("[search-threads] recording revealed threads failed error=\(error.localizedDescription)")
        }
    }

    /// Threads searches revealed in `messages`, newest first, at most `limit`;
    /// rows of `excludingAgentTurnID` (a resumed turn's own) left out. Opens
    /// at most `scanLimit` Output rows.
    func revealedThreadIDs(
        in messages: [KeepTalkingContextMessage],
        excludingAgentTurnID: UUID?,
        limit: Int,
        scanLimit: Int = 64
    ) async -> [UUID] {
        guard limit > 0 else { return [] }
        var found: [UUID] = []
        var opened = 0
        for message in messages.reversed() {
            guard opened < scanLimit, found.count < limit else { break }
            guard case .intermediate(let hint, _, _, _, let sealed?) = message.type, hint == "Output",
                excludingAgentTurnID == nil || message.agentTurnID != excludingAgentTurnID
            else { continue }
            opened += 1
            guard let parameters = await openSealedCallParameters(sealed),
                let ids = parameters[Self.revealedThreadsParameter]
            else { continue }
            for id in ids.split(separator: ",").compactMap({ UUID(uuidString: String($0)) })
            where !found.contains(id) && found.count < limit {
                found.append(id)
            }
        }
        return found
    }
}
