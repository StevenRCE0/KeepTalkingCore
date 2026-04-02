import XCTest
@testable import KeepTalking
import OpenAI

final class AIOrchestratorTests: XCTestCase {
    func testPlanningStageRunsBeforeNormalTurn() async throws {
        let connector = try XCTUnwrap(
            OpenAIConnector(apiKey: "test", apiMode: .responses)
        )
        let planningToolCall =
            ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam(
                id: "plan-call",
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

        var recordedChoices: [ChatQuery.ChatCompletionFunctionCallOptionParam] = []
        var turnIndex = 0
        var executedToolNames: [[String]] = []

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                openAIConnector: connector,
                turnRunner: { _, _, _, toolChoice in
                    recordedChoices.append(toolChoice)
                    defer { turnIndex += 1 }
                    switch turnIndex {
                        case 0:
                            return .init(
                                assistantText: nil,
                                toolCalls: [planningToolCall]
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
                maxToolRetries: 0,
                enforcePlanningStage: true
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

        XCTAssertEqual(recordedChoices, [.required, .auto])
        XCTAssertEqual(executedToolNames, [["lookup_weather"]])
        XCTAssertEqual(result, "Final answer")
    }

    func testPlanningStageSkipsWhenToolChoiceDisablesTools() async throws {
        let connector = try XCTUnwrap(
            OpenAIConnector(apiKey: "test", apiMode: .responses)
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

        var recordedChoices: [ChatQuery.ChatCompletionFunctionCallOptionParam] = []

        let orchestrator = AIOrchestrator(
            dependencies: .init(
                openAIConnector: connector,
                turnRunner: { _, _, _, toolChoice in
                    recordedChoices.append(toolChoice)
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
                maxToolRetries: 0,
                enforcePlanningStage: true
            )
        )

        let result = try await orchestrator.run(
            messages: [
                .user(.init(content: .string("Just answer directly")))
            ],
            tools: [tool],
            model: .gpt4_o,
            toolChoice: .none
        )

        XCTAssertEqual(recordedChoices, [.none])
        XCTAssertEqual(result, "No tools")
    }
}
