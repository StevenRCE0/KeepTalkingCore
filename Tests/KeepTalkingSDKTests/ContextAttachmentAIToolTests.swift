import Foundation
import OpenAI
import Testing

@testable import KeepTalkingSDK

struct ContextAttachmentAIToolTests {
    @Test("attachment listing tool is scoped to the active context")
    func attachmentListingStaysInContext() async throws {
        let fixture = try await makeFixture()

        let messages = try await fixture.client.executeAgentToolCalls(
            [
                toolCall(
                    name: KeepTalkingClient.contextAttachmentListingToolFunctionName,
                    arguments: "{}"
                )
            ],
            runtimeCatalog: emptyRuntimeCatalog(),
            context: fixture.visibleContext
        )

        let payload = try toolPayload(from: messages)
        let attachments = try #require(payload["attachments"] as? [[String: Any]])
        let firstAttachment = try #require(attachments.first)
        let firstAttachmentID = firstAttachment["attachment_id"] as? String
        let firstFilename = firstAttachment["filename"] as? String

        #expect(payload["count"] as? Int == 1)
        #expect(attachments.count == 1)
        #expect(firstAttachmentID == fixture.visibleAttachmentID.uuidString.lowercased())
        #expect(firstFilename == "visible.txt")
    }

    @Test("attachment read tool refuses attachment ids from another context")
    func attachmentReadRejectsOtherContextAttachment() async throws {
        let fixture = try await makeFixture()

        let messages = try await fixture.client.executeAgentToolCalls(
            [
                toolCall(
                    name: KeepTalkingClient.contextAttachmentReadToolFunctionName,
                    arguments: """
                        {"attachment_id":"\(fixture.hiddenAttachmentID.uuidString.lowercased())","mode":"metadata"}
                        """
                )
            ],
            runtimeCatalog: emptyRuntimeCatalog(),
            context: fixture.visibleContext
        )

        let payload = try toolPayload(from: messages)

        #expect(messages.count == 1)
        #expect(payload["ok"] as? Bool == false)
        #expect(payload["error"] as? String == "attachment_not_found")
        #expect(payload["attachment_id"] as? String == fixture.hiddenAttachmentID.uuidString.lowercased())
    }

    private func makeFixture() async throws -> (
        client: KeepTalkingClient,
        visibleContext: KeepTalkingContext,
        visibleAttachmentID: UUID,
        hiddenAttachmentID: UUID
    ) {
        let localStore = KeepTalkingInMemoryStore()
        let visibleContext = KeepTalkingContext(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        )
        let hiddenContext = KeepTalkingContext(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
        )
        let nodeID = UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: try #require(visibleContext.id),
                node: nodeID
            ),
            localStore: localStore
        )

        try await visibleContext.save(on: localStore.database)
        try await hiddenContext.save(on: localStore.database)

        let visibleAttachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!,
            context: visibleContext,
            sender: .node(node: nodeID),
            blobID: String(repeating: "a", count: 64),
            filename: "visible.txt",
            mimeType: "text/plain",
            byteCount: 3,
            metadata: .init(textPreview: "abc")
        )
        let hiddenAttachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000005")!,
            context: hiddenContext,
            sender: .node(node: nodeID),
            blobID: String(repeating: "b", count: 64),
            filename: "hidden.txt",
            mimeType: "text/plain",
            byteCount: 3,
            metadata: .init(textPreview: "xyz")
        )

        try await visibleAttachment.save(on: localStore.database)
        try await hiddenAttachment.save(on: localStore.database)

        return (
            client,
            visibleContext,
            try #require(visibleAttachment.id),
            try #require(hiddenAttachment.id)
        )
    }

    private func emptyRuntimeCatalog() -> KeepTalkingActionRuntimeCatalog {
        KeepTalkingActionRuntimeCatalog(
            catalog: .init(definitions: []),
            routesByFunctionName: [:],
            skillSummaries: []
        )
    }

    private func toolCall(
        name: String,
        arguments: String,
        id: String = "tool-call-1"
    ) -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
        .ToolCallParam
    {
        .init(
            id: id,
            function: .init(
                arguments: arguments,
                name: name
            )
        )
    }

    private func toolPayload(
        from messages: [ChatQuery.ChatCompletionMessageParam]
    ) throws -> [String: Any] {
        let firstMessage = try #require(messages.first)
        guard case .tool(let toolMessage) = firstMessage else {
            throw FixtureError.missingToolMessage
        }
        let text: String
        switch toolMessage.content {
            case .textContent(let value):
                text = value
            case .contentParts(let parts):
                text = parts.map { $0.text }.joined()
        }
        guard let data = text.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw FixtureError.invalidToolPayload
        }
        return payload
    }

    private enum FixtureError: Error {
        case missingToolMessage
        case invalidToolPayload
    }
}
