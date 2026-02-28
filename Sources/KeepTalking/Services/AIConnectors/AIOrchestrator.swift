import Foundation
import OpenAI

public struct AIOrchestrator {
    public typealias ToolCall =
        ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam
    public typealias Message = ChatQuery.ChatCompletionMessageParam
    public typealias AssistantMessageBuilder =
        (OpenAIConnector.ToolPlanningResult) -> Message?
    public typealias ToolExecutor = ([ToolCall]) async throws -> [Message]
    public typealias AssistantPublisher = (String) async throws -> Void

    public struct Configuration: Sendable {
        public let maxTurns: Int

        public init(maxTurns: Int = 8) {
            self.maxTurns = maxTurns
        }
    }

    public struct Dependencies {
        public let openAIConnector: OpenAIConnector
        public let assistantMessageBuilder: AssistantMessageBuilder
        public let toolExecutor: ToolExecutor
        public let assistantPublisher: AssistantPublisher

        public init(
            openAIConnector: OpenAIConnector,
            assistantMessageBuilder: @escaping AssistantMessageBuilder,
            toolExecutor: @escaping ToolExecutor,
            assistantPublisher: @escaping AssistantPublisher
        ) {
            self.openAIConnector = openAIConnector
            self.assistantMessageBuilder = assistantMessageBuilder
            self.toolExecutor = toolExecutor
            self.assistantPublisher = assistantPublisher
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
        tools: [ChatQuery.ChatCompletionToolParam],
        model: OpenAIModel = .gpt4_o
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

            if let assistantText = turn.assistantText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !assistantText.isEmpty
            {
                latestAssistantText = assistantText
                try await dependencies.assistantPublisher(assistantText)
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
}
