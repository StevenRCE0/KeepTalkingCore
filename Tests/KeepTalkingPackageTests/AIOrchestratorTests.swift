import XCTest
@testable import KeepTalking
import OpenAI

final class AIOrchestratorTests: XCTestCase {
    func testRunExecutesToolCallsInOrder() async throws {
        let connector = try XCTUnwrap(
            OpenAIConnector(apiKey: "test", apiMode: .responses)
        )
        let toolCall =
            ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam(
                id: "call-1",
                function: .init(
                    arguments: "{}",
                    name: "lookup_weather"
                )
            )

        let tool = Tool.functionTool(
            .init(
                name: "lookup_weather",
                description: "Look up weather",
                parameters: JSONSchema(
                    .type(.object),
                    .properties([:])
                ),
                strict: false
            )
        )

        var turnIndex = 0
        var executedToolNames: [[String]] = []

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                aiConnector: connector,
                turnRunner: { _, _, _, toolChoice, stage in
                    XCTAssertEqual(toolChoice, .auto)
                    XCTAssertEqual(stage, .execution)
                    defer { turnIndex += 1 }
                    switch turnIndex {
                        case 0:
                            return .init(
                                assistantText: nil,
                                toolCalls: [toolCall]
                            )
                        case 1:
                            return .init(
                                assistantText: "Final answer",
                                toolCalls: []
                            )
                        default:
                            XCTFail("Unexpected extra turn")
                            return .init(
                                assistantText: "Unexpected",
                                toolCalls: []
                            )
                    }
                },
                assistantMessageBuilder: { _ in nil },
                toolExecutor: { toolCalls in
                    executedToolNames.append(toolCalls.map(\.function.name))
                    return toolCalls.map { toolCall in
                        AIOrchestrator.ToolExecution(
                            toolCall: toolCall,
                            messages: [
                                .tool(
                                    .init(
                                        content: .textContent("{\"ok\":true}"),
                                        toolCallId: toolCall.id
                                    )
                                )
                            ]
                        )
                    }
                },
                assistantPublisher: { _ in }
            ),
            configuration: .init(
                maxTurns: 4,
                maxToolRetries: 0
            )
        )

        let result = try await orchestrator.run(
            messages: [
                .user(.init(content: .string("What is the weather?")))
            ],
            tools: [tool],
            model: .gpt4_o,
            toolChoice: .auto
        )

        XCTAssertEqual(executedToolNames, [["lookup_weather"]])
        XCTAssertEqual(result, "Final answer")
    }

    func testRunSkipsToolExecutorWhenNoToolCallsExist() async throws {
        let connector = try XCTUnwrap(
            OpenAIConnector(apiKey: "test", apiMode: .responses)
        )

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                aiConnector: connector,
                turnRunner: { _, _, _, toolChoice, stage in
                    XCTAssertEqual(toolChoice, .none)
                    XCTAssertEqual(stage, .execution)
                    return .init(
                        assistantText: "No tools",
                        toolCalls: []
                    )
                },
                assistantMessageBuilder: { _ in nil },
                toolExecutor: { _ in
                    XCTFail("Tool executor should not run")
                    return []
                },
                assistantPublisher: { _ in }
            ),
            configuration: .init(
                maxTurns: 2,
                maxToolRetries: 0
            )
        )

        let result = try await orchestrator.run(
            messages: [
                .user(.init(content: .string("Just answer directly")))
            ],
            tools: [],
            model: .gpt4_o,
            toolChoice: .none
        )

        XCTAssertEqual(result, "No tools")
    }
}
