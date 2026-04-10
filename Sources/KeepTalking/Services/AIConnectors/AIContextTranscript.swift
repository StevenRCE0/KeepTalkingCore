import FluentKit
import Foundation
import OpenAI

extension KeepTalkingClient {

    // MARK: - Decay constants

    /// Exponential decay applied to messages inside the live (contextMain) thread.
    /// A smaller value means messages reach further back before falling off.
    static let contextMainDecayLambda: Double = 0.05

    /// Exponential decay applied to messages inside completed (stored/archived) threads.
    static let storedThreadDecayLambda: Double = 0.1

    /// Maximum messages taken from the live thread  (= floor(1 / λ₀)).
    static let contextMainMessageBudget: Int = 20  // floor(1/0.05)

    /// Shared message budget across all completed threads  (= floor(1 / λ₁) * 1.5, rounded).
    static let storedTotalMessageBudget: Int = 20

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

        // --- Node name summary (derived from selected messages) ---
        let nodeNameSummary = renderNodeNameSummary(
            recentMessages: allSelectedMessages,
            aliasLookup: aliasLookup
        )
        let actionNodeSummary = renderActionNodeSummary(actionStubs, aliasLookup: aliasLookup)

        return [threadMapSummary, nodeNameSummary, attachmentSummary, actionNodeSummary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Returns the decay-weighted conversation history as proper API messages,
    /// filtering out intermediate/noise messages. Insert between the system message
    /// and the current user message in the request messages array.
    func agentContextMessages(
        _ context: KeepTalkingContext,
        excludingMessageID: UUID? = nil
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        guard let contextID = context.id else {
            return []
        }

        let (_, _, selected) = try await loadContextSelection(contextID: contextID)

        return selected.flatMap(\.messages).compactMap { message in
            if let excludeID = excludingMessageID, message.id == excludeID {
                return nil
            }
            guard case .message = message.type else { return nil }
            switch message.sender {
                case .autonomous:
                    return .assistant(
                        .init(content: .textContent(message.content))
                    )
                case .node:
                    return .user(
                        .init(content: .string(message.content))
                    )
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
            return "- action_id: \(stub.actionID.uuidString.lowercased())  name: \(stub.name)  type: \(stub.kind.rawValue)  node: \(nodeTag)"
        }

        return """
            Available actions (use \(Self.ktActionPrefetchToolFunctionName) to prefetch, \(Self.ktSkillMetainfoToolFunctionName) to inspect skill manifests):
            \(lines.joined(separator: "\n"))
            """
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
                .primary(uppercaseID: true)
            let prefix = nodeID == config.node ? "current_node" : "node"
            return "- \(prefix): \(name)"
        }

        return """
            Known node names in this context (mapping aliases with uppercase UUID fallback):
            \(lines.joined(separator: "\n"))
            """
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
