import Foundation
import Testing

@testable import KeepTalkingSDK

struct ThreadSemanticDocumentTests {
    @Test("thread semantic document includes transcript even when a summary exists")
    func documentIncludesTranscriptAlongsideSummary() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        try await context.save(on: store.database)

        let first = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            context: context,
            sender: .autonomous(name: "planner"),
            content: "Let's map the migration steps.",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let second = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            context: context,
            sender: .node(node: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!),
            content: "We should migrate the embeddings after the schema change.",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        try await first.save(on: store.database)
        try await second.save(on: store.database)

        let thread = KeepTalkingThread(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            context: context,
            startMessage: first,
            endMessage: second,
            state: .stored
        )
        thread.summary = "Migration Plan"
        try await thread.save(on: store.database)

        let text = try await KeepTalkingClient.threadDocumentText(
            for: thread,
            on: store.database
        )

        #expect(text.contains("Topic: Migration Plan"))
        #expect(text.contains("Let's map the migration steps."))
        #expect(text.contains("We should migrate the embeddings after the schema change."))
    }

    @Test("thread semantic document skips chitter chatter and keeps attachment metadata")
    func documentOmitsChatterButIncludesAttachments() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        try await context.save(on: store.database)

        let chatter = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            context: context,
            sender: .autonomous(name: "assistant"),
            content: "Thanks!",
            timestamp: Date(timeIntervalSince1970: 3)
        )
        let useful = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
            context: context,
            sender: .autonomous(name: "assistant"),
            content: "The PDF extract contains the billing totals.",
            timestamp: Date(timeIntervalSince1970: 4)
        )
        try await chatter.save(on: store.database)
        try await useful.save(on: store.database)

        let thread = KeepTalkingThread(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            context: context,
            startMessage: chatter,
            endMessage: useful,
            state: .stored,
            chitterChatter: [chatter.id!]
        )
        try await thread.save(on: store.database)

        let attachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            context: context,
            parentMessageID: useful.id!,
            sender: useful.sender,
            blobID: String(repeating: "a", count: 64),
            filename: "report.pdf",
            mimeType: "application/pdf",
            byteCount: 1024,
            metadata: .init(
                textPreview: "April billing totals",
                tags: ["finance", "pdf"],
                pageCount: 3
            )
        )
        try await attachment.save(on: store.database)

        let text = try await KeepTalkingClient.threadDocumentText(
            for: thread,
            on: store.database
        )

        #expect(!text.contains("Thanks!"))
        #expect(text.contains("The PDF extract contains the billing totals."))
        #expect(text.contains("[Attachments]"))
        #expect(text.contains("report.pdf (application/pdf)"))
        #expect(text.contains("preview: April billing totals"))
        #expect(text.contains("tags: finance, pdf"))
    }
}
