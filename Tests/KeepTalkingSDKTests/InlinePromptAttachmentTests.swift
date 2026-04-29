import AIProxy
import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct InlinePromptAttachmentTests {
    @Test("prepared prompt attachments survive source file deletion")
    func preparedPromptAttachmentsSurviveSourceDeletion() async throws {
        let client = makeClient()
        let fileURL = try makeTemporaryFile(
            named: "inline-note.txt",
            contents: "snapshot-content"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let prepared = try await client.prepareLocalAttachments(
            [
                KeepTalkingLocalAttachmentInput(sourceURL: fileURL)
            ]
        )
        try FileManager.default.removeItem(at: fileURL)

        let message = try await client.currentPromptUserMessage(
            prompt: "Inspect this file",
            attachments: prepared
        )

        let text = try #require(userText(from: message))
        #expect(text.contains("snapshot-content"))
        #expect(text.contains("inline-note.txt"))
    }

    @Test("prepared prompt attachments reuse normal context attachment persistence")
    func preparedPromptAttachmentsPersistAsContextAttachments() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let client = makeClient(localStore: localStore)
        let context = KeepTalkingContext(
            id: UUID(uuidString: "F0000000-0000-0000-0000-000000000021")!
        )
        try await context.save(on: localStore.database)

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "A0000000-0000-0000-0000-000000000021")!
        )
        let message = KeepTalkingContextMessage(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000021")!,
            context: context,
            sender: sender,
            content: "@AI inspect the attachment"
        )
        try await message.save(on: localStore.database)

        let fileURL = try makeTemporaryFile(
            named: "persisted.txt",
            contents: "persist-me"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let prepared = try await client.prepareLocalAttachments(
            [
                KeepTalkingLocalAttachmentInput(sourceURL: fileURL)
            ]
        )
        let saved = try await client.persistOutgoingAttachments(
            prepared,
            in: context,
            parentMessage: message,
            sender: sender
        )

        let attachment = try #require(saved.first)
        #expect(saved.count == 1)
        #expect(attachment.$parentMessage.id == message.id)
        #expect(attachment.filename == "persisted.txt")
        #expect(attachment.byteCount == "persist-me".utf8.count)
        #expect(attachment.metadata.textPreview == "persist-me")
    }

    @Test("agent run failures are published back into context")
    func agentRunFailuresPublishContextMessage() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let client = makeClient(localStore: localStore)
        let contextID = UUID(uuidString: "F0000000-0000-0000-0000-000000000031")!

        await client.publishAgentRunFailure(
            contextID: contextID,
            roleName: "ai",
            model: "gpt-5-codex",
            message: "Attachment preparation failed."
        )

        let messages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id == contextID)
        .sort(\.$timestamp, .ascending)
        .all()

        let message = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(message.content == "Agent run failed: Attachment preparation failed.")
        if case .autonomous(let name, _, let model) = message.sender {
            #expect(name == "ai")
            #expect(model == "gpt-5-codex")
        } else {
            Issue.record("Expected an autonomous sender for the run failure message")
        }
    }

    private func makeClient(
        localStore: any KeepTalkingLocalStore = KeepTalkingInMemoryStore()
    ) -> KeepTalkingClient {
        KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: URL(string: "ws://127.0.0.1")!,
                contextID: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!,
                node: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
            ),
            localStore: localStore
        )
    }

    private func makeTemporaryFile(
        named filename: String,
        contents: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(filename)
        guard let data = contents.data(using: .utf8) else {
            fatalError("Failed to encode temporary file contents.")
        }
        try data.write(to: fileURL)
        return fileURL
    }

    private func userText(
        from message: OpenAIChatCompletionRequestBody.Message
    ) -> String? {
        guard case .user(let content, _) = message else {
            return nil
        }

        switch content {
            case .text(let value):
                return value
            case .parts(let parts):
                return parts.compactMap { part in
                    switch part {
                        case .text(let value):
                            return value
                        case .imageURL:
                            return nil
                    }
                }
                .joined(separator: "\n")
        }
    }
}
