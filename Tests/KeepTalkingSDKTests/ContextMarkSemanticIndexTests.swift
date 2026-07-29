import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextMarkSemanticIndexTests {
    @Test("consuming an incoming turning-point mark queues semantic reconciliation")
    func incomingTurningPointQueuesReconciliation() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: store.database)

        let firstID = UUID()
        let first = KeepTalkingContextMessage(
            id: firstID,
            context: context,
            sender: .node(node: UUID()),
            content: "Previous topic",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let secondID = UUID()
        let second = KeepTalkingContextMessage(
            id: secondID,
            context: context,
            sender: .node(node: UUID()),
            content: "Current topic",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        try await first.save(on: store.database)
        try await second.save(on: store.database)

        let main = KeepTalkingThread(
            context: context,
            startMessage: first,
            endMessage: nil,
            state: .contextMain
        )
        try await main.save(on: store.database)

        let markID = UUID()
        let incomingMark = KeepTalkingContextMessage(
            id: markID,
            context: context,
            sender: .node(node: UUID()),
            content: "",
            timestamp: Date(timeIntervalSince1970: 3),
            type: .markTurningPoint(
                messageID: secondID,
                previousTopicName: "Previous",
                currentTopicName: "Current"
            )
        )
        try await incomingMark.save(on: store.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        let probe = ContextIDProbe()
        client.onSemanticIndexNeedsReconciliation = { contextID in
            await probe.record(contextID)
        }

        try await client.consumePendingMarks(in: contextID)

        #expect(await probe.recordedIDs() == [contextID])
        let savedContext = try #require(
            try await KeepTalkingContext.find(contextID, on: store.database)
        )
        #expect(savedContext.consumedMarks?.contains(markID) == true)

        let threads = try await KeepTalkingThread.query(on: store.database)
            .filter(\.$context.$id == contextID)
            .all()
        #expect(threads.count == 2)
        #expect(threads.contains { $0.state == .stored && $0.summary == "Previous" })
        #expect(threads.contains { $0.state == .contextMain && $0.summary == "Current" })
    }

    @Test("semantic retry reloads newer persisted thread state after a partial failure")
    func retryReloadsPersistedThreads() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: store.database)

        let firstMessage = KeepTalkingContextMessage(
            context: context,
            sender: .node(node: UUID()),
            content: "First transcript",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let secondMessage = KeepTalkingContextMessage(
            context: context,
            sender: .node(node: UUID()),
            content: "Second transcript",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        try await firstMessage.save(on: store.database)
        try await secondMessage.save(on: store.database)

        let failingThreadID = UUID()
        let failingThread = KeepTalkingThread(
            id: failingThreadID,
            context: context,
            startMessage: firstMessage,
            endMessage: firstMessage,
            state: .stored
        )
        failingThread.summary = "Original"
        let otherThread = KeepTalkingThread(
            context: context,
            startMessage: secondMessage,
            endMessage: secondMessage,
            state: .stored
        )
        try await failingThread.save(on: store.database)
        try await otherThread.save(on: store.database)

        let semanticStore = FlakySemanticStore(failingOnceFor: failingThreadID)
        var firstPassFailed = false
        do {
            try await KeepTalkingClient.reconcileContextThreads(
                contextID,
                on: store.database,
                semanticStore: semanticStore
            )
        } catch {
            firstPassFailed = true
        }

        #expect(firstPassFailed)
        #expect(await semanticStore.documentCount() == 1)
        let failedThread = try #require(
            try await KeepTalkingThread.find(failingThreadID, on: store.database)
        )
        #expect(failedThread.semanticDocumentDigest == nil)

        failingThread.summary = "Persisted after failure"
        try await failingThread.save(on: store.database)

        try await KeepTalkingClient.reconcileContextThreads(
            contextID,
            on: store.database,
            semanticStore: semanticStore
        )

        #expect(await semanticStore.documentCount() == 2)
        let retriedText = try #require(await semanticStore.document(id: failingThreadID))
        #expect(retriedText.contains("Topic: Persisted after failure"))
        #expect(!retriedText.contains("Topic: Original"))
        let repairedThread = try #require(
            try await KeepTalkingThread.find(failingThreadID, on: store.database)
        )
        let repairedDigest = try #require(repairedThread.semanticDocumentDigest)

        repairedThread.summary = "Persisted after successful embed"
        try await repairedThread.save(on: store.database)

        try await KeepTalkingClient.reconcileContextThreads(
            contextID,
            on: store.database,
            semanticStore: semanticStore
        )

        let latestText = try #require(await semanticStore.document(id: failingThreadID))
        #expect(latestText.contains("Topic: Persisted after successful embed"))
        let latestThread = try #require(
            try await KeepTalkingThread.find(failingThreadID, on: store.database)
        )
        #expect(latestThread.semanticDocumentDigest != repairedDigest)
    }
}

private actor ContextIDProbe {
    private var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }

    func recordedIDs() -> [UUID] {
        ids
    }
}

private struct SimulatedSemanticFailure: Error {}

private actor FlakySemanticStore: KeepTalkingSemanticStore {
    private let failingThreadID: UUID
    private var shouldFail = true
    private var documents: [UUID: String] = [:]

    init(failingOnceFor threadID: UUID) {
        failingThreadID = threadID
    }

    func indexThread(id: UUID, text: String) throws {
        if id == failingThreadID, shouldFail {
            shouldFail = false
            throw SimulatedSemanticFailure()
        }
        documents[id] = text
    }

    func updateThread(id: UUID, text: String) {
        documents[id] = text
    }

    func removeThread(id: UUID) {
        documents[id] = nil
    }

    func search(
        query: String,
        topK: Int,
        threshold: Float?
    ) -> [KeepTalkingSemanticSearchResult] {
        []
    }

    func reset() {
        documents = [:]
    }

    func documentCount() -> Int {
        documents.count
    }

    func allDocuments() -> [(id: UUID, text: String)] {
        documents.map { ($0.key, $0.value) }
    }

    func document(id: UUID) -> String? {
        documents[id]
    }
}
