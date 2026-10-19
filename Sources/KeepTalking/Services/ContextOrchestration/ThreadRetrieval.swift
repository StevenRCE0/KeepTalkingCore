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

/// What `kt_search_threads` hands back for the threads it found. Sizes come
/// from the run's strategy and the main model's window; every thread then
/// gets exactly one delivery, decided in rank order:
///
/// | delivery     | when                                                        |
/// |--------------|-------------------------------------------------------------|
/// | `verbatim`   | read whole here, and it still fits `verbatimTokens`         |
/// | `answered`   | too long: consultants read it and answer the query          |
/// | `newestRows` | too long and no consultant: its newest rows, within budget  |
/// | `listed`     | past what one search's consultants read (`consultTokens`)   |
/// | `excerpt`    | a peer's, in a context this node doesn't hold               |
struct ThreadSearchHandOver: Sendable {
    enum Delivery: String, Sendable {
        case verbatim
        case answered
        case newestRows = "newest rows"
        case listed
        case excerpt
    }

    /// The run's main model, lent to the consultants.
    struct Consultant: Sendable {
        let connector: any AIConnector
        let model: String
        /// The user's message this turn, read beside the query.
        let userPrompt: String?
        let agentTurnID: UUID?
        let promptCacheKey: String?
    }

    /// What goes back word for word, in all.
    let verbatimTokens: Int
    /// One consult's chunk.
    let chunkTokens: Int
    /// What one search's consultants read, in all.
    let consultTokens: Int
    /// Nil: long threads are cut to their newest rows instead.
    let consultant: Consultant?
    let consultEffort: AIReasoning.Effort?
    let consultMaxOutputTokens: Int

    /// How far back a thread is read: as much as this search could hand over.
    var readCeilingTokens: Int { consultant == nil ? verbatimTokens : max(verbatimTokens, consultTokens) }
    /// Rows the consultants cite, beside their answers.
    var evidenceTokens: Int { max(1_000, verbatimTokens / 4) }
}

extension ThreadSearchHandOver {
    init(strategy: KeepTalkingOrchestrationStrategy, profile: AIModelProfile?, consultant: Consultant?) {
        self.init(
            verbatimTokens: strategy.verbatimTokens(for: profile),
            chunkTokens: strategy.chunkTokens(for: profile),
            consultTokens: strategy.searchConsultTokens(for: profile),
            consultant: strategy.consultsLongSearchResults ? consultant : nil,
            consultEffort: strategy.consultEffort(for: profile),
            consultMaxOutputTokens: strategy.consultMaxOutputTokens
        )
    }

    /// For a search outside a main run, with no model to consult on.
    static let unconsulted = ThreadSearchHandOver(strategy: .legacy, profile: nil, consultant: nil)

    // MARK: 1. Deliveries

    /// One delivery per thread read here, `ranked` best first. Threads read
    /// whole fill the verbatim allowance in rank order; the rest are too long
    /// and go to the consultants up to `consultTokens`, or are cut without one.
    func deliveries(_ ranked: [RetrievedThread]) -> [(thread: RetrievedThread, delivery: Delivery)] {
        var verbatimLeft = verbatimTokens
        var consultLeft = consultTokens
        var consulting = false
        return ranked.map { thread in
            if thread.complete, thread.tokens <= verbatimLeft {
                verbatimLeft -= thread.tokens
                return (thread, .verbatim)
            }
            guard consultant != nil else { return (thread, .newestRows) }
            if thread.tokens <= consultLeft || !consulting {
                consultLeft -= thread.tokens
                consulting = true
                return (thread, .answered)
            }
            return (thread, .listed)
        }
    }

    // MARK: 2. Consulting what is too long

    struct Consultation: Sendable {
        let resolution: ThreadConsultResolution
        let chunkCount: Int
        let failures: [String]
    }

    /// One consult per chunk of `threads`, all in parallel, asked the query.
    func consult(
        _ threads: [RetrievedThread], query: String, on client: KeepTalkingClient
    ) async -> Consultation? {
        guard let consultant, !threads.isEmpty else { return nil }
        // Chronological labels, so a chunk's text depends only on its threads.
        let labelled = threads.sorted(by: RetrievedThread.chronological).enumerated()
            .map { (label: "t\($0.offset + 1)", thread: $0.element.thread) }
        let chunks = KeepTalkingClient.consultChunks(labelled, targetTokens: chunkTokens)
        var configuration = AITurnConfiguration(
            reasoning: consultEffort.map { AIReasoning(effort: $0) },
            maxOutputTokens: consultMaxOutputTokens,
            promptCacheKey: consultant.promptCacheKey
        )
        configuration.telemetry = AITurnTelemetry(role: .consult, agentTurnID: consultant.agentTurnID)
        let outcomes = await client.runThreadConsults(
            chunks,
            brief: .search(query: query, userPrompt: consultant.userPrompt),
            model: consultant.model,
            connector: consultant.connector,
            configuration: configuration
        )
        return Consultation(
            resolution: .resolve(outcomes, presentedLastTurn: []),
            chunkCount: chunks.count,
            failures: outcomes.compactMap { outcome in outcome.failure.map { "chunk \(outcome.chunk.index): \($0)" } }
        )
    }

    // MARK: 3. The tool result

    /// Every hit with its delivery, then what each delivery carries:
    /// `threads` (verbatim), `answers` + `evidence` (consulted),
    /// `newest_rows` (cut), and a `note` saying what happened.
    func toolResult(
        query: String,
        hits: [ThreadSearchHit],
        read: [String: RetrievedThread],
        deliveries: [(thread: RetrievedThread, delivery: Delivery)],
        consultation: Consultation?
    ) -> (payload: [String: Any], log: String) {
        let grouped = Dictionary(grouping: deliveries, by: \.delivery).mapValues { $0.map(\.thread) }
        let verbatim = grouped[.verbatim] ?? []
        let answered = grouped[.answered] ?? []
        let cut = grouped[.newestRows] ?? []
        let listed = grouped[.listed] ?? []
        let deliveryByThread = Dictionary(
            deliveries.map { ($0.thread.thread.threadID, $0.delivery) }, uniquingKeysWith: { first, _ in first }
        )
        func names(_ threads: [RetrievedThread]) -> String {
            threads.map { "\"\($0.thread.name)\"" }.joined(separator: ", ")
        }
        func were(_ threads: [RetrievedThread]) -> String { threads.count == 1 ? "was" : "were" }

        var payload: [String: Any] = ["ok": true, "query": query, "count": hits.count]
        var notes: [String] = []
        var log = "verbatim=\(verbatim.count) (≈\(verbatim.reduce(0) { $0 + $1.tokens })/\(verbatimTokens) tok)"

        if !verbatim.isEmpty {
            payload["threads"] = KeepTalkingClient.verbatimTranscript(verbatim)
        }
        if !answered.isEmpty, let consultation {
            let findings = consultation.resolution.findings
            payload["answers"] = findings.map { finding -> [String: Any] in
                var answer: [String: Any] = ["thread": finding.thread.name, "facts": finding.facts]
                if !finding.constraints.isEmpty { answer["must_honour"] = finding.constraints }
                return answer
            }
            let cited = PresentedTranscripts.window(
                findings.flatMap { finding in
                    finding.citedRows.map {
                        PresentedTranscripts.Entry(
                            threadID: finding.thread.threadID, threadName: finding.thread.name,
                            label: $0.label, row: $0.row
                        )
                    }
                },
                budget: evidenceTokens,
                cap: evidenceTokens
            )
            if !cited.text.isEmpty { payload["evidence"] = cited.text }
            let tokens = answered.reduce(0) { $0 + $1.tokens }
            notes.append(
                "\(names(answered)) \(were(answered)) too long to return whole (about \(tokens) tokens; this model takes \(verbatimTokens) here), so consultants read \(answered.count == 1 ? "it" : "them") in full (\(consultation.chunkCount) chunk(s)) and "
                    + (findings.isEmpty
                        ? "found nothing that answers the query."
                        : "answered the query: see answers, with the rows they cite in evidence.")
            )
            if !consultation.failures.isEmpty {
                notes.append(
                    "Some consults failed (\(consultation.failures.joined(separator: "; "))); their part was not read.")
            }
            log +=
                " answered=\(answered.count) (≈\(tokens) tok, \(consultation.chunkCount) chunk(s)) → \(findings.count) answer(s)/\(cited.tokens) tok cited"
                + (consultation.failures.isEmpty ? "" : " failures=[\(consultation.failures.joined(separator: "; "))]")
        }
        if !cut.isEmpty {
            let used = verbatim.reduce(0) { $0 + $1.tokens }
            let budget = max(verbatimTokens - used, verbatimTokens / 4)
            let newest = PresentedTranscripts.window(cut.map(\.thread), budget: budget, cap: budget)
            payload["newest_rows"] = newest.text
            notes.append("\(names(cut)) \(were(cut)) too long to return whole; the newest rows are in newest_rows.")
            if let note = newest.truncationNote { notes.append(note) }
            log += " cut=\(cut.count) (→ \(newest.tokens) tok)"
        }
        if !listed.isEmpty {
            notes.append("Not read (past what one search consults): \(names(listed)).")
            log += " listed=\(listed.count)"
        }

        payload["results"] = hits.map { hit -> [String: Any] in
            var result: [String: Any] = [
                "thread_id": hit.threadID,
                "label": read[hit.threadID]?.thread.name ?? hit.label,
                "score": hit.score,
                "node_id": hit.nodeID,
                "node_label": hit.nodeLabel,
            ]
            if let thread = read[hit.threadID], let delivery = deliveryByThread[thread.thread.threadID] {
                result["delivery"] = delivery.rawValue
            } else {
                result["delivery"] = Delivery.excerpt.rawValue
                result["excerpt"] = hit.excerpt
            }
            return result
        }
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
