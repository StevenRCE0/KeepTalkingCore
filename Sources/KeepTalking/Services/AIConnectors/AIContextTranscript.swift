import AIProxy
import FluentKit
import Foundation

extension KeepTalkingClient {

    // MARK: - Decay constants

    /// Exponential decay applied to messages inside the live (contextMain) thread.
    /// A smaller value means messages reach further back before falling off.
    static let contextMainDecayLambda: Double = 0.015

    /// Exponential decay applied to messages inside completed (stored/archived) threads.
    static let storedThreadDecayLambda: Double = 0.03

    /// Maximum messages taken from the live thread  (= floor(1 / λ₀)).
    static let contextMainMessageBudget: Int = 80  // floor(1/0.05)

    /// Shared message budget across all completed threads  (= floor(1 / λ₁) * 1.5, rounded).
    static let storedTotalMessageBudget: Int = 100

    // MARK: - Context transcript

    /// Loads threads + messages for `context` and applies decay-weighted selection,
    /// returning the raw grouped result for use by both the metadata formatter and the
    /// message-list builder.
    func loadContextSelection(
        contextID: UUID
    ) async throws -> (
        allMessages: [KeepTalkingContextMessage],
        threadedSegments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])],
        selected: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])]
    ) {
        let threads = try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)
            .all()

        let allMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$timestamp, .ascending)
        .all()

        let threadedSegments = buildThreadedSegments(
            threads: threads,
            allMessages: allMessages
        )

        let selected: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])]
        if threadedSegments.isEmpty {
            let recent = Array(allMessages.suffix(30))
            selected = [(thread: nil, messages: recent)]
        } else {
            selected = decayWeightedSelection(segments: threadedSegments)
        }

        return (allMessages: allMessages, threadedSegments: threadedSegments, selected: selected)
    }

    /// Returns metadata-only context string (thread map, node names, attachments, action stubs).
    /// Conversation messages are excluded — use `agentContextMessages` for those.
    func agentContextTranscript(
        _ context: KeepTalkingContext,
        actionStubs: [KeepTalkingActionStub]
    ) async throws -> String {
        guard let contextID = context.id else {
            return ""
        }
        let aliasLookup = try await aliasLookup()

        let (_, threadedSegments, selectedMessages) = try await loadContextSelection(
            contextID: contextID
        )

        let threadMapSummary = renderThreadMapSummary(
            segments: threadedSegments,
            aliasLookup: aliasLookup
        )

        let allSelectedMessages = selectedMessages.flatMap(\.messages)

        // --- Attachment summary ---
        let attachmentCount = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .count()
        let recentAttachmentNames = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$createdAt, .descending)
        .sort(\.$sortIndex, .descending)
        .limit(8)
        .all()
        .map(\.filename)
        .reversed()

        let attachmentSummary: String
        if attachmentCount > 0 {
            let preview = previewList(Array(recentAttachmentNames), maxItems: 8)
            attachmentSummary = """
                Context attachments: \(attachmentCount)
                Recent attachment names: \(preview)
                Use \(Self.contextAttachmentListingToolFunctionName) for the full inventory and \(Self.contextAttachmentReadToolFunctionName) to inspect one.
                """
        } else {
            attachmentSummary = ""
        }

        // --- Voice call transcript summary ---
        // Transcripts stay in the database and are exposed to the agent as
        // virtual attachments (attachment_id == the call's session id), read via
        // the same context-attachment tools.
        let transcriptSessions =
            (try? await voiceTranscriptSessionSummaries(in: contextID)) ?? []
        let voiceTranscriptSummary: String
        if !transcriptSessions.isEmpty {
            let transcriptDate = DateFormatter()
            transcriptDate.dateStyle = .medium
            transcriptDate.timeStyle = .short
            let names = transcriptSessions.prefix(5).map {
                "Voice call transcript — \(transcriptDate.string(from: $0.firstAt)) (\($0.lineCount) lines)"
            }
            voiceTranscriptSummary = """
                Voice call transcripts: \(transcriptSessions.count)
                Recent: \(previewList(Array(names), maxItems: 5))
                Each is a virtual attachment whose attachment_id is the call's session id — list them with \(Self.contextAttachmentListingToolFunctionName) and read one with \(Self.contextAttachmentReadToolFunctionName) (it resolves the live transcript from the database).
                """
        } else {
            voiceTranscriptSummary = ""
        }

        // --- Node name summary (derived from selected messages) ---
        let nodeNameSummary = renderNodeNameSummary(
            recentMessages: allSelectedMessages,
            aliasLookup: aliasLookup
        )
        let actionNodeSummary = renderActionNodeSummary(actionStubs, aliasLookup: aliasLookup)

        return [
            threadMapSummary, nodeNameSummary, attachmentSummary,
            voiceTranscriptSummary, actionNodeSummary,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Returns the decay-weighted conversation history as proper API messages,
    /// filtering out intermediate/noise messages. Insert between the system message
    /// and the current user message in the request messages array.
    func agentContextMessages(
        _ context: KeepTalkingContext,
        excludingMessageID: UUID? = nil,
        excludingAgentTurnID: UUID? = nil
    ) async throws -> [AIMessage] {
        guard let contextID = context.id else {
            return []
        }

        let (_, _, selected) = try await loadContextSelection(contextID: contextID)
        let aliasLookup = try await aliasLookup()

        return selected.flatMap(\.messages).compactMap { message -> AIMessage? in
            if let excludeID = excludingMessageID, message.id == excludeID {
                return nil
            }
            if let excludeTurnID = excludingAgentTurnID,
                message.agentTurnID == excludeTurnID
            {
                return nil
            }
            guard case .message = message.type else { return nil }
            switch message.sender {
                case .autonomous:
                    return .assistant(message.content)
                case .node(let nodeID):
                    let name =
                        aliasLookup
                        .resolve(.node(nodeID))
                        .primary(.uppercase)
                    return .user("[\(name)] \(message.content)")
            }
        }
    }

    // MARK: - Thread segmentation helpers

    /// Groups all context messages into ordered (thread, [message]) pairs.
    /// Threads without any messages are omitted.
    private func buildThreadedSegments(
        threads: [KeepTalkingThread],
        allMessages: [KeepTalkingContextMessage]
    ) -> [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])] {
        guard !threads.isEmpty, !allMessages.isEmpty else { return [] }

        let sorted =
            threads
            .compactMap { thread -> (thread: KeepTalkingThread, range: ClosedRange<Int>)? in
                guard let range = thread.resolvedMessageRange(in: allMessages) else {
                    return nil
                }
                return (thread: thread, range: range)
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

        var result: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])] = []
        for (thread, range) in sorted {
            let slice = Array(allMessages[range])
            // Exclude chitter-chatter messages from the prompt.
            let chitterSet = Set(thread.chitterChatter)
            let filtered = slice.filter { msg in
                guard let id = msg.id else { return true }
                return !chitterSet.contains(id)
            }
            if !filtered.isEmpty {
                result.append((thread: thread, messages: filtered))
            }
        }
        return result
    }

    /// Applies exponential decay to select messages from each thread segment.
    ///
    /// - contextMain: takes up to `contextMainMessageBudget` tail messages with λ₀ decay.
    /// - stored/archived: all threads share `storedTotalMessageBudget` tail messages with λ₁ decay;
    ///   each individual thread receives a proportional slice.
    private func decayWeightedSelection(
        segments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])]
    ) -> [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])] {
        let λ₀ = Self.contextMainDecayLambda
        let λ₁ = Self.storedThreadDecayLambda

        /// Number of tail messages to keep for a thread with a given decay λ and budget cap.
        /// Uses `ceil(-ln(0.01) / λ)` — the position at which the weight drops below 1 %.
        func tailCount(lambda: Double, cap: Int, available: Int) -> Int {
            let depth = Int(ceil(-log(0.01) / lambda))  // ~99 % of cumulative weight
            return min(cap, min(depth, available))
        }

        var result: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])] = []

        let storedSegments = segments.filter { $0.thread.state != .contextMain }
        let mainSegments = segments.filter { $0.thread.state == .contextMain }

        // --- Completed threads: share storedTotalMessageBudget ---
        if !storedSegments.isEmpty {
            let perThread = max(1, Self.storedTotalMessageBudget / storedSegments.count)
            for seg in storedSegments {
                let n = tailCount(lambda: λ₁, cap: perThread, available: seg.messages.count)
                let selected = Array(seg.messages.suffix(n))
                result.append((thread: seg.thread, messages: selected))
            }
        }

        // --- Live thread (contextMain) ---
        for seg in mainSegments {
            let n = tailCount(lambda: λ₀, cap: Self.contextMainMessageBudget, available: seg.messages.count)
            let selected = Array(seg.messages.suffix(n))
            result.append((thread: seg.thread, messages: selected))
        }

        return result
    }

    // MARK: - Thread rendering helpers

    private func threadTopicName(
        for thread: KeepTalkingThread,
        messages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        if let threadID = thread.id,
            let alias = aliasLookup.alias(for: .thread(threadID)),
            !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return alias
        }
        if let summary = thread.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty
        {
            return summary
        }
        return derivedThreadTopic(from: messages)
    }

    private func derivedThreadTopic(
        from messages: [KeepTalkingContextMessage]
    ) -> String {
        for message in messages.reversed() where message.type == .message {
            let normalized = normalizedTopicSnippet(message.content)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return "untitled"
    }

    private func normalizedTopicSnippet(_ raw: String) -> String {
        let collapsedWhitespace =
            raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedWhitespace.isEmpty else {
            return ""
        }

        let withoutURLs = collapsedWhitespace.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        let words =
            withoutURLs
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return ""
        }
        return words.prefix(6).joined(separator: " ")
    }

    /// Renders a single-line thread topic map injected before the transcript.
    private func renderThreadMapSummary(
        segments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        guard !segments.isEmpty else { return "" }

        let labels = segments.map { seg -> String in
            let topic = threadTopicName(
                for: seg.thread,
                messages: seg.messages,
                aliasLookup: aliasLookup
            )
            if seg.thread.state == .contextMain {
                return "● \"\(topic)\""
            }
            let mark = seg.thread.state == .archived ? "⊘" : "✓"
            return "\(mark) \"\(topic)\""
        }.joined(separator: " → ")

        let currentLiveTopic =
            segments
            .last(where: { $0.thread.state == .contextMain })
            .map {
                threadTopicName(
                    for: $0.thread,
                    messages: $0.messages,
                    aliasLookup: aliasLookup
                )
            }

        if let currentLiveTopic {
            return """
                Conversation thread topics (oldest→newest, last live): \(labels)
                Current live thread topic: "\(currentLiveTopic)"
                """
        }

        return "Conversation thread topics (oldest→newest): \(labels)"
    }

    func renderActionNodeSummary(
        _ stubs: [KeepTalkingActionStub],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        guard !stubs.isEmpty else {
            return ""
        }

        let lines = stubs.map { stub in
            let nodeName = aliasLookup.resolve(.node(stub.ownerNodeID)).primary()
            let nodeTag = stub.isCurrentNode ? "\(nodeName) (current)" : nodeName
            let desc = stub.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let descSuffix = desc.isEmpty ? "" : "  description: \(desc)"
            var line =
                "- action_id: \(stub.actionID.uuidString.lowercased())  name: \(stub.name)  type: \(stub.kind.rawValue)  node: \(nodeTag)\(descSuffix)"
            if !stub.objectContracts.isEmpty {
                line += "\n    objects: \(Self.renderObjectContracts(stub.objectContracts))"
            }
            return line
        }

        return """
            Available actions (use \(Self.runActionToolFunctionName) to execute, \(Self.ktSkillMetainfoToolFunctionName) to inspect skill manifests):
            Types: mcp=external server tools · skill=directory-based agent skill · primitive=built-in operation · filesystem=sandboxed file access + context blob bridge · semanticretrieval=remote thread-memory search
            An `objects:` line lists an action's declared inputs/outputs (direction + whether it's a file) so you can plan data flow BETWEEN actions — feed one action's `out` to another's `in`. You never see or pass provider file paths; reference a produced file by the handle the action returns.
            \(lines.joined(separator: "\n"))
            """
    }

    /// Renders declared object contracts PATH-FREE for the main agent: each shows
    /// name, file/value, direction (in/out/in·out), and description — never a path.
    static func renderObjectContracts(_ contracts: [KeepTalkingObjectContract]) -> String {
        contracts.map { contract in
            let direction: String
            switch contract.direction {
                case .input: direction = "in"
                case .output: direction = "out"
                case .inputOutput: direction = "in·out"
            }
            let kind = contract.isFile ? "file" : "value"
            let name = contract.name.isEmpty ? "(unnamed)" : contract.name
            let trimmed = contract.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : " — \(trimmed)"
            return "\(name) (\(kind), \(direction))\(suffix)"
        }.joined(separator: "; ")
    }

    func renderNodeNameSummary(
        recentMessages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        var nodeIDs = Set(
            recentMessages.compactMap { message -> UUID? in
                guard case .node(let nodeID) = message.sender else {
                    return nil
                }
                return nodeID
            }
        )
        nodeIDs.insert(config.node)

        let sortedNodeIDs = nodeIDs.sorted { $0.uuidString < $1.uuidString }
        let lines = sortedNodeIDs.map { nodeID in
            let name =
                aliasLookup
                .resolve(.node(nodeID))
                .primary(.uppercase)
            let prefix = nodeID == config.node ? "current_node" : "node"
            return "- \(prefix): \(name)"
        }

        return """
            Known node names in this context (mapping aliases with uppercase UUID fallback):
            \(lines.joined(separator: "\n"))
            """
    }

    // MARK: - Voice routing context

    /// Text-only context block injected into the audio bridge's `extractIntent`
    /// turn. The audio model uses it both to route accurately AND to answer
    /// simple things directly without a round trip to the main agent — so it
    /// carries real conversation content, not just a routing hint. Never throws —
    /// any fetch failure produces an empty string so the bridge always has
    /// *something* to inject (even if it's blank).
    ///
    /// Sections (all bounded):
    /// - Environment (local time / timezone / platform)
    /// - Conversation thread topics (what's been discussed)
    /// - Known participant names
    /// - Recent conversation tail (~8 turns, per-message capped)
    /// - Ongoing voice transcript lines (~20 lines) — omitted when `sessionID` is nil
    public func voiceRoutingContext(
        contextID: UUID,
        sessionID: UUID?
    ) async -> String {
        var sections: [String] = []

        // --- Environment ---
        // Ground the bridge in the same local time / timezone / platform the
        // main agent sees, so spoken answers and routing decisions can reason
        // about "now" correctly instead of being time-blind.
        sections.append("Environment:\n\(KeepTalkingEnvironmentContext.summaryLine())")

        // --- Side notes ---
        // Persistent context notes the main agent maintains (key/value pairs).
        // The audio bridge needs them to route intelligently — e.g. a note
        // "Current project: X" should inform which requests get delegated.
        let activeSideNotes =
            (try? await KeepTalkingSideNote.query(on: localStore.database)
                .filter(\.$context.$id, .equal, contextID)
                .filter(\.$isArchived == false)
                .sort(\.$updatedAt, .descending)
                .all()
                .map(KeepTalkingSideNoteDTO.init)) ?? []
        if !activeSideNotes.isEmpty {
            let body = activeSideNotes.map { "[\($0.key)] \($0.value ?? "")" }.joined(separator: "\n")
            sections.append(
                """
                Side notes:
                Active notes track plans, open questions, and state that must survive \
                across turns. They may also contain conventions, standard operating \
                procedures, and instructions you must follow. Archived notes no longer \
                appear here. To create, update, or archive a note, delegate the request \
                to the backend agent.
                \(body)
                """)
        }

        // --- Conversation-derived sections (single load) ---
        // One load feeds thread topics, participant names, and the recent tail —
        // the situational picture the model needs to answer in place.
        if let aliasLookup = try? await aliasLookup(),
            let (allMessages, threadedSegments, _) = try? await loadContextSelection(
                contextID: contextID)
        {
            // Thread topics — lets the model tell a follow-up from a new request.
            let threadMap = renderThreadMapSummary(
                segments: threadedSegments, aliasLookup: aliasLookup)
            if !threadMap.isEmpty { sections.append(threadMap) }

            // Participant names — so it can attribute and answer "who" questions.
            let nodeNames = renderNodeNameSummary(
                recentMessages: allMessages, aliasLookup: aliasLookup)
            if !nodeNames.isEmpty { sections.append(nodeNames) }

            // Recent conversation tail — actual message content.
            let tail = voiceRoutingTail(messages: allMessages, aliasLookup: aliasLookup)
            if !tail.isEmpty { sections.append(tail) }
        }

        // --- Ongoing voice transcript ---
        if let sessionID,
            let lines = try? await voiceTranscriptLines(forSession: sessionID),
            !lines.isEmpty
        {
            let recent = lines.suffix(20)
            var block = "Ongoing voice call transcript (most recent lines):"
            var remaining = 400
            for line in recent {
                let entry = "\n[\(line.author.uuidString.prefix(8))]: \(line.text)"
                guard remaining > 0 else { break }
                let clipped = String(entry.prefix(remaining))
                block += clipped
                remaining -= clipped.count
            }
            sections.append(block)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Formats the recent conversation tail for the audio bridge. Pure — takes
    /// pre-loaded, timestamp-sorted messages (so the tail is always the most
    /// recent turns regardless of thread structure). Keeps the last 8 `.message`
    /// turns, each capped independently so a long earlier turn can't starve the
    /// most recent — and most relevant — ones the way a shared budget would.
    private func voiceRoutingTail(
        messages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        let turns = messages.filter { $0.type == .message }.suffix(8)
        guard !turns.isEmpty else { return "" }

        let perMessageCap = 600
        var block =
            "Recent conversation (use this to understand what's going on and to answer directly when you can):"
        for message in turns {
            let speaker: String
            switch message.sender {
                case .autonomous:
                    speaker = "assistant"
                case .node(let nodeID):
                    speaker = aliasLookup.resolve(.node(nodeID)).primary(.uppercase)
            }
            let content =
                message.content.count > perMessageCap
                ? String(message.content.prefix(perMessageCap)) + "…"
                : message.content
            block += "\n[\(speaker)]: \(content)"
        }
        return block
    }

    // MARK: - Shared utilities

    func previewList(_ values: [String], maxItems: Int) -> String {
        guard !values.isEmpty else {
            return "<none>"
        }
        if values.count <= maxItems {
            return values.joined(separator: ", ")
        }
        let preview = values.prefix(maxItems).joined(separator: ", ")
        return "\(preview), ...[\(values.count - maxItems) more]"
    }

    func clipped(_ text: String, maxCharacters: Int) -> String {
        skillCatalogContextLoader.clipped(text, maxCharacters: maxCharacters)
    }

    func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            return "{\"ok\":false,\"error\":\"invalid_json_object\"}"
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":\"json_encoding_failed\"}"
        }
        return text
    }

}
