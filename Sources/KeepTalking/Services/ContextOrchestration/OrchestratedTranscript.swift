import Crypto
import FluentKit
import Foundation
import NIOConcurrencyHelpers

// MARK: - Rows and threads

/// One `.message` row as the orchestrated transcript renders it.
struct OrchestratedRow: Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let sender: KeepTalkingContextMessage.Sender
    let content: String
    let agentTurnID: UUID?
    /// Flagged chitter-chatter. Live rows render regardless; stored threads
    /// leave them out of consult chunks and presented transcripts.
    let isChitterChatter: Bool

    /// The row as the model sees it — the same shape the legacy layout uses.
    var message: AIMessage {
        switch sender {
            case .autonomous: return .assistant(content)
            case .node(let nodeID): return .user("[\(nodeID.friendlyNameToken)] \(content)")
        }
    }

    /// `[speaker] text`, for transcripts inside a single row.
    var line: String {
        switch sender {
            case .autonomous(let name, _, _): return "[\(name)] \(content)"
            case .node(let nodeID): return "[\(nodeID.friendlyNameToken)] \(content)"
        }
    }
}

/// One thread of the context, oldest rows first.
struct OrchestratedThread: Sendable, Equatable {
    let threadID: UUID
    let state: KeepTalkingThreadState
    let startMessageID: UUID?
    let name: String
    let rows: [OrchestratedRow]

    var substantiveRows: [OrchestratedRow] { rows.filter { !$0.isChitterChatter } }
}

// MARK: - The rendered request

/// A rendered orchestrated request: the messages through the trailing row,
/// plus the positions the run needs to stitch and to remember the prefix.
struct OrchestratedPrompt: Sendable {
    var messages: [AIMessage]
    /// Index of `user_n`; the trailing turn-context row follows it.
    let userMessageIndex: Int
    var trailingRowIndex: Int { userMessageIndex + 1 }
    /// Hash of the system prompt and the index row (the durable prefix).
    let durablePrefixDigest: String
    /// The live rows rendered, oldest first.
    let liveRowIDs: [UUID]
    /// Approximate tokens through `user_n`.
    let prefixTokens: Int

    struct TurnContextParts: Sendable {
        let currentDate: String
        let currentPromptGuidance: String
        let sideNotes: [KeepTalkingSideNoteDTO]
        let perTurnTranscript: String

        func row(extraSections: [String] = [], effortOverride: AIReasoning.Effort? = nil) -> AIMessage {
            var row = AIMessage.system(
                AIPromptPresets.turnContextRow(
                    currentDate: currentDate,
                    currentPromptGuidance: currentPromptGuidance,
                    sideNotes: sideNotes,
                    perTurnTranscript: perTurnTranscript,
                    extraSections: extraSections,
                    effortOverride: effortOverride
                )
            )
            row.effortOverride = effortOverride
            return row
        }
    }
}

// MARK: - Per-context memory between runs

/// What a client remembers of a context's last orchestrated run, in memory
/// only: whether the prefix changed (§9), and which threads the consults
/// presented (§7.4).
struct ContextOrchestrationMemory: Sendable {
    var durablePrefixDigest: String?
    var liveRowIDs: [UUID] = []
    /// Start message ids of the threads consulted as `present` last turn.
    var presentedThreadStarts: Set<UUID> = []
}

final class KeepTalkingContextOrchestrationMemoryStore: Sendable {
    private let state = NIOLockedValueBox<[UUID: ContextOrchestrationMemory]>([:])

    subscript(contextID: UUID) -> ContextOrchestrationMemory? {
        state.withLockedValue { $0[contextID] }
    }

    func update(_ contextID: UUID, _ body: (inout ContextOrchestrationMemory) -> Void) {
        state.withLockedValue { all in
            var memory = all[contextID] ?? ContextOrchestrationMemory()
            body(&memory)
            all[contextID] = memory
        }
    }
}

// MARK: - Rendering

extension KeepTalkingClient {

    /// The deterministic part of the request (§5): the same threads in, a
    /// byte-identical prefix out.
    ///
    /// ```
    /// system (stable)                       ── durable
    /// index: older threads, by name         ── durable   (only when there are any)
    /// live thread, verbatim                 ── rolling
    /// user_n · turn context                 ── uncached
    /// ```
    ///
    /// `excludingRowIDs` drops the prompt row and, on a resumed run, the
    /// turn's own rows (as the legacy layout does).
    static func renderOrchestratedPrompt(
        systemPrompt: String,
        index: [OrchestratedThread],
        live: OrchestratedThread?,
        userMessage: AIMessage,
        turnContext: OrchestratedPrompt.TurnContextParts,
        excludingRowIDs: Set<UUID>,
        excludingAgentTurnID: UUID?
    ) -> OrchestratedPrompt {
        var messages: [AIMessage] = [AIMessage.system(systemPrompt).withCacheBoundary(.durable)]
        if !index.isEmpty {
            let lines = index.map { "- \(indexLine(for: $0))" }
            messages.append(
                AIMessage.system(
                    "Older threads, by name (oldest first) — reach any of them with \(searchThreadsToolFunctionName):\n"
                        + lines.joined(separator: "\n")
                ).withCacheBoundary(.durable)
            )
        }
        var hasher = SHA256()
        for message in messages { hasher.update(data: Data((message.content?.text ?? "").utf8)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let liveRows = (live?.rows ?? []).filter { row in
            !excludingRowIDs.contains(row.id)
                && (excludingAgentTurnID == nil || row.agentTurnID != excludingAgentTurnID)
        }
        messages.append(contentsOf: liveRows.map(\.message))
        // The rolling end of the cached prefix — the last row before user_n,
        // unless a durable boundary already sits there.
        if let last = messages.indices.last, messages[last].cacheBoundary == nil {
            messages[last] = messages[last].withCacheBoundary(.rolling)
        }
        let userIndex = messages.count
        messages.append(userMessage)
        messages.append(turnContext.row())
        let prefixTokens = messages[...userIndex].reduce(0) { $0 + $1.approximateTokenCount }
        return OrchestratedPrompt(
            messages: messages,
            userMessageIndex: userIndex,
            durablePrefixDigest: digest,
            liveRowIDs: liveRows.map(\.id),
            prefixTokens: prefixTokens
        )
    }

    static let memoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    static func dateRange(of thread: OrchestratedThread) -> String {
        guard let first = thread.rows.first?.timestamp, let last = thread.rows.last?.timestamp else { return "" }
        let start = memoryDateFormatter.string(from: first)
        let end = memoryDateFormatter.string(from: last)
        return start == end ? start : "\(start) – \(end)"
    }

    /// A thread in the index: its name and when it ran.
    static func indexLine(for thread: OrchestratedThread) -> String {
        let archived = thread.state == .archived ? ", archived" : ""
        return "\"\(thread.name)\" (\(dateRange(of: thread))\(archived))"
    }

    /// The thread map for the turn context, in the legacy line format so the
    /// annotation skill finds `Current live thread topic:`.
    static func orchestratedThreadMap(_ threads: [OrchestratedThread]) -> String {
        guard !threads.isEmpty else { return "" }
        let labels = threads.map { thread -> String in
            switch thread.state {
                case .contextMain: return "● \"\(thread.name)\""
                case .archived: return "⊘ \"\(thread.name)\""
                default: return "✓ \"\(thread.name)\""
            }
        }.joined(separator: " → ")
        guard let live = threads.last(where: { $0.state == .contextMain }) else {
            return "Conversation thread topics (oldest→newest): \(labels)"
        }
        let liveName = live.name == "untitled" ? nil : live.name
        return """
            Conversation thread topics (oldest→newest, last live): \(labels)
            \(liveName.map { "Current live thread topic: \"\($0)\"" } ?? "The live thread is unlabeled.")
            """
    }
}
