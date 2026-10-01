import Foundation
import Testing

@testable import KeepTalkingSDK

struct ThreadSemanticDocumentTests {
    @Test("thread semantic document includes transcript even when a summary exists")
    func documentIncludesTranscriptAlongsideSummary() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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

extension ThreadSemanticDocumentTests {
    @Test("a thread ending on a tied timestamp stops at its end row, by id")
    func documentStopsAtTiedBoundary() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)
        // The end row and the row after it share a timestamp; only the id
        // separates them, and the id order is the key order.
        let first = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
            context: context, sender: .autonomous(name: "a"),
            content: "inside one", timestamp: Date(timeIntervalSince1970: 1)
        )
        let end = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!,
            context: context, sender: .autonomous(name: "a"),
            content: "inside two", timestamp: Date(timeIntervalSince1970: 2)
        )
        let after = KeepTalkingContextMessage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000013")!,
            context: context, sender: .autonomous(name: "a"),
            content: "outside", timestamp: Date(timeIntervalSince1970: 2)
        )
        for message in [first, end, after] { try await message.save(on: store.database) }
        let thread = KeepTalkingThread(context: context, startMessage: first, endMessage: end, state: .stored)
        try await thread.save(on: store.database)

        let text = try await KeepTalkingClient.threadDocumentText(for: thread, on: store.database)

        #expect(text.contains("inside one"))
        #expect(text.contains("inside two"))
        #expect(!text.contains("outside"))
        await store.shutdown()
    }

    @Test("a thread past the budget keeps its newest rows across pages")
    func documentKeepsNewestAcrossPages() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)
        // More rows than a document page, each about 40 estimated tokens, so
        // the 400-token budget is met deep into the second page from the end.
        let count = KeepTalkingClient.documentPageSize + 40
        var messages: [KeepTalkingContextMessage] = []
        for index in 0..<count {
            let message = KeepTalkingContextMessage(
                id: UUID(), context: context, sender: .autonomous(name: "a"),
                content: "row \(index) " + String(repeating: "lorem ipsum ", count: 12),
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
            try await message.save(on: store.database)
            messages.append(message)
        }
        let thread = KeepTalkingThread(
            context: context, startMessage: messages[0], endMessage: nil, state: .contextMain)
        try await thread.save(on: store.database)

        let text = try await KeepTalkingClient.threadDocumentText(for: thread, on: store.database)

        #expect(text.contains("row \(count - 1) "))
        #expect(!text.contains("row 0 "))
        // Oldest kept row comes first: order is restored after filling from the end.
        let kept = text.components(separatedBy: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("row ") else { return nil }
            return Int(line.split(separator: " ")[1])
        }
        #expect(kept == kept.sorted())
        #expect(kept.count > 1)
        await store.shutdown()
    }
}
