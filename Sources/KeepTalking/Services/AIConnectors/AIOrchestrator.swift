import Foundation
import OpenAI

public struct AIOrchestrator {
    public typealias ToolCall =
        ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam
    public typealias Message = ChatQuery.ChatCompletionMessageParam
    public typealias TurnRunner =
        (
            [Message],
            [OpenAITool],
            OpenAIModel,
            ChatQuery.ChatCompletionFunctionCallOptionParam?,
            AIStage
        ) async throws -> AITurnResult
    public typealias AssistantMessageBuilder =
        (AITurnResult) -> Message?
    public struct ToolExecution {
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
    public typealias ToolNameResolver = (ToolCall) -> String
    public typealias ToolHintResolver = (ToolCall, AIStage) -> IntermediateMessageHints?

    public struct ACTAgent: Sendable {
        public typealias CanHandle = @Sendable (ToolCall) -> Bool
        public typealias Executor =
            @Sendable ([ToolCall], OpenAIModel) async throws -> [ToolExecution]

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
            toolNameResolver: @escaping ToolNameResolver = { $0.function.name },
            toolHintResolver: @escaping ToolHintResolver = { _, _ in .toolUse },
            toolRetryObserver: ToolRetryObserver? = nil
        ) {
            self.aiConnector = aiConnector
            self.turnRunner =
                turnRunner
                ?? { messages, tools, model, toolChoice, stage in
                    return try await aiConnector.completeTurn(
                        messages: messages,
                        tools: tools,
                        model: model,
                        toolChoice: toolChoice,
                        stage: stage,
                        toolExecutor: { calls in
                            let executions = try await toolExecutor(calls)
                            return executions.flatMap { $0.messages }.compactMap { msg in
                                if case .tool(let toolMsg) = msg {
                                    return toolMsg
                                }
                                return nil
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
        tools initialTools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam = .auto
    ) async throws -> String {
        var transcript = messages
        var latestAssistantText = ""

        for _ in 0..<configuration.maxTurns {
            try Task.checkCancellation()

            let turn = try await dependencies.turnRunner(
                transcript,
                initialTools,
                model,
                toolChoice,
                .execution
            )

            if let assistantMessage =
                dependencies.assistantMessageBuilder(turn)
            {
                transcript.append(assistantMessage)
            }

            if let assistantText = turn.assistantText,
                !assistantText.isEmpty
            {
                latestAssistantText = assistantText
            }

            if let chatText = Self.chatText(
                for: turn,
                stage: .execution,
                toolNameResolver: dependencies.toolNameResolver,
                toolHintResolver: dependencies.toolHintResolver
            ) {
                if latestAssistantText.isEmpty {
                    latestAssistantText = chatText.0
                }
                try Task.checkCancellation()
                try await dependencies
                    .assistantPublisher(chatText)
            }

            guard !turn.toolCalls.isEmpty else {
                break
            }

            try Task.checkCancellation()
            let toolExecutions = try await executeWithRetry(
                toolCalls: turn.toolCalls,
                model: model,
                maxRetries: configuration.maxToolRetries
            )
            for execution in toolExecutions {
                transcript.append(contentsOf: execution.messages)
            }
            transcript.append(
                contentsOf: try await dependencies.toolTranscriptAdapter(
                    toolExecutions
                )
            )
        }

        return latestAssistantText
    }

    private func executeWithRetry(
        toolCalls: [ToolCall],
        model: OpenAIModel,
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
        model: OpenAIModel
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

    static func chatText(
        for turn: AITurnResult,
        stage: AIStage,
        toolNameResolver: ToolNameResolver,
        toolHintResolver: ToolHintResolver
    ) -> (String, KeepTalkingContextMessage.MessageType)? {
        if let assistantText = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !assistantText.isEmpty
        {
            return (assistantText, .message)
        }
        guard !turn.toolCalls.isEmpty else {
            return nil
        }
        let toolNames = orderedUniqueToolNames(
            turn.toolCalls.map(toolNameResolver)
        )

        // Use a specific hint if all calls in this turn share one.
        let hints = turn.toolCalls.compactMap { toolHintResolver($0, stage) }
        guard !hints.isEmpty else {
            return nil
        }

        let hint: IntermediateMessageHints =
            hints.allSatisfy({ $0 == hints[0] }) ? hints[0] : .toolUse
        if toolNames.count == 1, let name = toolNames.first {
            return (name, .intermediate(hint: hint.rawValue))
        }
        return (toolNames.joined(separator: ", "), .intermediate(hint: hint.rawValue))
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

    public enum IntermediateMessageHints: String {
        case toolUse = "Using tool"
        case reasoning = "Reasoning"
        case searchingMemory = "Searching memory"
        case searchingWeb = "Searching web"
        case inspecting = "Inspecting"
    }
}
