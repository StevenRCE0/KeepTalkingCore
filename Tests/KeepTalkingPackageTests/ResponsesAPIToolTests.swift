import XCTest
@testable import KeepTalking
import OpenAI

final class ResponsesAPIToolTests: XCTestCase {
    func testResponseAPI() async throws {
        let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        if envKey.isEmpty {
            print("No api key")
            return
        }
        let connector = OpenAIConnector(
            apiKey: envKey,
            apiMode: .responses
        )
        
        let tool = Tool.functionTool(
            .init(
                name: "get_weather",
                description: "Get the current weather",
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "location": JSONSchema(.type(.string))
                    ]),
                    .required(["location"])
                ),
                strict: false
            )
        )
        
        let messages: [ChatQuery.ChatCompletionMessageParam] = [
            .user(.init(content: .string("What is the weather in Tokyo?")))
        ]
        
        do {
            let result = try await connector.completeTurn(
                messages: messages,
                tools: [tool],
                model: .gpt4_o
            )
            print("ASSISTANT TEXT:")
            print(result.assistantText ?? "nil")
            print("TOOL CALLS:")
            print(result.toolCalls)
        } catch {
            print("ERROR: \(error)")
        }
    }
}
