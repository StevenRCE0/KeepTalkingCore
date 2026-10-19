import AIProxy
import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// The gates of the context-orchestration design (§10): determinism,
/// incrementality, the consult window and overflow, plus the connector
/// placement rules they rest on. Cache accounting
/// against a real provider is a validation harness's job, run through `AIMiddlewareConnector`.
struct ContextOrchestrationTests {

    // MARK: - Overflow (§7.5)

    private func thread(_ name: String, rows: [(Double, String)], chitter: Set<Int> = []) -> OrchestratedThread {
        OrchestratedThread(
            threadID: UUID(),
            state: .stored,
            startMessageID: UUID(),
            name: name,
            rows: rows.enumerated().map { index, row in
                OrchestratedRow(
                    id: UUID(),
                    timestamp: Date(timeIntervalSince1970: row.0),
                    sender: .autonomous(name: "ai", node: nil, model: nil),
                    content: row.1,
                    agentTurnID: nil,
                    isChitterChatter: chitter.contains(index)
                )
            }
        )
    }

    @Test("presented transcripts keep the newest rows across threads within budget and cap")
    func presentedRecencyWindow() {
        let a = thread("A", rows: (0..<20).map { (Double($0 * 2), "a\($0) " + String(repeating: "x", count: 80)) })
        let b = thread(
            "B", rows: (0..<20).map { (Double($0 * 2 + 1), "b\($0) " + String(repeating: "y", count: 80)) },
            chitter: [19])
        let window = PresentedTranscripts.window([a, b], budget: 400, cap: 10_000)
        #expect(window.tokens <= 400)
        #expect(window.text.contains("a19"))
        #expect(!window.text.contains("b19"), "chitter-chatter rows are never presented")
        #expect(window.text.contains("b18"))
        #expect(!window.text.contains("a0 "))
        #expect(window.truncationNote?.contains("\"A\"") == true)
        #expect(window.truncationNote?.contains("\"B\"") == true)

        let capped = PresentedTranscripts.window([a, b], budget: 100_000, cap: 120)
        #expect(capped.tokens <= 120, "the hard cap wins over a large window")

        let none = PresentedTranscripts.window([a, b], budget: -5_000, cap: 6_000)
        #expect(none.text.isEmpty)
        #expect(none.truncationNote != nil, "overflow is a note, never a failure")

        let everything = PresentedTranscripts.window([a], budget: 100_000, cap: 100_000)
        #expect(everything.truncationNote == nil)
    }

    // MARK: - Placement and breakpoints (§4.1, §4.2)

    @Test("OpenAI wire: a system row after dialogue is wrapped for hoisting providers, inline for OpenAI")
    func openAIPlacement() throws {
        let row = AIMessage.system("Turn context")
        let wrapped = OpenAIConnector.translateMessage(row, followsDialogue: true, placement: .wrappedInUserTurn)
        let inline = OpenAIConnector.translateMessage(row, followsDialogue: true, placement: .inline)
        let leading = OpenAIConnector.translateMessage(row, followsDialogue: false, placement: .wrappedInUserTurn)
        let encode: (OpenAIChatCompletionRequestBody.Message) throws -> String = {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }
        #expect(try encode(wrapped).contains("\"role\":\"user\""))
        #expect(try encode(wrapped).contains("<system>"))
        #expect(try encode(inline).contains("\"role\":\"system\""))
        #expect(try encode(leading).contains("\"role\":\"system\""))

        let router = try OpenAIConnector(apiKey: "test", backend: .openRouter)
        #expect(router.systemRowPlacement(forModel: "openai/gpt-5") == .inline)
        #expect(router.systemRowPlacement(forModel: "google/gemini-3.8-flash") == .wrappedInUserTurn)
        #expect(router.cacheBreakpoints(forModel: "anthropic/claude-sonnet-5") == (true, true))
        #expect(router.cacheBreakpoints(forModel: "google/gemini-3.8-flash") == (true, false))
        #expect(router.cacheBreakpoints(forModel: "openai/gpt-5") == (false, false))
        let direct = try OpenAIConnector(apiKey: "test", backend: .openAI)
        #expect(direct.cacheBreakpoints(forModel: "gpt-5") == (false, false))

        // Through AIProxy's own type: the row's content becomes parts, the last one marked.
        let marked = OpenAIChatCompletionRequestBody.Message.cacheBreakpoint(
            OpenAIConnector.translateMessage(.system("stable")), cacheControl: .init(ttl: "1h"))
        let json = try encode(marked)
        #expect(
            json.contains(#""cache_control""#) && json.contains(#""ttl":"1h""#) && json.contains(#""type":"ephemeral""#)
        )
        #expect(json.contains(#""text":"stable""#))
    }

    @Test("Anthropic: leading system rows become system blocks, later ones wrapped user turns")
    func anthropicPlacement() throws {
        let (system, messages) = AnthropicConnector.translateMessages([
            AIMessage.system("stable").withCacheBoundary(.durable),
            .system("memory"),
            .user("hello").withCacheBoundary(.rolling),
            .system("turn context"),
        ])
        let systemJSON = String(decoding: try JSONEncoder().encode(system), as: UTF8.self)
        #expect(systemJSON.contains("\"ttl\":\"1h\""))
        #expect(systemJSON.contains("memory"))
        #expect(!systemJSON.contains("turn context"), "a trailing system row is never hoisted")
        #expect(messages.count == 2)
        let trailing = String(decoding: try JSONEncoder().encode(messages[1]), as: UTF8.self)
        #expect(trailing.contains("<system>"))
        let user = String(decoding: try JSONEncoder().encode(messages[0]), as: UTF8.self)
        #expect(user.contains("cache_control"))
    }

    // MARK: - End to end through runAI

    /// Answers every call and records it. Consult requests get the JSON
    /// their callers parse.
    private actor ScriptedModel: AIConnector {
        nonisolated let capabilities = AIConnectorCapabilities(supportsNativeToolCalling: true)
        private(set) var requests: [(messages: [AIMessage], tools: [String], configuration: AITurnConfiguration?)] = []
        /// What every consult answers (JSON).
        var consultReply = #"{"relevant": []}"#
        /// Answers the next main-loop call with this tool call, once.
        var pendingToolCall: AIToolCall?

        func setConsultReply(_ reply: String) { consultReply = reply }
        func callToolOnce(_ call: AIToolCall) { pendingToolCall = call }

        func completeTurn(
            messages: [AIMessage],
            tools: [KeepTalkingActionToolDefinition],
            model: String,
            toolChoice: AIToolChoice?,
            stage: AIStage,
            configuration: AITurnConfiguration?,
            toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
        ) async throws -> AITurnResult {
            requests.append((messages, tools.map(\.functionName), configuration))
            let last = messages.last?.content?.text ?? ""
            if last.contains("Consultation —") {
                return AITurnResult(assistantText: consultReply, toolCalls: [])
            }
            if let call = pendingToolCall {
                pendingToolCall = nil
                return AITurnResult(assistantText: nil, toolCalls: [call])
            }
            return AITurnResult(assistantText: "Reply \(requests.count).", toolCalls: [])
        }
    }

    private func seededSurface(_ model: ScriptedModel) async throws -> AgentSurface {
        let surface = try await AgentSurface.make(aiConnector: model)
        let topics = ["alpha", "bravo", "charlie", "delta"]
        for topic in topics {
            for index in 0..<4 {
                try await surface.client.send("\(topic) message \(index)", in: surface.contextID)
            }
        }
        let ids = try await KeepTalkingContextMessage.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID)
            .all()
            .sortedForSync()
            .compactMap(\.id)
        for (offset, topic) in topics.enumerated().dropFirst() {
            try await surface.client.markTurningPoint(
                at: ids[offset * 4], currentTopicName: topic, in: surface.contextID)
        }
        return surface
    }

    private func strategy(consults: Bool) -> KeepTalkingOrchestrationStrategy {
        var strategy = KeepTalkingOrchestrationStrategy.orchestrated
        strategy.consultsStoredThreads = consults
        return strategy
    }

    private func agent(_ model: ScriptedModel, consults: Bool) -> KeepTalkingAgentConfiguration {
        KeepTalkingAgentConfiguration(
            main: .init(connector: model, model: "test"), orchestrationStrategy: strategy(consults: consults))
    }

    /// Phases 1 and 2 only: the ledger, cut by `strategy`.
    private func plan(
        _ surface: AgentSurface, strategy: KeepTalkingOrchestrationStrategy = .orchestrated
    ) async throws -> OrchestrationPlan {
        let lookup = try await surface.client.aliasLookup().scoped(to: surface.contextID)
        let ledger = try await surface.client.orchestrationLedger(
            contextID: surface.contextID, layout: .orchestrated, revealedThreadsKept: 0, revealedCeilingTokens: 0,
            aliasLookup: lookup, excludingAgentTurnID: nil
        )
        return OrchestrationPlan(ledger, strategy: strategy, profile: nil)
    }

    @Test("rendering the same plan twice gives identical messages (determinism)")
    func determinism() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let plan = try await plan(surface)
        let parts = OrchestratedPrompt.TurnContextParts(
            currentDate: "Sunday", currentPromptGuidance: "", sideNotes: [], perTurnTranscript: "map"
        )
        let render = {
            KeepTalkingClient.renderOrchestratedPrompt(
                systemPrompt: "system", index: plan.index, live: plan.ledger.live, userMessage: .user("now"),
                turnContext: parts, excludingRowIDs: [], excludingAgentTurnID: nil
            )
        }
        let first = render()
        let second = render()
        #expect(first.messages == second.messages)
        #expect(first.durablePrefixDigest == second.durablePrefixDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first.messages) == encoder.encode(second.messages))
        #expect(plan.ledger.live?.name == "delta")
        #expect(plan.consultChunks.count == 1, "three small stored threads fit one chunk")
        #expect(plan.index.isEmpty, "every stored thread is inside the consult window")
        #expect(first.messages.count == 1 + 4 + 2, "system, the live rows, user_n, turn context")
        await surface.shutdown()
    }

    @Test("a clean next turn is the previous prefix plus appended rows (incrementality)")
    func incrementality() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let config = agent(model, consults: false)
        _ = try await surface.client.runDequeuedAIPrompt("first question", in: surface.contextID, agent: config)
        _ = try await surface.client.runDequeuedAIPrompt("second question", in: surface.contextID, agent: config)

        let mains = await model.requests.filter { request in
            !(request.messages.last?.content?.text.contains("Thread freeze") ?? false)
        }
        #expect(mains.count == 2)
        let first = mains[0].messages
        let second = mains[1].messages
        // First request: …, user_n, turn context. Everything before its turn
        // context is a prefix of the second request.
        let firstPrefix = Array(first.dropLast())
        #expect(Array(second.prefix(firstPrefix.count)).map(\.content) == firstPrefix.map(\.content))
        // …followed by the reply, then the new user_n and turn context.
        #expect(second.count == firstPrefix.count + 3)
        #expect(second[firstPrefix.count].role == .assistant)
        #expect(second.last?.content?.text.hasPrefix("Turn context") == true)
        // Breakpoints: system durable, last live row rolling.
        #expect(first.first?.cacheBoundary == .durable)
        #expect(first.contains { $0.cacheBoundary == .rolling })
        #expect(mains[0].configuration?.toolsCacheBoundary == .durable)
        #expect(mains[0].configuration?.promptCacheKey?.hasPrefix("kt-") == true)
        await surface.shutdown()
    }

    @Test("consult chunks hold every stored thread once, whole, oldest first; oversized threads split")
    func consultChunkPacking() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let threads = try await plan(surface).ledger.threads
        let stored = threads.filter { $0.state == .stored }
        #expect(stored.count == 3)
        let one = KeepTalkingClient.consultChunks(storedIn: threads, targetTokens: 32_000)
        #expect(one.count == 1)
        #expect(one[0].parts.map(\.thread.name) == stored.map(\.name))
        #expect(one[0].text.contains("t1.1 "))
        #expect(!one[0].text.contains("delta"), "the live thread is the collector's, never a consult's")

        // A small target still packs whole threads, oldest first.
        let small = KeepTalkingClient.consultChunks(storedIn: threads, targetTokens: 1_000)
        let labels = small.flatMap { $0.parts.map(\.threadLabel) }
        #expect(Set(labels).count == 3)
        #expect(labels == labels.sorted(), "oldest first")
        await surface.shutdown()
    }

    @Test("a thread bigger than one chunk is split into consecutive parts, every row kept once")
    func consultChunkSplitsOversizedThread() {
        let big = thread("big", rows: (0..<200).map { (Double($0), "row \($0) " + String(repeating: "z", count: 90)) })
        let small = thread("small", rows: [(1_000, "after")])
        let live = OrchestratedThread(
            threadID: UUID(), state: .contextMain, startMessageID: UUID(), name: "live", rows: [])
        let chunks = KeepTalkingClient.consultChunks(storedIn: [big, small, live], targetTokens: 1_000)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.tokens <= 1_000 })
        let bigRows = chunks.flatMap { $0.parts.filter { $0.threadLabel == "t1" }.flatMap { $0.rows.map(\.number) } }
        #expect(bigRows == Array(1...200))
        #expect(chunks.last?.parts.last?.threadLabel == "t2")
    }

    @Test("a consult's chunk is a durable prefix that stays byte-identical across turns")
    func consultChunkIsStable() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let config = agent(model, consults: true)
        _ = try await surface.client.runDequeuedAIPrompt("first", in: surface.contextID, agent: config)
        _ = try await surface.client.runDequeuedAIPrompt("second", in: surface.contextID, agent: config)
        let consults = await model.requests.filter { $0.configuration?.telemetry?.role == .consult }
        #expect(consults.count == 2, "one chunk, one consult per turn")
        let prefixes = consults.map { Array($0.messages.prefix(2)) }
        #expect(prefixes[0] == prefixes[1])
        #expect(prefixes[0][1].cacheBoundary == .durable)
        #expect(consults.allSatisfy { $0.tools.isEmpty }, "consults never get tools")
        #expect(consults[1].messages.contains { $0.content?.text.contains("first") == true }, "they see the live tail")
        await surface.shutdown()
    }

    @Test("rows a consult cites reach the collector verbatim, with its facts")
    func consultCitationsReachCollector() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        await model.setConsultReply(
            #"{"relevant": [{"thread": "t2", "verdict": "present", "facts": ["bravo said 2"], "refs": ["t2.3", "bogus"]}]}"#
        )
        _ = try await surface.client.runDequeuedAIPrompt(
            "what did bravo say?", in: surface.contextID, agent: agent(model, consults: true))
        let collector = await model.requests.last { $0.configuration?.telemetry?.role == .collector }
        let trailing = collector?.messages.last?.content?.text ?? ""
        #expect(trailing.contains("Retrieved from stored history"))
        #expect(trailing.contains("bravo said 2"))
        #expect(trailing.contains("t2.3 "))
        #expect(trailing.contains("bravo message 2"))
        #expect(!trailing.contains("bogus"))
        await surface.shutdown()
    }

    @Test("an answering consult marks a turning point only when claims are enabled")
    func answerClaimsTheTurn() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        await model.setConsultReply(#"{"relevant": [{"thread": "t2", "verdict": "answer", "refs": ["t2.1"]}]}"#)
        let before = try await surface.client.threads(for: surface.contextID).count
        _ = try await surface.client.runDequeuedAIPrompt(
            "back to bravo", in: surface.contextID, agent: agent(model, consults: true))
        #expect(try await surface.client.threads(for: surface.contextID).count == before, "default: nothing marked")
        let collector = await model.requests.last { $0.configuration?.telemetry?.role == .collector }
        #expect(collector?.messages.last?.content?.text.contains("appears to resume") == true)

        var claiming = agent(model, consults: true)
        claiming.orchestrationStrategy?.claimsMarkTurningPoints = true
        _ = try await surface.client.runDequeuedAIPrompt("bravo again", in: surface.contextID, agent: claiming)
        #expect(try await surface.client.threads(for: surface.contextID).count == before + 1)
        await surface.shutdown()
    }

    @Test("an orchestrated turn writes nothing into the conversation: no summaries, no cards")
    func nothingWrittenIntoTheConversation() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let before = try await KeepTalkingContextMessage.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID).count()
        _ = try await surface.client.runDequeuedAIPrompt(
            "one", in: surface.contextID, agent: agent(model, consults: true))
        let notes = try await KeepTalkingSideNote.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID).count()
        #expect(notes == 0)
        let after = try await KeepTalkingContextMessage.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID).count()
        #expect(after == before + 2, "the prompt and the reply, nothing else")
        let main = await model.requests.last { $0.configuration?.telemetry?.role == .collector }
        let text = main?.messages.compactMap { $0.content?.text }.joined(separator: "\n") ?? ""
        #expect(!text.contains("Summary:"))
        #expect(!text.contains("card"))
        await surface.shutdown()
    }

    @Test("threads older than the consult window are listed by name only")
    func consultWindowAndIndex() {
        let old = (0..<3).map { index in
            thread(
                "old \(index)",
                rows: (0..<40).map {
                    (Double(index * 100 + $0), "old \(index) row \($0) " + String(repeating: "w", count: 60))
                })
        }
        let recent = thread("recent", rows: [(1_000, "recent row")])
        let live = OrchestratedThread(
            threadID: UUID(), state: .contextMain, startMessageID: UUID(), name: "live",
            rows: [
                OrchestratedRow(
                    id: UUID(), timestamp: Date(timeIntervalSince1970: 2_000),
                    sender: .autonomous(name: "ai", node: nil, model: nil), content: "live row", agentTurnID: nil,
                    isChitterChatter: false)
            ])
        let ledger = OrchestrationLedger(
            contextID: UUID(), threads: old + [recent, live], sideNotes: [], revealed: [])
        var strategy = KeepTalkingOrchestrationStrategy.orchestrated
        strategy.chunkWindowShare = 0.0125  // 1,000-token chunks on the fallback window
        strategy.consultWindowChunks = 1
        let plan = OrchestrationPlan(ledger, strategy: strategy, profile: nil)
        #expect(plan.consultChunks.count == 1)
        let consulted = Set(plan.consultChunks.flatMap { $0.parts.map(\.thread.name) })
        #expect(consulted.contains("recent"))
        #expect(plan.index.map(\.name).allSatisfy { $0.hasPrefix("old") })
        #expect(!plan.index.isEmpty)
        #expect(Set(plan.index.map(\.name)).isDisjoint(with: consulted))

        let prompt = KeepTalkingClient.renderOrchestratedPrompt(
            systemPrompt: "system", index: plan.index, live: ledger.live, userMessage: .user("now"),
            turnContext: .init(currentDate: "Sunday", currentPromptGuidance: "", sideNotes: [], perTurnTranscript: ""),
            excludingRowIDs: [], excludingAgentTurnID: nil
        )
        let index = prompt.messages[1].content?.text ?? ""
        #expect(index.hasPrefix("Older threads, by name"))
        #expect(index.contains("\"old 0\""))
        #expect(!index.contains("row"), "names only, never the rows")
        #expect(prompt.messages[1].cacheBoundary == .durable)
    }

    // MARK: - kt_search_threads hand-over

    @Test("retrieval sizes are shares of the model's input window, with a fallback window")
    func retrievalWindowShares() {
        let retrieval = KeepTalkingOrchestrationStrategy.legacy
        let profile = AIModelProfile(contextWindow: 200_000, maxOutputTokens: 8_000)  // 192k input
        #expect(retrieval.verbatimTokens(for: profile) == 38_400)
        #expect(retrieval.chunkTokens(for: profile) == 76_800)
        #expect(retrieval.verbatimTokens(for: nil) == 16_000)
        #expect(retrieval.chunkTokens(for: nil) == 32_000, "unknown window: the measured 32k sweet spot")
    }

    @Test("the plan fills the verbatim allowance in rank order, consults the rest, lists what is past the limit")
    func searchPlan() {
        func retrieved(_ name: String, rows: Int) -> RetrievedThread {
            RetrievedThread(
                thread: thread(name, rows: (0..<rows).map { (Double($0), "\(name) row \($0)") }),
                score: 1, complete: true
            )
        }
        let a = retrieved("a", rows: 10)
        let b = retrieved("b", rows: 40)
        let c = retrieved("c", rows: 80)
        let d = retrieved("d", rows: 5)
        func handOver(consultant: ThreadSearchHandOver.Consultant?) -> ThreadSearchHandOver {
            ThreadSearchHandOver(
                verbatimTokens: a.tokens + d.tokens, chunkTokens: 32_000, consultTokens: b.tokens + 1,
                consultant: consultant, consultEffort: nil, consultMaxOutputTokens: 1_200
            )
        }
        func deliveries(_ handOver: ThreadSearchHandOver) -> [String: ThreadSearchHandOver.Delivery] {
            Dictionary(
                uniqueKeysWithValues: handOver.deliveries([a, b, c, d]).map { ($0.thread.thread.name, $0.delivery) })
        }
        let consultant = ThreadSearchHandOver.Consultant(
            connector: ScriptedModel(), model: "test", userPrompt: nil, agentTurnID: nil, promptCacheKey: nil)
        #expect(
            deliveries(handOver(consultant: consultant))
                == ["a": .verbatim, "b": .answered, "c": .listed, "d": .verbatim],
            "d still fits after b and c overflow")
        #expect(
            deliveries(handOver(consultant: nil)) == [
                "a": .verbatim, "b": .newestRows, "c": .newestRows, "d": .verbatim,
            ])
    }

    private func search(
        _ surface: AgentSurface, _ query: String, handOver: ThreadSearchHandOver
    ) async throws -> [String: Any] {
        let payload = try await surface.client.executeSearchThreadsToolCall(
            rawArguments: #"{"query": "\#(query)"}"#,
            remoteSemanticRetrievalActions: [],
            context: KeepTalkingContext(id: surface.contextID),
            handOver: handOver
        )
        return try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    private func deliveries(_ payload: [String: Any]) -> [String: String] {
        let results = payload["results"] as? [[String: Any]] ?? []
        return Dictionary(
            results.compactMap { result in
                (result["label"] as? String).map { ($0, result["delivery"] as? String ?? "") }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// One long "echo" thread (about 4k tokens) and a short live one after it.
    private func longThreadSurface(_ model: ScriptedModel) async throws -> AgentSurface {
        let surface = try await AgentSurface.make(aiConnector: model)
        let filler = String(repeating: "padding words for length ", count: 3)
        for index in 0..<120 {
            try await surface.client.send("echo note \(index): \(filler)", in: surface.contextID)
        }
        try await surface.client.send("foxtrot opener", in: surface.contextID)
        let ids = try await KeepTalkingContextMessage.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID)
            .all()
            .sortedForSync()
            .compactMap(\.id)
        try await surface.client.markTurningPoint(
            at: ids[120], previousTopicName: "echo", currentTopicName: "foxtrot", in: surface.contextID)
        return surface
    }

    /// 8k window: 1,228 tokens verbatim, 2,457-token chunks.
    private let smallWindow = AIModelProfile(contextWindow: 8_192, maxOutputTokens: 2_048)

    @Test("threads that fit come back whole and verbatim, with no consult")
    func searchReturnsThreadsVerbatim() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let payload = try await search(
            surface, "bravo",
            handOver: ThreadSearchHandOver(
                strategy: .legacy, profile: nil,
                consultant: .init(
                    connector: model, model: "test", userPrompt: nil, agentTurnID: nil, promptCacheKey: nil)
            )
        )
        let threads = payload["threads"] as? String ?? ""
        #expect(threads.contains("— thread \"bravo\""))
        #expect((0..<4).allSatisfy { threads.contains("bravo message \($0)") }, "every row, not an excerpt")
        #expect(deliveries(payload)["bravo"] == "verbatim")
        #expect(payload["answers"] == nil)
        #expect(await model.requests.isEmpty, "nothing to consult")
        await surface.shutdown()
    }

    @Test("a thread too long for the window is consulted in chunks, and the consult must answer")
    func searchConsultsLongThreads() async throws {
        let model = ScriptedModel()
        let surface = try await longThreadSurface(model)
        await model.setConsultReply(
            #"{"relevant": [{"thread": "t1", "verdict": "answer", "facts": ["echo settled on 42"], "refs": ["t1.3"]}]}"#
        )
        let payload = try await search(
            surface, "echo",
            handOver: ThreadSearchHandOver(
                strategy: .legacy, profile: smallWindow,
                consultant: .init(
                    connector: model, model: "test", userPrompt: "what did echo settle on?",
                    agentTurnID: nil, promptCacheKey: nil)
            )
        )
        #expect(deliveries(payload)["echo"] == "answered")
        let answers = payload["answers"] as? [[String: Any]] ?? []
        #expect(answers.first?["facts"] as? [String] == ["echo settled on 42"])
        #expect((payload["evidence"] as? String)?.contains("t1.3 ") == true)
        #expect((payload["evidence"] as? String)?.contains("echo note 2:") == true, "row 3 is the third message")
        #expect((payload["threads"] as? String)?.contains("echo note") != true, "the long thread is not returned whole")
        #expect((payload["note"] as? String)?.contains("too long to return whole") == true)

        let consults = await model.requests.filter { $0.configuration?.telemetry?.role == .consult }
        #expect(consults.count > 1, "about 4k tokens over 2.4k chunks")
        #expect(consults.allSatisfy { $0.configuration?.telemetry?.label?.hasPrefix("search · chunk") == true })
        #expect(consults.allSatisfy { $0.tools.isEmpty })
        let charter = consults[0].messages.last?.content?.text ?? ""
        #expect(charter.contains(#"verdict is ALWAYS "answer""#))
        #expect(charter.contains("NEVER report that something is present"))
        let question = consults[0].messages.dropLast().last?.content?.text ?? ""
        #expect(question.contains("Search query: echo"))
        #expect(question.contains("what did echo settle on?"))
        #expect(consults[0].messages[1].cacheBoundary == .durable, "each chunk is its own cached prefix")
        await surface.shutdown()
    }

    @Test("without a consultant a long thread keeps its newest rows")
    func searchWithoutConsultantKeepsNewestRows() async throws {
        let model = ScriptedModel()
        let surface = try await longThreadSurface(model)
        let payload = try await search(
            surface, "echo", handOver: ThreadSearchHandOver(strategy: .legacy, profile: smallWindow, consultant: nil))
        #expect(deliveries(payload)["echo"] == "newest rows")
        let newest = payload["newest_rows"] as? String ?? ""
        #expect(newest.contains("echo note 119:"))
        #expect(!newest.contains("echo note 0:"))
        #expect(await model.requests.isEmpty)
        await surface.shutdown()
    }

    // MARK: - withOrchestrationTranscript

    @Test("the fan-out runs every consult before the loop's first call")
    func fanOutPrecedesTheLoop() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        _ = try await surface.client.runDequeuedAIPrompt(
            "first", in: surface.contextID, agent: agent(model, consults: true))
        let roles = await model.requests.map { $0.configuration?.telemetry?.role }
        let firstLoopCall = try #require(roles.firstIndex(of: .collector))
        #expect(roles.prefix(firstLoopCall).allSatisfy { $0 == .consult })
        #expect(roles.prefix(firstLoopCall).contains(.consult))
        #expect(!roles.contains(.main), "with consults stitched in, every loop call is the collector")
        await surface.shutdown()
    }

    @Test("a search records what it revealed, and the next turn carries those threads again")
    func revealedThreadsCarryOver() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        // Connect-time bootstrap: mints the keypair the Output row seals to.
        try await surface.client.persistMyNode()
        for layout in [KeepTalkingOrchestrationStrategy.legacy, strategy(consults: false)] {
            await model.callToolOnce(
                AIToolCall(id: "search-1", name: "kt_search_threads", argumentsJSON: #"{"query": "bravo"}"#))
            let config = KeepTalkingAgentConfiguration(
                main: .init(connector: model, model: "test"), orchestrationStrategy: layout)
            _ = try await surface.client.runDequeuedAIPrompt(
                "what did bravo say?", in: surface.contextID, agent: config)
            let toolResult =
                await model.requests.last { request in
                    request.messages.contains { $0.role == .tool }
                }?.messages.last { $0.role == .tool }?.content?.text ?? ""
            #expect(toolResult.contains("bravo message 3"), "the search returned the thread verbatim")

            _ = try await surface.client.runDequeuedAIPrompt("and after that?", in: surface.contextID, agent: config)
            let next = await model.requests.last { request in
                request.messages.last?.content?.text.contains("and after that?") == true
                    || request.messages.contains { $0.content?.text.contains("Turn context") == true }
            }
            let text = next?.messages.compactMap { $0.content?.text }.joined(separator: "\n") ?? ""
            #expect(text.contains("Threads your earlier searches revealed"), "\(layout.layout)")
            #expect(text.contains("— thread \"bravo\""), "\(layout.layout)")
        }
        let outputs = try await KeepTalkingContextMessage.query(on: surface.store.database)
            .filter(\.$context.$id == surface.contextID)
            .all()
            .filter { message in
                if case .intermediate(let hint, _, _, _, let sealed) = message.type {
                    return hint == "Output" && sealed != nil
                }
                return false
            }
        #expect(outputs.count == 2, "one sealed Output row per search")
        await surface.shutdown()
    }

    // MARK: - Middleware slot

    private actor CallLog {
        var calls: [(role: AITurnTelemetry.Role?, model: String)] = []
        func append(_ role: AITurnTelemetry.Role?, _ model: String) { calls.append((role, model)) }
    }

    /// Records each call's role and rewrites its model, the two things a
    /// validation harness does.
    private struct Recorder: AIConnectorMiddleware {
        let log = CallLog()
        func completeTurn(
            _ request: AIConnectorRequest, next: @Sendable (AIConnectorRequest) async throws -> AITurnResult
        ) async throws -> AITurnResult {
            await log.append(request.configuration?.telemetry?.role, request.model)
            var request = request
            request.model = "rewritten"
            return try await next(request)
        }
    }

    @Test("a connector middleware sees every call of the run, with its role, and can rewrite it")
    func middlewareSlot() async throws {
        let model = ScriptedModel()
        let surface = try await seededSurface(model)
        let recorder = Recorder()
        let config = KeepTalkingAgentConfiguration(
            main: .init(connector: AIMiddlewareConnector(model, middleware: recorder), model: "test"),
            orchestrationStrategy: strategy(consults: true)
        )
        _ = try await surface.client.runDequeuedAIPrompt("first", in: surface.contextID, agent: config)
        let calls = await recorder.log.calls
        #expect(calls.count == (await model.requests.count), "every call passes through")
        #expect(Set(calls.compactMap(\.role)) == [.consult, .collector])
        #expect(calls.allSatisfy { $0.model == "test" })
        await surface.shutdown()
    }
}
