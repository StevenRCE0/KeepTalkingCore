import Crypto
import FluentKit
import Foundation

// MARK: - In and out

/// What one turn hands the transcript build: the message, the models the
/// consultants borrow, and what the system prompt is rendered from.
struct OrchestrationTurn: Sendable {
    let agent: KeepTalkingAgentConfiguration
    let prompt: String
    let userMessage: AIMessage
    let promptMessageID: UUID?
    let agentTurnID: UUID
    /// A resumed turn: its own rows are already in the checkpoint.
    let resumingCheckpoint: Bool
    let tools: [KeepTalkingActionToolDefinition]
    let turnConfiguration: AITurnConfiguration
    let actionStubs: [KeepTalkingActionStub]
    let remoteActionCreationActions: [KeepTalkingActionCreationCatalogEntry]
    let aliasLookup: KeepTalkingAliasLookup
    let hasCurrentPromptAttachments: Bool
    let allowAutomaticToolUse: Bool
    let currentDate: String
    let platform: String

    var excludedAgentTurnID: UUID? { resumingCheckpoint ? agentTurnID : nil }
}

/// The request the main loop starts from.
struct OrchestrationTranscript: Sendable {
    let messages: [AIMessage]
    let turnConfiguration: AITurnConfiguration
    /// The telemetry role of the loop's calls: `.collector` once consult
    /// findings are stitched in.
    let role: AITurnTelemetry.Role
    /// How the loop's `kt_search_threads` hands back what it finds.
    let search: ThreadSearchHandOver
}

// MARK: - The build

extension KeepTalkingClient {
    /// Builds this turn's transcript and hands it to `body`, which runs the
    /// main loop. That is the one boundary: nothing here looks inside the
    /// loop, and the loop's own searches come back as its tool results (and,
    /// next turn, through the first pass).
    ///
    /// 1. **First pass**, additive: the context's rows — messages, the threads
    ///    earlier searches revealed, turning-point and chitter-chatter marks —
    ///    and its side notes, into a ledger.
    /// 2. **Chunking**: the strategy, sized to the model's window, cuts stored
    ///    history into chunks; the newest are consulted, threads older than
    ///    that go to the index by name, and revealed threads that fit are kept.
    /// 3. **Fan-out**: one task group consumes the chunks, a consult each.
    /// 4. **Stitching**: findings, cited rows and revealed threads into the
    ///    turn context; then `body`.
    ///
    /// No strategy builds `.legacy`.
    func withOrchestrationTranscript<Result>(
        _ context: KeepTalkingContext,
        providerProfile: AIModelProfile?,
        alternativeStrategy: KeepTalkingOrchestrationStrategy? = nil,
        turn: OrchestrationTurn,
        _ body: (OrchestrationTranscript) async throws -> Result
    ) async throws -> Result {
        let strategy = alternativeStrategy ?? .legacy
        let ledger = try await orchestrationLedger(
            contextID: try context.requireID(),
            layout: strategy.layout,
            revealedThreadsKept: strategy.revealedThreadsKept,
            revealedCeilingTokens: strategy.presentedTokens(for: providerProfile),
            aliasLookup: turn.aliasLookup,
            excludingAgentTurnID: turn.excludedAgentTurnID
        )
        let plan = OrchestrationPlan(ledger, strategy: strategy, profile: providerProfile)
        let consultant = ThreadConsultant(
            strategy: strategy, profile: providerProfile, main: turn.agent.main, contextID: ledger.contextID,
            agentTurnID: turn.agentTurnID
        )
        let resolution = await fanOut(plan, consultant: consultant, turn: turn)
        let search = ThreadSearchHandOver(
            strategy: strategy, profile: providerProfile, consultant: consultant, userPrompt: turn.prompt)
        let transcript = try await stitch(plan, resolution, search: search, context: context, turn: turn)
        return try await body(transcript)
    }

    /// A per-conversation prompt-cache key: OpenAI's `prompt_cache_key`, and
    /// on OpenRouter the session that keeps a conversation on one upstream
    /// (sticky routing) so its cache stays warm. A hash, so the context id
    /// itself never leaves the node.
    static func promptCacheKey(for contextID: UUID) -> String {
        let digest = SHA256.hash(data: Data("keeptalking.context.\(contextID.uuidString.lowercased())".utf8))
        return "kt-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 1. First pass

/// Everything the context holds that a transcript is built from, read once
/// per run (§3.1): a peer's sync or a moved turning point mid-run changes the
/// store, not this.
struct OrchestrationLedger: Sendable {
    let contextID: UUID
    /// Threads oldest first, marks applied; one synthetic live thread when no
    /// mark resolved. Empty for `.legacy`, which reads its own history window.
    let threads: [OrchestratedThread]
    /// The context's live side notes.
    let sideNotes: [KeepTalkingSideNoteDTO]
    /// Threads earlier searches revealed, newest first, read here.
    let revealed: [RetrievedThread]

    var live: OrchestratedThread? { threads.last { $0.state == .contextMain } }
}

extension KeepTalkingClient {
    /// Rows the legacy layout scans for search Output rows: it reads no
    /// further back than its own history window.
    static let revealScanRows = 512

    /// The additive first pass: each kind of row adds what it carries —
    /// `.message` rows the transcript, turning-point and chitter-chatter marks
    /// the thread bounds and noise flags (through the thread records they
    /// keep), search Output rows the threads they revealed — then the side
    /// notes.
    func orchestrationLedger(
        contextID: UUID,
        layout: KeepTalkingOrchestrationStrategy.Layout,
        revealedThreadsKept: Int,
        revealedCeilingTokens: Int,
        aliasLookup: KeepTalkingAliasLookup,
        excludingAgentTurnID: UUID?
    ) async throws -> OrchestrationLedger {
        let database = localStore.database
        let messages: [KeepTalkingContextMessage]
        let threads: [OrchestratedThread]
        switch layout {
            case .orchestrated:
                messages = try await KeepTalkingContextMessage.query(on: database)
                    .filter(\.$context.$id, .equal, contextID)
                    .all()
                    .sortedForSync()
                threads = try await orchestratedThreads(messages, contextID: contextID, aliasLookup: aliasLookup)
            case .legacy:
                messages = try await Self.messagePage(
                    in: contextID, direction: .backward, limit: Self.revealScanRows, attachments: .none, on: database
                ).messages
                threads = []
        }

        var revealed: [RetrievedThread] = []
        for threadID in await revealedThreadIDs(
            in: messages, excludingAgentTurnID: excludingAgentTurnID, limit: revealedThreadsKept)
        {
            if let thread = try? await retrievedThread(
                threadID, score: 0, aliasLookup: aliasLookup, ceilingTokens: revealedCeilingTokens)
            {
                revealed.append(thread)
            }
        }

        let sideNotes =
            try await KeepTalkingSideNote.query(on: database)
            .filter(\.$context.$id == contextID)
            .filter(\.$isArchived == false)
            .all()
            .map(KeepTalkingSideNoteDTO.init)
            .sorted { $0.key < $1.key }
        return OrchestrationLedger(contextID: contextID, threads: threads, sideNotes: sideNotes, revealed: revealed)
    }

    /// The thread records laid over the rows, oldest first. Rows no thread
    /// covers after the last stored one are the live thread.
    private func orchestratedThreads(
        _ allMessages: [KeepTalkingContextMessage],
        contextID: UUID,
        aliasLookup: KeepTalkingAliasLookup
    ) async throws -> [OrchestratedThread] {
        let threadRows = try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)
            .all()

        func rows(_ slice: ArraySlice<KeepTalkingContextMessage>, chitter: Set<UUID>) -> [OrchestratedRow] {
            slice.compactMap { message in
                guard let id = message.id, case .message = message.type else { return nil }
                return OrchestratedRow(
                    id: id,
                    timestamp: message.timestamp,
                    sender: message.sender,
                    content: message.content,
                    agentTurnID: message.agentTurnID,
                    isChitterChatter: chitter.contains(id)
                )
            }
        }

        var threads: [OrchestratedThread] =
            threadRows
            .compactMap { thread -> (KeepTalkingThread, ClosedRange<Int>)? in
                guard let range = thread.resolvedMessageRange(in: allMessages) else { return nil }
                return (thread, range)
            }
            .sorted { $0.1.lowerBound < $1.1.lowerBound }
            .compactMap { thread, range in
                guard let threadID = thread.id else { return nil }
                return OrchestratedThread(
                    threadID: threadID,
                    state: thread.state,
                    startMessageID: thread.$startMessage.id ?? allMessages[range.lowerBound].id,
                    name: threadTopicName(for: thread, messages: Array(allMessages[range]), aliasLookup: aliasLookup),
                    rows: rows(allMessages[range], chitter: Set(thread.chitterChatter))
                )
            }
        if threads.isEmpty || !threads.contains(where: { $0.state == .contextMain }) {
            let lastStoredEnd =
                threadRows
                .compactMap { $0.resolvedMessageRange(in: allMessages)?.upperBound }
                .max()
            let liveStart = lastStoredEnd.map { $0 + 1 } ?? 0
            if liveStart < allMessages.count {
                threads.append(
                    OrchestratedThread(
                        threadID: contextID,
                        state: .contextMain,
                        startMessageID: allMessages[liveStart].id,
                        name: "untitled",
                        rows: rows(allMessages[liveStart...], chitter: [])
                    )
                )
            }
        }
        return threads
    }
}

// MARK: - 2. Chunking

/// The ledger cut by the strategy for this model. Pure: no model calls, no
/// writes.
struct OrchestrationPlan: Sendable {
    let strategy: KeepTalkingOrchestrationStrategy
    let profile: AIModelProfile?
    let ledger: OrchestrationLedger
    /// The newest chunks of stored history — whole threads, oldest first —
    /// one consult each before the reply.
    let consultChunks: [ConsultChunk]
    /// Stored threads no consult reads (older than the consult window, or
    /// archived), listed by name for `kt_search_threads`.
    let index: [OrchestratedThread]
    /// Revealed threads the turn context carries again, within the presented
    /// budget (the live thread is already verbatim).
    let revealed: [RetrievedThread]

    init(_ ledger: OrchestrationLedger, strategy: KeepTalkingOrchestrationStrategy, profile: AIModelProfile?) {
        self.strategy = strategy
        self.profile = profile
        self.ledger = ledger

        // Chunks are packed oldest first and never change once full, so the
        // window drops a whole chunk into the index at a time.
        let chunks = KeepTalkingClient.consultChunks(
            storedIn: ledger.threads, targetTokens: strategy.chunkTokens(for: profile))
        let window =
            strategy.layout == .orchestrated && strategy.consultsStoredThreads
            ? Array(chunks.suffix(max(0, strategy.consultWindowChunks))) : []
        consultChunks = window
        let consulted = Set(window.flatMap { $0.parts.map(\.thread.threadID) })
        index =
            strategy.layout == .orchestrated
            ? ledger.threads.filter { $0.state != .contextMain && !consulted.contains($0.threadID) } : []

        var revealedLeft = strategy.presentedTokens(for: profile)
        var revealed: [RetrievedThread] = []
        for thread in ledger.revealed where thread.thread.threadID != ledger.live?.threadID {
            guard thread.tokens <= revealedLeft else { continue }
            revealedLeft -= thread.tokens
            revealed.append(thread)
        }
        self.revealed = revealed
    }
}

// MARK: - 3. Fan-out

extension KeepTalkingClient {
    /// One consult per chunk, all in one task group, each asked the user's
    /// message over its chunk of stored history.
    func fanOut(
        _ plan: OrchestrationPlan, consultant: ThreadConsultant, turn: OrchestrationTurn
    ) async -> ThreadConsultResolution? {
        guard !plan.consultChunks.isEmpty else { return nil }
        let strategy = plan.strategy
        return await consult(
            plan.consultChunks,
            brief: .turn(
                userMessage: Self.speakerTagged(turn.userMessage, node: config.node),
                liveTail: (plan.ledger.live?.rows ?? [])
                    .filter { $0.id != turn.promptMessageID }
                    .suffix(strategy.consultLiveTailRows)
                    .map(\.message)
            ),
            with: consultant,
            presentedLastTurn: strategy.claimsMarkTurningPoints
                ? contextOrchestrationMemory[plan.ledger.contextID]?.presentedThreadStarts ?? [] : []
        )
    }
}

// MARK: - 4. Stitching

extension KeepTalkingClient {
    func stitch(
        _ plan: OrchestrationPlan,
        _ resolution: ThreadConsultResolution?,
        search: ThreadSearchHandOver,
        context: KeepTalkingContext,
        turn: OrchestrationTurn
    ) async throws -> OrchestrationTranscript {
        switch plan.strategy.layout {
            case .legacy: return try await stitchLegacy(plan, search: search, context: context, turn: turn)
            case .orchestrated:
                return try await stitchOrchestrated(plan, resolution, search: search, context: context, turn: turn)
        }
    }

    static func revealedSection(_ threads: [RetrievedThread]) -> String? {
        guard !threads.isEmpty else { return nil }
        return "Threads your earlier searches revealed (verbatim, oldest first):\n" + verbatimTranscript(threads)
    }

    /// Today's layout: one system prompt carrying everything that changes,
    /// the decay-selected history fitted to the window, then `user_n`.
    /// Threads earlier searches revealed ride in a system row after it.
    private func stitchLegacy(
        _ plan: OrchestrationPlan, search: ThreadSearchHandOver, context: KeepTalkingContext, turn: OrchestrationTurn
    ) async throws -> OrchestrationTranscript {
        let contextTranscript = try await agentContextTranscript(
            context,
            actionStubs: turn.actionStubs,
            remoteActionCreationEntries: turn.remoteActionCreationActions
        )
        var contextMessages = try await agentContextMessages(
            context,
            excludingMessageID: turn.promptMessageID,
            excludingAgentTurnID: turn.excludedAgentTurnID
        )
        let systemPrompt = OpenAIConnector.keepTalkingSystemPrompt(
            OrchestrationPromptFactor.groupChat(
                tools: Self.promptToolNames,
                currentPromptIncludesAttachments: turn.hasCurrentPromptAttachments,
                currentPromptShouldAvoidAutomaticToolUse: turn.hasCurrentPromptAttachments
                    && !turn.allowAutomaticToolUse,
                sideNotes: plan.ledger.sideNotes,
                contextTranscript: contextTranscript,
                currentDate: turn.currentDate,
                platform: turn.platform,
                responseLanguages: turn.agent.responseLanguages,
                modelProfile: plan.profile
            )
        )
        let revealed = Self.revealedSection(plan.revealed).map { AIMessage.system($0) }
        // Fit the decay-selected history into the model's window: whatever the
        // system prompt and this turn's message leave over, minus a fifth of
        // the input budget held back for tool rounds within the run. The
        // decay caps still bound a large window; this only ever trims.
        if let inputBudget = plan.profile?.inputTokenBudget {
            let fixedCost =
                AIMessage.system(systemPrompt).approximateTokenCount
                + turn.userMessage.approximateTokenCount
                + (revealed?.approximateTokenCount ?? 0)
            let historyBudget = max(0, inputBudget - fixedCost - inputBudget / 5)
            let trimmed = contextMessages.trimmedToTokenBudget(historyBudget)
            if trimmed.droppedCount > 0 {
                onLog?(
                    "[ai] trimmed \(trimmed.droppedCount) of \(contextMessages.count) history message(s) to fit \(inputBudget)-token input budget"
                )
            }
            contextMessages = trimmed.messages
        }
        return OrchestrationTranscript(
            messages: [AIMessage.system(systemPrompt)] + (revealed.map { [$0] } ?? []) + contextMessages
                + [turn.userMessage],
            turnConfiguration: turn.turnConfiguration,
            role: .main,
            search: search
        )
    }

    /// The orchestrated layout: act on a consult claim, render the stable
    /// prefix, and put the consults' findings, cited rows and the revealed
    /// threads into the turn context.
    private func stitchOrchestrated(
        _ plan: OrchestrationPlan,
        _ resolution: ThreadConsultResolution?,
        search: ThreadSearchHandOver,
        context: KeepTalkingContext,
        turn: OrchestrationTurn
    ) async throws -> OrchestrationTranscript {
        let strategy = plan.strategy
        let ledger = plan.ledger
        let contextID = ledger.contextID
        let memory = contextOrchestrationMemory[contextID]
        var turnConfiguration = turn.turnConfiguration
        turnConfiguration.promptCacheKey = Self.promptCacheKey(for: contextID)
        turnConfiguration.toolsCacheBoundary = .durable

        // A claim marks a turning point only when the strategy says so.
        var claimMarked = false
        if strategy.claimsMarkTurningPoints, let answering = resolution?.answering,
            let promptMessageID = turn.promptMessageID
        {
            claimMarked =
                (try? await markTurningPoint(
                    at: promptMessageID,
                    previousTopicName: ledger.live?.name,
                    currentTopicName: answering.thread.name,
                    in: contextID
                )) ?? false
        }

        // The stable prefix.
        let nodeIDs = Set(
            ledger.threads.flatMap(\.rows).compactMap { row -> UUID? in
                if case .node(let nodeID) = row.sender { return nodeID }
                return nil
            }
        )
        let parts = try await agentContextTranscriptParts(
            context,
            actionStubs: turn.actionStubs,
            remoteActionCreationEntries: turn.remoteActionCreationActions,
            threadMap: Self.orchestratedThreadMap(ledger.threads),
            nodeIDs: nodeIDs
        )
        let systemPrompt = OpenAIConnector.keepTalkingSystemPrompt(
            OrchestrationPromptFactor.groupChat(
                tools: Self.promptToolNames,
                contextTranscript: parts.stable,
                currentDate: turn.currentDate,
                platform: turn.platform,
                responseLanguages: turn.agent.responseLanguages,
                modelProfile: plan.profile,
                layout: .orchestrated
            )
        )
        let currentPromptGuidance =
            turn.hasCurrentPromptAttachments
            ? OrchestrationPromptFactor.currentPromptAttachments(
                attachmentListing: Self.promptToolNames[.attachmentListing],
                attachmentReader: Self.promptToolNames[.attachmentReader],
                avoidAutomaticToolUse: !turn.allowAutomaticToolUse
            ).rendered
            : ""
        let turnContext = OrchestratedPrompt.TurnContextParts(
            currentDate: turn.currentDate,
            currentPromptGuidance: currentPromptGuidance,
            sideNotes: ledger.sideNotes,
            perTurnTranscript: parts.perTurn
        )
        // user_n carries the speaker tag its row will carry next turn, so the
        // next request's prefix runs on through it (§10 incrementality).
        let userMessage = Self.speakerTagged(turn.userMessage, node: config.node)
        var excluded: Set<UUID> = turn.promptMessageID.map { [$0] } ?? []
        func render() -> OrchestratedPrompt {
            Self.renderOrchestratedPrompt(
                systemPrompt: systemPrompt,
                index: plan.index,
                live: ledger.live,
                userMessage: userMessage,
                turnContext: turnContext,
                excludingRowIDs: excluded,
                excludingAgentTurnID: turn.excludedAgentTurnID
            )
        }
        var rendered = render()
        // Last resort when even the verbatim live thread overflows the window:
        // drop its oldest rows in 32-row steps, so the cached start of the
        // live thread moves once per 32 rows rather than every turn.
        if let inputBudget = plan.profile?.inputTokenBudget {
            let limit = inputBudget - strategy.outputReserveTokens
            let liveIDs = ledger.live?.rows.map(\.id) ?? []
            var dropped = 0
            while rendered.prefixTokens > limit, dropped < liveIDs.count {
                dropped = min(liveIDs.count, dropped + 32)
                excluded.formUnion(liveIDs.prefix(dropped))
                rendered = render()
            }
            if dropped > 0 {
                onLog?(
                    "[orchestration] live thread over the \(inputBudget)-token input budget: dropped its oldest \(dropped) row(s)"
                )
            }
        }

        // The turn context: findings, the rows they cite, revealed threads.
        var sections: [String] = []
        var transcripts: PresentedTranscripts?
        if let resolution {
            let cited = resolution.citedEntries
            if !cited.isEmpty {
                let window = plan.profile?.inputTokenBudget ?? 128_000
                let budget =
                    window - rendered.prefixTokens - turnContext.row().approximateTokenCount
                    - strategy.outputReserveTokens
                transcripts = PresentedTranscripts.window(
                    cited, budget: budget, cap: strategy.presentedTokens(for: plan.profile))
            }
            sections += Self.collectorSections(
                resolution: resolution, transcripts: transcripts, claimMarked: claimMarked)
        }
        if let revealed = Self.revealedSection(plan.revealed) { sections.append(revealed) }
        if !sections.isEmpty {
            rendered.messages[rendered.trailingRowIndex] = turnContext.row(extraSections: sections)
        }

        // What the next run compares against.
        let liveExtends =
            memory.map { Array(rendered.liveRowIDs.prefix($0.liveRowIDs.count)) == $0.liveRowIDs } ?? false
        let prefixDirty = memory?.durablePrefixDigest != rendered.durablePrefixDigest || !liveExtends
        onLog?(
            "[orchestration] live=\"\(ledger.live?.name ?? "-")\" (\(rendered.liveRowIDs.count) rows) consulted=\(Set(plan.consultChunks.flatMap { $0.parts.map(\.threadLabel) }).count) index=\(plan.index.count) prefix≈\(rendered.prefixTokens) tok dirty=\(prefixDirty) revealed=\(plan.revealed.count)"
        )
        if let resolution {
            let failures = resolution.failures
            onLog?(
                "[orchestration] consults \(plan.consultChunks.count) chunk(s) (\(plan.consultChunks.map { "\($0.threadCount)t/\($0.tokens)tok" }.joined(separator: ", "))) → \(resolution.findings.count) relevant thread(s): \(resolution.findings.map { "\"\($0.thread.name)\"=\($0.verdict.rawValue) \($0.facts.count)f/\($0.citedRows.count)r" }.joined(separator: ", "))"
                    + (resolution.answering.map { " resumes=\"\($0.thread.name)\"\(claimMarked ? " (marked)" : "")" }
                        ?? "")
                    + (transcripts.map { " cited≈\($0.tokens) tok\($0.truncationNote == nil ? "" : " (truncated)")" }
                        ?? "")
                    + (failures.isEmpty ? "" : " failures=[\(failures.joined(separator: "; "))]")
            )
        }
        contextOrchestrationMemory.update(contextID) { memory in
            memory.durablePrefixDigest = rendered.durablePrefixDigest
            memory.liveRowIDs = rendered.liveRowIDs
            if let resolution {
                memory.presentedThreadStarts = Set(
                    resolution.findings.filter { $0.verdict == .present }.compactMap(\.thread.startMessageID)
                )
            }
        }
        return OrchestrationTranscript(
            messages: rendered.messages,
            turnConfiguration: turnConfiguration,
            role: plan.consultChunks.isEmpty ? .main : .collector,
            search: search
        )
    }

    static func speakerTagged(_ message: AIMessage, node: UUID) -> AIMessage {
        let tag = "[\(node.friendlyNameToken)] "
        switch message.content {
            case .text(let text):
                return AIMessage(role: message.role, content: .text(tag + text), name: message.name)
            case .parts(var parts):
                if let first = parts.firstIndex(where: { if case .text = $0 { return true } else { return false } }),
                    case .text(let text) = parts[first]
                {
                    parts[first] = .text(tag + text)
                } else {
                    parts.insert(.text(tag.trimmingCharacters(in: .whitespaces)), at: 0)
                }
                return AIMessage(role: message.role, content: .parts(parts), name: message.name)
            case nil:
                return message
        }
    }
}
