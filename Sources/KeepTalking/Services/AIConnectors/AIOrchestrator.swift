import Foundation
import OpenAI

public struct AIOrchestrator {
    public typealias ToolCall =
        ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam
    public typealias Message = ChatQuery.ChatCompletionMessageParam
    public typealias AssistantMessageBuilder =
        (OpenAIConnector.ToolPlanningResult) -> Message?
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
    public typealias ToolExecutor = ([ToolCall]) async throws -> [ToolExecution]
    public typealias ToolTranscriptAdapter =
        ([ToolExecution]) async throws -> [Message]
    public typealias AssistantPublisher = ((String, KeepTalkingContextMessage.MessageType)) async throws -> Void
    public typealias ToolNameResolver = (ToolCall) -> String
    public typealias ToolHintResolver = (ToolCall) -> IntermediateMessageHints?

    public struct Configuration: Sendable {
        public let maxTurns: Int

        public init(maxTurns: Int = 32) {
            self.maxTurns = maxTurns
        }
    }

    public struct Dependencies {
        public let openAIConnector: OpenAIConnector
        public let assistantMessageBuilder: AssistantMessageBuilder
        public let toolExecutor: ToolExecutor
        public let toolTranscriptAdapter: ToolTranscriptAdapter
        public let assistantPublisher: AssistantPublisher
        public let toolNameResolver: ToolNameResolver
        public let toolHintResolver: ToolHintResolver

        public init(
            openAIConnector: OpenAIConnector,
            assistantMessageBuilder: @escaping AssistantMessageBuilder,
            toolExecutor: @escaping ToolExecutor,
            toolTranscriptAdapter: @escaping ToolTranscriptAdapter = { _ in [] },
            assistantPublisher: @escaping AssistantPublisher,
            toolNameResolver: @escaping ToolNameResolver = { $0.function.name },
            toolHintResolver: @escaping ToolHintResolver = { _ in .toolUse }
        ) {
            self.openAIConnector = openAIConnector
            self.assistantMessageBuilder = assistantMessageBuilder
            self.toolExecutor = toolExecutor
            self.toolTranscriptAdapter = toolTranscriptAdapter
            self.assistantPublisher = assistantPublisher
            self.toolNameResolver = toolNameResolver
            self.toolHintResolver = toolHintResolver
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
        tools: [OpenAITool],
        model: OpenAIModel,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam = .auto
    ) async throws -> String {
        var transcript = messages
        var latestAssistantText = ""

        for _ in 0..<configuration.maxTurns {
            let turn = try await dependencies.openAIConnector.completeTurn(
                messages: transcript,
                tools: tools,
                model: model,
                toolChoice: toolChoice
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
                toolNameResolver: dependencies.toolNameResolver,
                toolHintResolver: dependencies.toolHintResolver
            ) {
                if latestAssistantText.isEmpty {
                    latestAssistantText = chatText.0
                }
                try await dependencies
                    .assistantPublisher(chatText)
            }

            guard !turn.toolCalls.isEmpty else {
                break
            }

            let toolExecutions = try await dependencies.toolExecutor(
                turn.toolCalls
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

    private static func chatText(
        for turn: OpenAIConnector.ToolPlanningResult,
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
        let hints = turn.toolCalls.compactMap(toolHintResolver)
        guard hints.count > 1 else {
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
}

extension AIOrchestrator {
    public enum IntermediateMessageHints: String {
        case toolUse = "Using tool"
        case reasoning = "Reasoning"
    }
}
