import Foundation

/// Consult fan-out over verbatim history (§7, reworked): every stored thread
/// is packed, whole and oldest first, into chunks sized to the model's sweet
/// spot. Each chunk becomes one consult that is asked the user's own message
/// against those rows — retrieval, not summarisation — and answers with the
/// facts and the labels of the rows it found them in. The collector gets the
/// facts and the cited rows verbatim.
///
/// A chunk's rows never change once their threads are stored, so the chunk is
/// a durable, separately cached prefix (system + chunk); only the live tail,
/// the user's message and the question are paid uncached per turn.
enum ThreadConsultVerdict: String, Sendable, Decodable {
    case present
    case answer
}

/// One labelled row of a chunk: `t<thread>.<row>`.
struct ConsultRowRef: Sendable, Hashable {
    let threadLabel: String
    let rowNumber: Int
    var label: String { "\(threadLabel).\(rowNumber)" }
}

/// Whole threads (or, for a thread bigger than a chunk, consecutive parts of
/// one) packed up to the chunk target.
struct ConsultChunk: Sendable {
    struct Part: Sendable {
        let threadLabel: String
        let thread: OrchestratedThread
        /// (row number in the thread, row), chitter-chatter left out.
        let rows: [(number: Int, row: OrchestratedRow)]
        let partNumber: Int?
    }

    let index: Int
    let parts: [Part]
    let text: String
    let tokens: Int

    var threadCount: Int { Set(parts.map(\.threadLabel)).count }

    func row(_ ref: ConsultRowRef) -> (thread: OrchestratedThread, row: OrchestratedRow)? {
        for part in parts where part.threadLabel == ref.threadLabel {
            if let match = part.rows.first(where: { $0.number == ref.rowNumber }) {
                return (part.thread, match.row)
            }
        }
        return nil
    }

    func thread(labelled label: String) -> OrchestratedThread? {
        parts.first { $0.threadLabel == label }?.thread
    }
}

/// A consult's reply (prompt-level JSON).
struct ThreadConsultReply: Sendable, Decodable {
    struct Item: Sendable, Decodable {
        let thread: String
        let verdict: ThreadConsultVerdict?
        let facts: [String]?
        let constraints: [String]?
        let refs: [String]?
    }

    let relevant: [Item]
}

struct ThreadConsultOutcome: Sendable {
    let chunk: ConsultChunk
    let reply: ThreadConsultReply?
    var failure: String?
}

/// How one consult is asked. Every consult runs the same way — one call per
/// history chunk, the chunk its own cached prefix, a JSON reply of facts and
/// the rows they come from — and the brief says what it is for.
struct ThreadConsultBrief: Sendable {
    let systemPrompt: String
    /// Recent live rows, so the consult can tell what the message refers to.
    let liveTail: [AIMessage]
    let question: AIMessage
    let charter: String
    /// Telemetry label in front of the chunk's.
    let label: String?

    /// System and chunk (the cached prefix), then the live tail, the question
    /// and the charter.
    func messages(for chunk: ConsultChunk) -> [AIMessage] {
        [.system(systemPrompt), AIMessage.system(chunk.text).withCacheBoundary(.durable)]
            + liveTail + [question, .system(charter)]
    }

    /// Before the reply (orchestrated layout): what does the reply to the
    /// user's message need? A thread the message resumes is an `answer`.
    static func turn(userMessage: AIMessage, liveTail: [AIMessage]) -> Self {
        Self(
            systemPrompt: turnSystemPrompt, liveTail: liveTail, question: userMessage, charter: turnCharter, label: nil)
    }

    /// For `kt_search_threads`, over the threads it retrieved: answer the
    /// query. The assistant never sees these rows, so every finding must be
    /// the answer itself, never a note that something is there.
    static func search(query: String, userPrompt: String?) -> Self {
        var question = "Search query: \(query)"
        if let prompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            question += "\nThe user's latest message, for what the query refers to: \(prompt)"
        }
        return Self(
            systemPrompt: searchSystemPrompt, liveTail: [], question: .user(question), charter: searchCharter,
            label: "search"
        )
    }

    // MARK: Prompts (stable: the system prompt is part of each cached prefix)

    static let turnSystemPrompt = """
        You search one chunk of a group conversation's stored history for what the reply to the user's latest message needs. You never reply to the user and never call tools.
        Rows are labelled <thread>.<row> (for example t4.7). Quote numbers, names, dates and amounts exactly as written. When a decision or value changed over time, report the latest one and say which earlier value it replaced.
        """

    static let turnCharter = """
        Consultation — not the reply to the user. Search the history chunk above for everything the reply to the user's latest message (just above) needs: facts, numbers, names, dates, decisions, open questions, owners. Use the recent conversation above it only to understand what the message refers to.
        Reply with ONLY a JSON object:
        {"relevant": [{"thread": "t4", "verdict": "present", "facts": ["…"], "constraints": ["…"], "refs": ["t4.7", "t4.10"]}]}
        - List only threads with rows the reply needs; {"relevant": []} when nothing in this chunk is.
        - facts: short, exact statements with the numbers and names as written; for a value that changed, the final one and what it replaced.
        - constraints: decisions the reply must honour.
        - refs: the labels of the rows the facts come from.
        - verdict: "answer" only if the user's message continues that thread's own topic; otherwise "present".
        """

    static let searchSystemPrompt = """
        You answer a search over one chunk of a group conversation's stored history. You never reply to the user and never call tools.
        Rows are labelled <thread>.<row> (for example t4.7). Quote numbers, names, dates and amounts exactly as written. When a decision or value changed over time, report the latest one and say which earlier value it replaced.
        """

    static let searchCharter = """
        Consultation — answer the search. The assistant will not see these threads, only what you write, so your reply must BE the answer.
        Reply with ONLY a JSON object:
        {"relevant": [{"thread": "t2", "verdict": "answer", "facts": ["…"], "refs": ["t2.14"]}]}
        - verdict is ALWAYS "answer". NEVER report that something is present, mentioned or discussed, and never point to where it is: write the answer itself.
        - facts: complete, self-contained statements that answer the query, with the exact numbers, names, dates and amounts as written; for a value that changed, the final one and what it replaced. Include everything the query asks for that this chunk holds.
        - refs: the labels of the rows the facts come from.
        - List only threads that hold part of the answer; {"relevant": []} when none do.
        """
}

struct ThreadConsultant: Sendable {
    let connector: any AIConnector
    let model: String
    let configuration: AITurnConfiguration
    let chunkTokens: Int
    let citationTokens: Int
}

extension ThreadConsultant {
    init(
        strategy: KeepTalkingOrchestrationStrategy,
        profile: AIModelProfile?,
        main: KeepTalkingAgentConfiguration.Role,
        contextID: UUID,
        agentTurnID: UUID
    ) {
        var configuration = AITurnConfiguration(
            reasoning: strategy.consultEffort(for: profile).map { AIReasoning(effort: $0) },
            maxOutputTokens: strategy.consultMaxOutputTokens,
            promptCacheKey: KeepTalkingClient.promptCacheKey(for: contextID)
        )
        configuration.telemetry = AITurnTelemetry(role: .consult, agentTurnID: agentTurnID)
        self.init(
            connector: main.connector,
            model: main.model,
            configuration: configuration,
            chunkTokens: strategy.chunkTokens(for: profile),
            citationTokens: strategy.presentedTokens(for: profile)
        )
    }
}

/// Every relevant thread the consults reported, merged across chunks.
struct ThreadConsultFinding: Sendable {
    let thread: OrchestratedThread
    let threadLabel: String
    var verdict: ThreadConsultVerdict
    var facts: [String]
    var constraints: [String]
    var citedRows: [(label: String, row: OrchestratedRow)]
    /// `present` here two turns running (§7.4), promoted to `answer`.
    var promoted = false
}

struct ThreadConsultResolution: Sendable {
    var findings: [ThreadConsultFinding]
    var consultedChunks: Int
    var consultedThreads: Int
    /// The one thread the message resumes, if exactly one claims it.
    var answering: ThreadConsultFinding?
    /// Several claimed it; the collector decides.
    var contestedClaims: [ThreadConsultFinding] = []
    var failures: [String] = []
    var unread: Set<UUID> = []

    var citedEntries: [PresentedTranscripts.Entry] {
        findings.flatMap { finding in
            finding.citedRows.map {
                PresentedTranscripts.Entry(
                    threadID: finding.thread.threadID, threadName: finding.thread.name, label: $0.label, row: $0.row
                )
            }
        }
    }

    static func resolve(
        _ outcomes: [ThreadConsultOutcome],
        presentedLastTurn: Set<UUID>
    ) -> ThreadConsultResolution {
        var findings: [ThreadConsultFinding] = []
        for outcome in outcomes {
            for item in outcome.reply?.relevant ?? [] {
                guard let thread = outcome.chunk.thread(labelled: item.thread) else { continue }
                let cited: [(label: String, row: OrchestratedRow)] = (item.refs ?? []).compactMap { raw in
                    guard let ref = Self.parseRef(raw), let found = outcome.chunk.row(ref) else { return nil }
                    return (ref.label, found.row)
                }
                if let existing = findings.firstIndex(where: { $0.thread.threadID == thread.threadID }) {
                    // A thread split across chunks: merge its parts.
                    for fact in item.facts ?? [] where !findings[existing].facts.contains(fact) {
                        findings[existing].facts.append(fact)
                    }
                    for constraint in item.constraints ?? [] where !findings[existing].constraints.contains(constraint)
                    {
                        findings[existing].constraints.append(constraint)
                    }
                    findings[existing].citedRows += cited
                    if item.verdict == .answer { findings[existing].verdict = .answer }
                    continue
                }
                findings.append(
                    ThreadConsultFinding(
                        thread: thread,
                        threadLabel: item.thread,
                        verdict: item.verdict ?? .present,
                        facts: item.facts ?? [],
                        constraints: item.constraints ?? [],
                        citedRows: cited
                    )
                )
            }
        }
        for index in findings.indices where findings[index].verdict == .present {
            if let start = findings[index].thread.startMessageID, presentedLastTurn.contains(start) {
                findings[index].verdict = .answer
                findings[index].promoted = true
            }
        }
        let claims = findings.filter { $0.verdict == .answer }
        return ThreadConsultResolution(
            findings: findings,
            consultedChunks: outcomes.count,
            consultedThreads: Set(outcomes.flatMap { $0.chunk.parts.map(\.threadLabel) }).count,
            answering: claims.count == 1 ? claims.first : nil,
            contestedClaims: claims.count > 1 ? claims : [],
            failures: outcomes.compactMap { outcome in outcome.failure.map { "chunk \(outcome.chunk.index): \($0)" } },
            unread: Set(outcomes.filter { $0.failure != nil }.flatMap { $0.chunk.parts.map(\.thread.threadID) })
        )
    }

    /// `t4.7`, tolerating brackets and spaces.
    static func parseRef(_ raw: String) -> ConsultRowRef? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []()"))
        let pieces = cleaned.split(separator: ".")
        guard pieces.count == 2, pieces[0].hasPrefix("t"), let number = Int(pieces[1]) else { return nil }
        return ConsultRowRef(threadLabel: String(pieces[0]), rowNumber: number)
    }
}

/// The collector's view of stored-thread rows (§7.5): one recency window
/// across everything presented, never failing a turn.
struct PresentedTranscripts: Sendable, Equatable {
    struct Entry: Sendable {
        let threadID: UUID
        let threadName: String
        let label: String?
        let row: OrchestratedRow
    }

    let text: String
    /// Threads that lost rows off the front, and the earliest row kept.
    let truncationNote: String?
    let tokens: Int

    /// - `budget`: tokens left once the cached prefix, `user_n` and the output
    ///   reserve are taken from the model's input limit (dynamic budget).
    /// - `cap`: the absolute ceiling (`presentedTranscriptTokenCap`).
    static func window(_ entries: [Entry], budget: Int, cap: Int) -> PresentedTranscripts {
        let limit = max(0, min(budget, cap))
        var seen = Set<UUID>()
        let rows =
            entries
            .filter { !$0.row.isChitterChatter && seen.insert($0.row.id).inserted }
            .sorted { ($0.row.timestamp, $0.row.id.uuidString) < ($1.row.timestamp, $1.row.id.uuidString) }
        var kept: [Entry] = []
        var used = 0
        for entry in rows.reversed() {
            let line = (entry.label.map { "\($0) " } ?? "") + entry.row.line
            let cost = AIMessage.approximateTokens(line) + 6
            guard used + cost <= limit else { break }
            used += cost
            kept.insert(entry, at: 0)
        }
        let keptIDs = Set(kept.map(\.row.id))
        var cutNames: [String] = []
        for entry in rows where !keptIDs.contains(entry.row.id) && !cutNames.contains(entry.threadName) {
            cutNames.append(entry.threadName)
        }
        let earliest =
            kept.first.map { KeepTalkingClient.memoryDateFormatterWithTime.string(from: $0.row.timestamp) } ?? "none"
        let note: String? =
            cutNames.isEmpty
            ? nil
            : "Rows truncated to fit: older rows of \(cutNames.map { "\"\($0)\"" }.joined(separator: ", ")) were left out (earliest row kept: \(earliest))."
        var lines: [String] = []
        var currentThread: UUID?
        for entry in kept {
            if entry.threadID != currentThread {
                lines.append("— thread \"\(entry.threadName)\":")
                currentThread = entry.threadID
            }
            lines.append((entry.label.map { "\($0) " } ?? "") + entry.row.line)
        }
        return PresentedTranscripts(text: lines.joined(separator: "\n"), truncationNote: note, tokens: used)
    }

    /// Every substantive row of `threads`, unlabelled.
    static func window(_ threads: [OrchestratedThread], budget: Int, cap: Int) -> PresentedTranscripts {
        window(
            threads.flatMap { thread in
                thread.rows.map { Entry(threadID: thread.threadID, threadName: thread.name, label: nil, row: $0) }
            },
            budget: budget,
            cap: cap
        )
    }

    static func == (lhs: PresentedTranscripts, rhs: PresentedTranscripts) -> Bool {
        lhs.text == rhs.text && lhs.truncationNote == rhs.truncationNote && lhs.tokens == rhs.tokens
    }
}

extension KeepTalkingClient {
    static let memoryDateFormatterWithTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy HH:mm:ss 'UTC'"
        return formatter
    }()

    /// Packs every stored thread of `threads`, whole and oldest first, into
    /// chunks of at most `targetTokens`; a thread bigger than that is split
    /// into consecutive parts. Thread labels follow context order (`t1` is
    /// the oldest thread), so a chunk's text only changes when its own
    /// threads do.
    static func consultChunks(storedIn threads: [OrchestratedThread], targetTokens: Int) -> [ConsultChunk] {
        consultChunks(
            threads.enumerated()
                .filter { $0.element.state == .stored }
                .map { (label: "t\($0.offset + 1)", thread: $0.element) },
            targetTokens: targetTokens
        )
    }

    /// Packs `threads`, in the order given, under their labels.
    static func consultChunks(
        _ threads: [(label: String, thread: OrchestratedThread)],
        targetTokens: Int
    ) -> [ConsultChunk] {
        let target = max(1_000, targetTokens)
        var chunks: [ConsultChunk] = []
        var pending: [ConsultChunk.Part] = []
        var pendingTokens = 0

        func rowLine(_ number: Int, _ label: String, _ row: OrchestratedRow) -> String {
            "\(label).\(number) \(row.line)"
        }
        func partTokens(_ part: ConsultChunk.Part) -> Int {
            part.rows.reduce(24) { $0 + AIMessage.approximateTokens(rowLine($1.number, part.threadLabel, $1.row)) + 1 }
        }
        func flush() {
            guard !pending.isEmpty else { return }
            let index = chunks.count + 1
            var lines = ["History chunk \(index) · stored threads, oldest first · rows labelled <thread>.<row>"]
            for part in pending {
                let partNote = part.partNumber.map { " · part \($0)" } ?? ""
                lines.append("")
                lines.append(
                    "Thread \(part.threadLabel) \"\(part.thread.name)\" · \(part.thread.rows.count) messages · \(dateRange(of: part.thread))\(partNote)"
                )
                lines.append(contentsOf: part.rows.map { rowLine($0.number, part.threadLabel, $0.row) })
            }
            chunks.append(
                ConsultChunk(index: index, parts: pending, text: lines.joined(separator: "\n"), tokens: pendingTokens))
            pending = []
            pendingTokens = 0
        }

        for (label, thread) in threads {
            let numbered = thread.rows.enumerated()
                .filter { !$0.element.isChitterChatter }
                .map { (number: $0.offset + 1, row: $0.element) }
            guard !numbered.isEmpty else { continue }
            let whole = ConsultChunk.Part(threadLabel: label, thread: thread, rows: numbered, partNumber: nil)
            let tokens = partTokens(whole)
            if tokens <= target {
                if pendingTokens + tokens > target { flush() }
                pending.append(whole)
                pendingTokens += tokens
                continue
            }
            // Bigger than a chunk: consecutive parts, each a chunk of its own.
            flush()
            var slice: [(number: Int, row: OrchestratedRow)] = []
            var sliceTokens = 24
            var partNumber = 1
            for entry in numbered {
                let cost = AIMessage.approximateTokens(rowLine(entry.number, label, entry.row)) + 1
                if sliceTokens + cost > target, !slice.isEmpty {
                    pending = [.init(threadLabel: label, thread: thread, rows: slice, partNumber: partNumber)]
                    pendingTokens = sliceTokens
                    flush()
                    slice = []
                    sliceTokens = 24
                    partNumber += 1
                }
                slice.append(entry)
                sliceTokens += cost
            }
            if !slice.isEmpty {
                pending = [.init(threadLabel: label, thread: thread, rows: slice, partNumber: partNumber)]
                pendingTokens = sliceTokens
                flush()
            }
        }
        flush()
        return chunks
    }

    /// The first `{…}` in `text` that decodes as `T` — models wrap JSON in
    /// prose or code fences however they're asked.
    static func firstJSONObject<T: Decodable>(in text: String) -> T? {
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = open
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(text[open...index])
                        if let data = candidate.data(using: .utf8),
                            let decoded = try? JSONDecoder().decode(T.self, from: data)
                        {
                            return decoded
                        }
                        break
                    }
                }
                index = text.index(after: index)
            }
            searchStart = text.index(after: open)
        }
        return nil
    }

    func consult(
        _ chunks: [ConsultChunk],
        brief: ThreadConsultBrief,
        with consultant: ThreadConsultant,
        presentedLastTurn: Set<UUID> = []
    ) async -> ThreadConsultResolution {
        .resolve(
            await runThreadConsults(
                chunks, brief: brief, model: consultant.model, connector: consultant.connector,
                configuration: consultant.configuration
            ),
            presentedLastTurn: presentedLastTurn
        )
    }

    /// One consult: the chunk under its brief, no tools, a JSON reply.
    func consultOutcome(
        _ chunk: ConsultChunk,
        brief: ThreadConsultBrief,
        model: String,
        connector: any AIConnector,
        configuration: AITurnConfiguration
    ) async -> ThreadConsultOutcome {
        var chunkConfiguration = configuration
        chunkConfiguration.telemetry?.label = [brief.label, "chunk \(chunk.index) · \(chunk.threadCount) threads"]
            .compactMap { $0 }.joined(separator: " · ")
        do {
            let turn = try await connector.completeTurn(
                messages: brief.messages(for: chunk),
                tools: [],
                model: model,
                toolChoice: nil,
                stage: .execution,
                configuration: chunkConfiguration,
                toolExecutor: nil
            )
            if let usage = turn.usage {
                onLog?(
                    "[ai.usage] turn=\(configuration.telemetry?.agentTurnID?.uuidString.prefix(8) ?? "?") role=consult \(usage.logDescription)"
                )
            }
            guard let reply: ThreadConsultReply = Self.firstJSONObject(in: turn.assistantText ?? "") else {
                return ThreadConsultOutcome(chunk: chunk, reply: nil, failure: "unparseable reply")
            }
            return ThreadConsultOutcome(chunk: chunk, reply: reply)
        } catch {
            return ThreadConsultOutcome(chunk: chunk, reply: nil, failure: error.localizedDescription)
        }
    }

    /// One consult per chunk, all in parallel: each chunk is its own cached
    /// prefix, so there is no shared, unwritten prefix to stagger for.
    func runThreadConsults(
        _ chunks: [ConsultChunk],
        brief: ThreadConsultBrief,
        model: String,
        connector: any AIConnector,
        configuration: AITurnConfiguration
    ) async -> [ThreadConsultOutcome] {
        var outcomes: [Int: ThreadConsultOutcome] = [:]
        await withTaskGroup(of: (Int, ThreadConsultOutcome).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    (
                        index,
                        await self.consultOutcome(
                            chunk, brief: brief, model: model, connector: connector, configuration: configuration)
                    )
                }
            }
            for await (index, outcome) in group { outcomes[index] = outcome }
        }
        return chunks.indices.compactMap { outcomes[$0] }
    }

    /// The collector's extra turn-context sections: what the consults found,
    /// newest thread first, and the rows they cited.
    static func collectorSections(
        resolution: ThreadConsultResolution,
        transcripts: PresentedTranscripts?,
        claimMarked: Bool
    ) -> [String] {
        var sections: [String] = []
        let header =
            "Retrieved from stored history this turn (\(resolution.consultedChunks) chunk(s) covering \(resolution.consultedThreads) thread(s), read verbatim):"
        let findings = resolution.findings.sorted {
            ($0.thread.rows.last?.timestamp ?? .distantPast) > ($1.thread.rows.last?.timestamp ?? .distantPast)
        }
        if findings.isEmpty {
            sections.append(header + "\n- nothing in the stored history bears on this message.")
        } else {
            let lines = findings.map { finding -> String in
                var line = "- \"\(finding.thread.name)\" (\(finding.threadLabel))"
                if finding.verdict == .answer { line += " — the message resumes this thread" }
                if finding.promoted { line += " (relevant two turns running)" }
                if !finding.facts.isEmpty { line += ":\n  " + finding.facts.joined(separator: "\n  ") }
                if !finding.constraints.isEmpty {
                    line += "\n  must honour: " + finding.constraints.joined(separator: "; ")
                }
                return line
            }
            sections.append(header + "\n" + lines.joined(separator: "\n"))
        }
        if let answering = resolution.answering {
            sections.append(
                claimMarked
                    ? "This message resumes the stored thread \"\(answering.thread.name)\": a turning point has already been marked at it. Answer in that thread's frame, and do not call \(markTurningPointToolFunctionName) this turn."
                    : "This message appears to resume the stored thread \"\(answering.thread.name)\". Decide yourself whether that is a turning point."
            )
        } else if !resolution.contestedClaims.isEmpty {
            let names = resolution.contestedClaims.map { "\"\($0.thread.name)\"" }.joined(separator: ", ")
            sections.append(
                "Several stored threads claim this message: \(names). You decide which, if any, it resumes.")
        }
        if let transcripts, !transcripts.text.isEmpty {
            sections.append("Rows the consults cited (verbatim, oldest first):\n\(transcripts.text)")
        }
        if let note = transcripts?.truncationNote { sections.append(note) }
        return sections
    }
}
