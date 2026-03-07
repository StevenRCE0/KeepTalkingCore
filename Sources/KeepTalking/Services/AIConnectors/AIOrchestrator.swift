import Foundation
import OpenAI

public struct AIOrchestrator {
    public typealias ToolCall =
        ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam
    public typealias Message = ChatQuery.ChatCompletionMessageParam
    public typealias AssistantMessageBuilder =
        (OpenAIConnector.ToolPlanningResult) -> Message?
    public typealias ToolExecutor = ([ToolCall]) async throws -> [Message]
    public typealias AssistantPublisher = ((String, KeepTalkingContextMessage.MessageType)) async throws -> Void
    public typealias ToolNameResolver = (ToolCall) -> String

    public struct Configuration: Sendable {
        public let maxTurns: Int

        public init(maxTurns: Int = 12) {
            self.maxTurns = maxTurns
        }
    }

    public struct Dependencies {
        public let openAIConnector: OpenAIConnector
        public let assistantMessageBuilder: AssistantMessageBuilder
        public let toolExecutor: ToolExecutor
        public let assistantPublisher: AssistantPublisher
        public let toolNameResolver: ToolNameResolver

        public init(
            openAIConnector: OpenAIConnector,
            assistantMessageBuilder: @escaping AssistantMessageBuilder,
            toolExecutor: @escaping ToolExecutor,
            assistantPublisher: @escaping AssistantPublisher,
            toolNameResolver: @escaping ToolNameResolver = { $0.function.name }
        ) {
            self.openAIConnector = openAIConnector
            self.assistantMessageBuilder = assistantMessageBuilder
            self.toolExecutor = toolExecutor
            self.assistantPublisher = assistantPublisher
            self.toolNameResolver = toolNameResolver
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
        model: OpenAIModel
    ) async throws -> String {
        var transcript = messages
        var latestAssistantText = ""

        for _ in 0..<configuration.maxTurns {
            let turn = try await dependencies.openAIConnector.completeTurn(
                messages: transcript,
                tools: tools,
                model: model,
                toolChoice: .auto
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
                toolNameResolver: dependencies.toolNameResolver
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

            transcript.append(
                contentsOf: try await dependencies.toolExecutor(turn.toolCalls)
            )
        }

        return latestAssistantText
    }

    private static func chatText(
        for turn: OpenAIConnector.ToolPlanningResult,
        toolNameResolver: ToolNameResolver
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
        if toolNames.count == 1, let name = toolNames.first {
            return (
                name,
                .intermediate(
                    hint: IntermediateMessageHints.toolUse.rawValue
                )
            )
        }
        return (
            toolNames.joined(separator: ", "),
            .intermediate(hint: IntermediateMessageHints.toolUse.rawValue)
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
}

extension AIOrchestrator {
    public enum IntermediateMessageHints: String {
        case toolUse = "Using tool"
        case reasoning = "Reasoning"
    }
}
