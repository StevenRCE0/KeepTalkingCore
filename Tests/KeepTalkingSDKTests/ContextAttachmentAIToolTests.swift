import AIProxy
import Foundation
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
            promptMessageID: nil,
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
                    name: KeepTalkingClient.resourceReadToolFunctionName,
                    arguments: """
                        {"handle":"\(fixture.hiddenAttachmentID.uuidString.lowercased())","mode":"metadata"}
                        """
                )
            ],
            runtimeCatalog: emptyRuntimeCatalog(),
            promptMessageID: nil,
            context: fixture.visibleContext
        )

        let payload = try toolPayload(from: messages)

        #expect(messages.count == 1)
        #expect(payload["ok"] as? Bool == false)
        #expect(payload["error"] as? String == "attachment_not_found")
        #expect(payload["handle"] as? String == fixture.hiddenAttachmentID.uuidString.lowercased())
    }

    @Test("produced otb resources are injected as native user messages")
    func producedOTBResourcesAreInjected() async throws {
        let fixture = try await makeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kt-produced-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("answer.txt")
        try Data("needle from produced file".utf8).write(to: fileURL)

        let stagedOutput = await fixture.client.stagedFileStore.stageLocalFile(
            at: fileURL,
            filename: "answer.txt",
            callerNodeID: fixture.client.config.node
        )
        let staged = try #require(stagedOutput)
        let resource = KTResourceManifest.AgentResource.otb(
            id: staged.handle,
            name: "answer.txt",
            mimeType: nil,
            byteCount: staged.byteCount)
        let execution = AIOrchestrator.ToolExecution(
            toolCall: toolCall(name: KeepTalkingClient.runActionToolFunctionName, arguments: "{}"),
            messages: [
                .tool(
                    try jsonPayload([
                        "ok": true,
                        "produced_resources": [resource.jsonObject()],
                    ]),
                    toolCallID: "tool-call-1"
                )
            ]
        )

        let injected = await KeepTalkingIOManager(client: fixture.client)
            .transcriptMessagesForProducedResources(
                from: [execution],
                context: fixture.visibleContext
            )

        #expect(injected.count == 1)
        #expect(injected.first?.role == .user)
        let text = try #require(injected.first?.content?.text)
        #expect(text.contains(resource.handle))
        #expect(text.contains("needle from produced file"))
        #expect(text.contains("do NOT call any tool"))
    }

    private func makeFixture() async throws -> (
        client: KeepTalkingClient,
        visibleContext: KeepTalkingContext,
        visibleAttachmentID: UUID,
        hiddenAttachmentID: UUID
    ) {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let visibleContext = KeepTalkingContext(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        )
        let hiddenContext = KeepTalkingContext(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
        )
        let nodeID = UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
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
            actionStubs: [],
            remoteSemanticRetrievalActions: [],
            remoteActionCreationActions: [],
            lazyRegistry: KeepTalkingLazyToolRegistry()
        )
    }

    private func runtimeCatalog(
        definition: KeepTalkingActionToolDefinition
    ) -> KeepTalkingActionRuntimeCatalog {
        KeepTalkingActionRuntimeCatalog(
            catalog: .init(definitions: [definition]),
            routesByFunctionName: [
                definition.functionName: .actionProxy(definition)
            ],
            actionStubs: [],
            remoteSemanticRetrievalActions: [],
            remoteActionCreationActions: [],
            lazyRegistry: KeepTalkingLazyToolRegistry()
        )
    }

    private func toolCall(
        name: String,
        arguments: String,
        id: String = "tool-call-1"
    ) -> AIToolCall {
        AIToolCall(
            id: id,
            name: name,
            argumentsJSON: arguments
        )
    }

    private func toolPayload(
        from executions: [AIOrchestrator.ToolExecution]
    ) throws -> [String: Any] {
        let firstExecution = try #require(executions.first)
        return try toolPayload(from: firstExecution.messages)
    }

    private func toolPayload(
        from messages: [AIMessage]
    ) throws -> [String: Any] {
        let firstMessage = try #require(messages.first)
        guard firstMessage.role == .tool, let content = firstMessage.content else {
            throw FixtureError.missingToolMessage
        }
        let text: String
        switch content {
            case .text(let value):
                text = value
            case .parts(let parts):
                text = parts.compactMap { part in
                    if case .text(let value) = part {
                        return value
                    }
                    return nil
                }
                .joined()
        }
        guard let data = text.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw FixtureError.invalidToolPayload
        }
        return payload
    }

    private func jsonPayload(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private enum FixtureError: Error {
        case missingToolMessage
        case invalidToolPayload
    }
}
