import Foundation

/// Durable progress for one queued agent run. `messages` contains only the
/// model/tool transcript produced after the original prompt, keeping restore
/// independent from the context and system prompt rebuilt at launch.
public struct AIAgentCheckpoint: Codable, Sendable, Equatable {
    public var messages: [AIMessage]
    public var completedTurnCount: Int
    public var completedToolCallIndexes: [Int]
    public var hasActiveToolTurn: Bool
    public var latestAssistantText: String
    public var isComplete: Bool

    public init(
        messages: [AIMessage] = [],
        completedTurnCount: Int = 0,
        completedToolCallIndexes: [Int] = [],
        hasActiveToolTurn: Bool = false,
        latestAssistantText: String = "",
        isComplete: Bool = false
    ) {
        self.messages = messages
        self.completedTurnCount = completedTurnCount
        self.completedToolCallIndexes = completedToolCallIndexes
        self.hasActiveToolTurn = hasActiveToolTurn
        self.latestAssistantText = latestAssistantText
        self.isComplete = isComplete
    }
}

public struct AIOrchestrator {
    public typealias ToolCall = AIToolCall
    public typealias Message = AIMessage
    public typealias TurnRunner =
        (
            [Message],
            [KeepTalkingActionToolDefinition],
            String,
            AIToolChoice?,
            AIStage,
            AITurnConfiguration?
        ) async throws -> AITurnResult
    public typealias AssistantMessageBuilder =
        (AITurnResult) -> Message?
    public struct ToolExecution: Sendable {
        public let toolCall: ToolCall
        public let messages: [Message]

        public init(
            toolCall: ToolCall,
            messages: [Message]
        ) {
            self.toolCall = toolCall
            self.messages = messages
        }
    }
    public typealias ToolExecutor = @Sendable ([ToolCall]) async throws -> [ToolExecution]
    public typealias ToolTranscriptAdapter =
        ([ToolExecution]) async throws -> [Message]
    public typealias AssistantPublisher =
        @Sendable ((String, KeepTalkingContextMessage.MessageType)) async throws ->
        Void

    /// Extended publisher that also carries the agent turn ID.
    public typealias AgentTurnPublisher =
        @Sendable (String, KeepTalkingContextMessage.MessageType, UUID) async throws ->
        Void
    public typealias ToolNameResolver = (ToolCall) -> String

    /// The orchestrator filters tool-result messages out of the executor output
    /// so they can be passed to the connector's optional `toolExecutor`. With
    /// the KT-native `AIMessage` IR, "tool result" simply means `role == .tool`.

    /// Rich context returned by `ToolHintResolver`; carries optional action metadata
    /// for population into `MessageType.intermediate`.
    public struct ToolHintContext: Sendable {
        public let hint: IntermediateMessageHints
        public let targetNodeID: UUID?
        public let actionID: UUID?
        public let actionName: String?
        public let parameters: [String: String]?

        public init(
            hint: IntermediateMessageHints,
            targetNodeID: UUID? = nil,
            actionID: UUID? = nil,
            actionName: String? = nil,
            parameters: [String: String]? = nil
        ) {
            self.hint = hint
            self.targetNodeID = targetNodeID
            self.actionID = actionID
            self.actionName = actionName
            self.parameters = parameters
        }
    }

    public typealias ToolHintResolver = (ToolCall, AIStage) -> ToolHintContext?

    public struct ACTAgent: Sendable {
        public typealias CanHandle = @Sendable (ToolCall) -> Bool
        public typealias Executor =
            @Sendable ([ToolCall], String) async throws -> [ToolExecution]

        public let canHandle: CanHandle
        public let execute: Executor

        public init(
            canHandle: @escaping CanHandle,
            execute: @escaping Executor
        ) {
            self.canHandle = canHandle
            self.execute = execute
        }
    }

    public struct Configuration: Sendable {
        public let maxTurns: Int
        /// Maximum number of retry attempts per tool-execution batch on failure.
        public let maxToolRetries: Int

        public init(
            maxTurns: Int = 32,
            maxToolRetries: Int = 2
        ) {
            self.maxTurns = maxTurns
            self.maxToolRetries = maxToolRetries
        }
    }

    /// Called when a tool-execution batch fails and a retry is about to be attempted.
    /// Receives `(attempt, maxAttempts, error)` so callers can surface progress in the UI.
    public typealias ToolRetryObserver = @Sendable (Int, Int, any Error) async -> Void

    public struct Dependencies {
        public let aiConnector: any AIConnector
        public let turnRunner: TurnRunner
        public let assistantMessageBuilder: AssistantMessageBuilder
        public let toolExecutor: ToolExecutor
        public let toolTranscriptAdapter: ToolTranscriptAdapter
        public let assistantPublisher: AssistantPublisher
        public let toolNameResolver: ToolNameResolver
        public let toolHintResolver: ToolHintResolver
        public let actAgent: ACTAgent?
        public let toolRetryObserver: ToolRetryObserver?

        public init(
            aiConnector: any AIConnector,
            turnRunner: TurnRunner? = nil,
            assistantMessageBuilder: @escaping AssistantMessageBuilder,
            toolExecutor: @escaping ToolExecutor,
            toolTranscriptAdapter: @escaping ToolTranscriptAdapter = { _ in [] },
            actAgent: ACTAgent? = nil,
            assistantPublisher: @escaping AssistantPublisher,
            toolNameResolver: @escaping ToolNameResolver = { $0.name },
            toolHintResolver: @escaping ToolHintResolver = { _, _ in .init(hint: .toolUse) },
            toolRetryObserver: ToolRetryObserver? = nil
        ) {
            self.aiConnector = aiConnector
            self.turnRunner =
                turnRunner
                ?? { messages, tools, model, toolChoice, stage, configuration in
                    return try await aiConnector.completeTurn(
                        messages: messages,
                        tools: tools,
                        model: model,
                        toolChoice: toolChoice,
                        stage: stage,
                        configuration: configuration,
                        toolExecutor: { calls in
                            let executions = try await toolExecutor(calls)
                            // Pass through only the tool-result messages (one per call).
                            return executions.flatMap(\.messages).filter { msg in
                                msg.role == .tool
                            }
                        }
                    )
                }
            self.assistantMessageBuilder = assistantMessageBuilder
            self.toolExecutor = toolExecutor
            self.toolTranscriptAdapter = toolTranscriptAdapter
            self.actAgent = actAgent
            self.assistantPublisher = assistantPublisher
            self.toolNameResolver = toolNameResolver
            self.toolHintResolver = toolHintResolver
            self.toolRetryObserver = toolRetryObserver
        }
    }

    private let dependencies: Dependencies
    private let configuration: Configuration

    public init(
        dependencies: Dependencies,
        configuration: Configuration = .init()
    ) {
        self.dependencies = dependencies
        self.configuration = configuration
    }

    public func run(
        messages: [Message],
        tools initialTools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice = .auto,
        turnConfiguration: AITurnConfiguration? = nil,
        checkpoint restoredCheckpoint: AIAgentCheckpoint? = nil,
        onCheckpoint: ((AIAgentCheckpoint) async throws -> Void)? = nil
    ) async throws -> String {
        var checkpoint = restoredCheckpoint ?? AIAgentCheckpoint()
        var transcript = messages + checkpoint.messages

        if checkpoint.isComplete {
            return checkpoint.latestAssistantText
        }

        if checkpoint.hasActiveToolTurn,
            let pendingAssistant = checkpoint.messages.last(where: {
                $0.role == .assistant && !$0.toolCalls.isEmpty
            })
        {
            try await executePendingToolCalls(
                pendingAssistant.toolCalls,
                model: model,
                transcript: &transcript,
                checkpoint: &checkpoint,
                onCheckpoint: onCheckpoint
            )
            checkpoint.completedTurnCount += 1
            checkpoint.completedToolCallIndexes = []
            checkpoint.hasActiveToolTurn = false
            try await onCheckpoint?(checkpoint)
        }

        for _ in checkpoint.completedTurnCount..<configuration.maxTurns {
            try Task.checkCancellation()

            let turn = try await dependencies.turnRunner(
                transcript,
                initialTools,
                model,
                toolChoice,
                .execution,
                turnConfiguration
            )

            // Publish reasoning content first (if surfaced by the connector) so
            // the UI can render the model's thinking before the answer lands.
            if let thinking = turn.thinking?.trimmingCharacters(in: .whitespacesAndNewlines),
                !thinking.isEmpty
            {
                try Task.checkCancellation()
                try await dependencies.assistantPublisher(
                    (thinking, .thinking)
                )
            }

            if let assistantMessage =
                dependencies.assistantMessageBuilder(turn)
            {
                transcript.append(assistantMessage)
                checkpoint.messages.append(assistantMessage)
            }

            if let assistantText = turn.assistantText,
                !assistantText.isEmpty
            {
                checkpoint.latestAssistantText = assistantText
            }

            if let assistantText = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !assistantText.isEmpty
            {
                if checkpoint.latestAssistantText.isEmpty {
                    checkpoint.latestAssistantText = assistantText
                }
                try Task.checkCancellation()
                try await dependencies.assistantPublisher((assistantText, .message))
            }

            if let hint = Self.toolHint(
                for: turn,
                stage: .execution,
                toolNameResolver: dependencies.toolNameResolver,
                toolHintResolver: dependencies.toolHintResolver
            ) {
                try Task.checkCancellation()
                try await dependencies.assistantPublisher(hint)
            }

            guard !turn.toolCalls.isEmpty else {
                checkpoint.completedTurnCount += 1
                checkpoint.isComplete = true
                try await onCheckpoint?(checkpoint)
                break
            }

            checkpoint.completedToolCallIndexes = []
            checkpoint.hasActiveToolTurn = true
            try await onCheckpoint?(checkpoint)
            try await executePendingToolCalls(
                turn.toolCalls,
                model: model,
                transcript: &transcript,
                checkpoint: &checkpoint,
                onCheckpoint: onCheckpoint
            )
            checkpoint.completedTurnCount += 1
            checkpoint.completedToolCallIndexes = []
            checkpoint.hasActiveToolTurn = false
            try await onCheckpoint?(checkpoint)
        }

        return checkpoint.latestAssistantText
    }

    private func executePendingToolCalls(
        _ toolCalls: [ToolCall],
        model: String,
        transcript: inout [Message],
        checkpoint: inout AIAgentCheckpoint,
        onCheckpoint: ((AIAgentCheckpoint) async throws -> Void)?
    ) async throws {
        let completed = Set(checkpoint.completedToolCallIndexes)
        for (index, toolCall) in toolCalls.enumerated() where !completed.contains(index) {
            try Task.checkCancellation()
            let executions = try await executeWithRetry(
                toolCalls: [toolCall],
                model: model,
                maxRetries: configuration.maxToolRetries
            )
            let adapted = try await dependencies.toolTranscriptAdapter(executions)
            let newMessages = executions.flatMap(\.messages) + adapted
            transcript.append(contentsOf: newMessages)
            checkpoint.messages.append(contentsOf: newMessages)
            checkpoint.completedToolCallIndexes.append(index)
            try await onCheckpoint?(checkpoint)
        }
    }

    private func executeWithRetry(
        toolCalls: [ToolCall],
        model: String,
        maxRetries: Int
    ) async throws -> [ToolExecution] {
        var lastError: (any Error)?
        for attempt in 1...(maxRetries + 1) {
            do {
                return try await executeToolCalls(
                    toolCalls,
                    model: model
                )
            } catch {
                lastError = error
                if attempt <= maxRetries {
                    await dependencies.toolRetryObserver?(attempt, maxRetries, error)
                }
            }
        }
        throw lastError!
    }

    private func executeToolCalls(
        _ toolCalls: [ToolCall],
        model: String
    ) async throws -> [ToolExecution] {
        guard let actAgent = dependencies.actAgent else {
            return try await dependencies.toolExecutor(toolCalls)
        }

        var executions: [ToolExecution] = []
        var batch: [ToolCall] = []
        var batchUsesACT = false

        func flush() async throws {
            guard !batch.isEmpty else { return }
            if batchUsesACT {
                executions.append(
                    contentsOf: try await actAgent.execute(batch, model)
                )
            } else {
                executions.append(
                    contentsOf: try await dependencies.toolExecutor(batch)
                )
            }
            batch.removeAll(keepingCapacity: true)
        }

        for toolCall in toolCalls {
            // Honour cancellation between tools so a multi-tool turn aborts
            // promptly when the user clicks cancel mid-batch instead of
            // running every queued tool to completion first.
            try Task.checkCancellation()
            let shouldUseACT = actAgent.canHandle(toolCall)
            if !batch.isEmpty && shouldUseACT != batchUsesACT {
                try await flush()
            }
            if batch.isEmpty {
                batchUsesACT = shouldUseACT
            }
            batch.append(toolCall)
        }

        try await flush()
        return executions
    }

    static func toolHint(
        for turn: AITurnResult,
        stage: AIStage,
        toolNameResolver: ToolNameResolver,
        toolHintResolver: ToolHintResolver
    ) -> (String, KeepTalkingContextMessage.MessageType)? {
        guard !turn.toolCalls.isEmpty else {
            return nil
        }
        let toolNames = orderedUniqueToolNames(
            turn.toolCalls.map(toolNameResolver)
        )

        let contexts = turn.toolCalls.compactMap { toolHintResolver($0, stage) }
        guard !contexts.isEmpty else {
            return nil
        }

        let dominantHint: IntermediateMessageHints =
            contexts.allSatisfy({ $0.hint == contexts[0].hint }) ? contexts[0].hint : .toolUse

        let singleContext = contexts.count == 1 ? contexts[0] : nil

        let displayName: String
        if toolNames.count == 1, let name = toolNames.first {
            displayName = name
        } else {
            displayName = toolNames.joined(separator: ", ")
        }

        return (
            displayName,
            .intermediate(
                hint: dominantHint.rawValue,
                targetNodeID: singleContext?.targetNodeID,
                actionID: singleContext?.actionID,
                actionName: singleContext?.actionName,
                parameters: singleContext?.parameters
            )
        )
    }

    private static func orderedUniqueToolNames(_ rawNames: [String]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        names.reserveCapacity(rawNames.count)

        for rawName in rawNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else {
                continue
            }
            names.append(name)
        }

        return names.isEmpty ? rawNames : names
    }

    /// Pull the text from the first `.tool` role message in `messages`. That's
    /// the raw result string the executor returned for this tool call — the
    /// model sees it; we surface it (collapsed) to the user too.
    private static func extractToolResultText(_ messages: [AIMessage]) -> String? {
        for message in messages where message.role == .tool {
            // `content` is `Content?`; bind through the optional with `?`.
            // Also fall through to `.parts` so we don't drop multi-part
            // results that happen to carry a text leg.
            if case .text(let str)? = message.content {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let content = message.content {
                let projection = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !projection.isEmpty { return projection }
            }
        }
        return nil
    }

    /// Parse the structured result text emitted by `SkillManager+ToolCalls.swift`
    /// (`command: ... \nexit_code: N\nstdout: ...\nstderr: ...`) into a flat
    /// parameters dict the chat's intermediate-message renderer can show
    /// behind a chevron. Returns `[:]` for tool results that don't follow this
    /// shape so we don't litter the UI with garbled output panels.
    static func parseScriptResultParameters(_ text: String) -> [String: String] {
        // `summary:` is appended by SkillManager when a script ran inside a
        // skill action — it carries the inner agent's prose reply alongside
        // the raw command/stdout/stderr fields.
        let keys = ["command", "exit_code", "stdout", "stderr", "summary"]
        // Cheap header check — only handle the shape SkillManager emits.
        guard text.hasPrefix("command:") else { return [:] }

        var ranges: [(key: String, range: Range<String.Index>)] = []
        for key in keys {
            if let r = text.range(of: "\n\(key):") ?? text.range(of: "\(key):") {
                ranges.append((key, r))
            }
        }
        guard !ranges.isEmpty else { return [:] }
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result: [String: String] = [:]
        for (i, entry) in ranges.enumerated() {
            let valueStart = entry.range.upperBound
            let valueEnd = i + 1 < ranges.count ? ranges[i + 1].range.lowerBound : text.endIndex
            let raw = text[valueStart..<valueEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result[entry.key] = raw.isEmpty ? "<empty>" : raw
        }
        return result
    }

    public enum IntermediateMessageHints: String, Equatable, Sendable {
        case toolUse = "Using tool"
        case reasoning = "Reasoning"
        case searchingMemory = "Searching for"
        case searchingWeb = "Searching the web for"
        case inspecting = "Inspecting"
        case computing = "Calculating"
    }
}
