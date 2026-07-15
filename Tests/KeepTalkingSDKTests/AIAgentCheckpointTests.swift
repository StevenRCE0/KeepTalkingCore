import Foundation
import Testing

@testable import KeepTalkingSDK

struct AIAgentCheckpointTests {
    private struct Interruption: Error {}

    @Test("resume skips tool calls already committed in the checkpoint")
    func resumesAfterCompletedToolCall() async throws {
        let probe = Probe()
        let orchestrator = makeOrchestrator(probe: probe)

        await #expect(throws: Interruption.self) {
            _ = try await orchestrator.run(
                messages: [.user("go")],
                tools: [],
                model: "test",
                onCheckpoint: { checkpoint in
                    try await probe.store(checkpoint, interruptAfterFirstTool: true)
                }
            )
        }

        let saved = try #require(await probe.checkpoint)
        let restored = try JSONDecoder().decode(
            AIAgentCheckpoint.self,
            from: JSONEncoder().encode(saved)
        )
        let result = try await orchestrator.run(
            messages: [.user("go")],
            tools: [],
            model: "test",
            checkpoint: restored,
            onCheckpoint: { checkpoint in
                try await probe.store(checkpoint)
            }
        )

        #expect(result == "done")
        #expect(await probe.executionCount(for: "first") == 1)
        #expect(await probe.executionCount(for: "second") == 1)
        #expect(await probe.turnCount == 2)

        let completed = try #require(await probe.checkpoint)
        let recoveredResult = try await orchestrator.run(
            messages: [.user("go")],
            tools: [],
            model: "test",
            checkpoint: completed
        )
        #expect(recoveredResult == "done")
        #expect(await probe.turnCount == 2)
    }

    private func makeOrchestrator(probe: Probe) -> AIOrchestrator {
        AIOrchestrator(
            dependencies: .init(
                aiConnector: StubConnector(),
                turnRunner: { _, _, _, _, _, _ in
                    await probe.nextTurn()
                },
                assistantMessageBuilder: { turn in
                    .assistantToolCalls(turn.toolCalls, text: turn.assistantText)
                },
                toolExecutor: { calls in
                    await probe.execute(calls)
                },
                assistantPublisher: { _ in }
            )
        )
    }

    private actor Probe {
        var checkpoint: AIAgentCheckpoint?
        var turnCount = 0
        private var executionCounts: [String: Int] = [:]

        func nextTurn() -> AITurnResult {
            turnCount += 1
            if turnCount == 1 {
                return AITurnResult(
                    assistantText: nil,
                    toolCalls: [
                        .init(id: "call-1", name: "first", argumentsJSON: "{}"),
                        .init(id: "call-2", name: "second", argumentsJSON: "{}"),
                    ]
                )
            }
            return AITurnResult(assistantText: "done", toolCalls: [])
        }

        func execute(_ calls: [AIToolCall]) -> [AIOrchestrator.ToolExecution] {
            calls.map { call in
                executionCounts[call.name, default: 0] += 1
                return .init(
                    toolCall: call,
                    messages: [.tool("ok", toolCallID: call.id)]
                )
            }
        }

        func store(
            _ checkpoint: AIAgentCheckpoint,
            interruptAfterFirstTool: Bool = false
        ) throws {
            self.checkpoint = checkpoint
            if interruptAfterFirstTool,
                checkpoint.completedToolCallIndexes == [0]
            {
                throw Interruption()
            }
        }

        func executionCount(for name: String) -> Int {
            executionCounts[name, default: 0]
        }
    }

    private actor StubConnector: AIConnector {
        nonisolated let capabilities = AIConnectorCapabilities(
            supportsNativeToolCalling: true
        )

        func completeTurn(
            messages: [AIMessage],
            tools: [KeepTalkingActionToolDefinition],
            model: String,
            toolChoice: AIToolChoice?,
            stage: AIStage,
            configuration: AITurnConfiguration?,
            toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
        ) async throws -> AITurnResult {
            throw Interruption()
        }
    }
}
