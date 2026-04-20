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
                    name: KeepTalkingClient.contextAttachmentReadToolFunctionName,
                    arguments: """
                        {"attachment_id":"\(fixture.hiddenAttachmentID.uuidString.lowercased())","mode":"metadata"}
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
        #expect(payload["attachment_id"] as? String == fixture.hiddenAttachmentID.uuidString.lowercased())
    }

    @Test("ask-for-file action appends synced files back into the same AI turn")
    func askForFileActionInjectsNativeAttachmentMessage() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let contextID = UUID(uuidString: "F0000000-0000-0000-0000-000000000006")!
        let nodeID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let attachmentData = Data("abc".utf8)
        let blobID = String(repeating: "c", count: 64)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: nodeID
            ),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in JSONSchema(.type(.object)) },
                callAction: { _, _ in
                    KeepTalkingPrimitiveActionResponse(
                        text: """
                            {"status":"sent_to_context","context_id":"\(contextID.uuidString.lowercased())","attachments":[{"blob_id":"\(blobID)","size":3}]}
                            """
                    )
                }
            ),
            localStore: localStore
        )

        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: localStore.database)

        let node = KeepTalkingNode(id: nodeID)
        try await node.save(on: localStore.database)

        let stored = try client.blobStore.put(
            data: attachmentData,
            blobID: blobID,
            pathExtension: "txt"
        )
        try await client.upsertBlobRecord(
            blobID: blobID,
            relativePath: stored.relativePath,
            availability: .ready,
            mimeType: "text/plain",
            byteCount: attachmentData.count,
            receivedBytes: attachmentData.count
        )

        let attachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!,
            context: context,
            sender: .node(node: nodeID),
            blobID: blobID,
            filename: "picked.txt",
            mimeType: "text/plain",
            byteCount: attachmentData.count
        )
        try await attachment.save(on: localStore.database)

        let bundle = KeepTalkingPrimitiveBundle(
            name: "ask-for-file",
            indexDescription: "Ask for a file",
            action: .askForFile
        )
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        action.$node.id = nodeID
        _ = try await client.saveConstructedAction(action)

        let definition = client.makePrimitiveActionProxyDefinition(
            actionID: try #require(action.id),
            ownerNodeID: nodeID,
            bundle: bundle,
            descriptor: nil
        )

        let toolCall = toolCall(
            name: definition.functionName,
            arguments: "{}",
            id: "tool-call-1"
        )
        let payload = try await client.executeActionProxyToolCall(
            functionName: definition.functionName,
            definition: definition,
            rawArguments: toolCall.function.arguments,
            context: context
        )
        let executions = [
            AIOrchestrator.ToolExecution(
                toolCall: toolCall,
                messages: [
                    client.toolMessage(
                        payload: payload,
                        toolCallID: toolCall.id
                    )
                ]
            )
        ]
        let messages = try await client.adaptMidTurnInjectionMessages(
            executions,
            runtimeCatalog: runtimeCatalog(definition: definition),
            context: context
        )

        #expect(messages.count == 1)
        guard case .user(let message) = try #require(messages.first) else {
            Issue.record("Expected a native user message for the picked file")
            return
        }
        guard case .contentParts(let parts) = message.content else {
            Issue.record("Expected content parts for injected file payload")
            return
        }
        #expect(parts.count == 1)
        if case .text(let textPart) = try #require(parts.first) {
            #expect(
                textPart.text
                    == """
                    Inspect the attached context file 'picked.txt'. This is the user-provided attachment you just requested, and it is already included in this turn. Use it directly. Do not call context attachment tools to verify this same file again; only call them if you truly need a different attachment or metadata not present here.

                    abc
                    """
            )
        } else {
            Issue.record("Expected a leading text part for injected file prompt")
        }
    }

    @Test("ask-for-file action waits for complete transfer receipt")
    func askForFileActionRequiresReadyBlobBeforeContinuing() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let contextID = UUID(uuidString: "F0000000-0000-0000-0000-000000000006")!
        let nodeID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let blobID = String(repeating: "d", count: 64)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: nodeID
            ),
            primitiveRegistry: KeepTalkingPrimitiveRegistry(
                toolParameters: { _ in JSONSchema(.type(.object)) },
                callAction: { _, _ in
                    KeepTalkingPrimitiveActionResponse(
                        text: """
                            {"status":"sent_to_context","context_id":"\(contextID.uuidString.lowercased())","attachments":[{"blob_id":"\(blobID)","size":3}]}
                            """
                    )
                }
            ),
            localStore: localStore
        )

        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: localStore.database)

        let node = KeepTalkingNode(id: nodeID)
        try await node.save(on: localStore.database)

        let attachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!,
            context: context,
            sender: .node(node: nodeID),
            blobID: blobID,
            filename: "picked.txt",
            mimeType: "text/plain",
            byteCount: 3
        )
        try await attachment.save(on: localStore.database)

        let bundle = KeepTalkingPrimitiveBundle(
            name: "ask-for-file",
            indexDescription: "Ask for a file",
            action: .askForFile
        )
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        action.$node.id = nodeID
        _ = try await client.saveConstructedAction(action)

        let definition = client.makePrimitiveActionProxyDefinition(
            actionID: try #require(action.id),
            ownerNodeID: nodeID,
            bundle: bundle,
            descriptor: nil
        )

        let toolCall = toolCall(
            name: definition.functionName,
            arguments: "{}",
            id: "tool-call-1"
        )
        let payload = try await client.executeActionProxyToolCall(
            functionName: definition.functionName,
            definition: definition,
            rawArguments: toolCall.function.arguments,
            context: context
        )
        let executions = [
            AIOrchestrator.ToolExecution(
                toolCall: toolCall,
                messages: [
                    client.toolMessage(
                        payload: payload,
                        toolCallID: toolCall.id
                    )
                ]
            )
        ]

        await #expect(throws: AskForFileToolError.self) {
            try await client.adaptMidTurnInjectionMessages(
                executions,
                runtimeCatalog: runtimeCatalog(definition: definition),
                context: context,
                transferReceiptTimeout: .milliseconds(50)
            )
        }
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
            actionStubs: [],
            remoteSemanticRetrievalActions: [],
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
            lazyRegistry: KeepTalkingLazyToolRegistry()
        )
    }

    private func toolCall(
        name: String,
        arguments: String,
        id: String = "tool-call-1"
    )
        -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
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
        from executions: [AIOrchestrator.ToolExecution]
    ) throws -> [String: Any] {
        let firstExecution = try #require(executions.first)
        return try toolPayload(from: firstExecution.messages)
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
