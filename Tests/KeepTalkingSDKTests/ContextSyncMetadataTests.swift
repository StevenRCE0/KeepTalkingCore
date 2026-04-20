import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextSyncMetadataTests {
    @Test("context refresh stores local sender and chunk summaries")
    func refreshStoresChunkedMetadata() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        )
        try await context.save(on: localStore.database)

        let senderA = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let senderB = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let first = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            context: context,
            sender: senderA,
            content: "one",
            second: 1
        )
        let second = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            context: context,
            sender: senderA,
            content: "two",
            second: 2
        )
        let third = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            context: context,
            sender: senderA,
            content: "three",
            second: 3
        )
        let fourth = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            context: context,
            sender: senderB,
            content: "four",
            second: 4
        )

        try await first.save(on: localStore.database)
        try await second.save(on: localStore.database)
        try await third.save(on: localStore.database)
        try await fourth.save(on: localStore.database)

        try await context.refreshSyncMetadata(
            on: localStore.database,
            chunkSize: 2
        )

        let contextID = try #require(context.id)
        let storedContext = try #require(
            try await KeepTalkingContext.query(on: localStore.database)
                .filter(\.$id, .equal, contextID)
                .first()
        )
        let metadata = try #require(storedContext.syncMetadata)
        let firstID = try #require(first.id)
        let secondID = try #require(second.id)
        let thirdID = try #require(third.id)
        let fourthID = try #require(fourth.id)

        #expect(metadata.chunkSize == 2)
        #expect(metadata.messageCount == 4)
        #expect(
            metadata.senders == [
                .init(sender: senderA, messageCount: 3),
                .init(sender: senderB, messageCount: 1),
            ]
        )
        #expect(metadata.chunks.count == 3)
        #expect(metadata.chunks[0].firstMessage == firstID)
        #expect(metadata.chunks[0].lastMessage == secondID)
        #expect(metadata.chunks[0].messageCount == 2)
        #expect(metadata.chunks[1].firstMessage == thirdID)
        #expect(metadata.chunks[1].lastMessage == thirdID)
        #expect(metadata.chunks[1].messageCount == 1)
        #expect(metadata.chunks[2].firstMessage == fourthID)
        #expect(metadata.chunks[2].lastMessage == fourthID)
        #expect(metadata.chunks[2].messageCount == 1)
        #expect(metadata.chunks[0].digest != metadata.chunks[1].digest)
    }

    @Test("context encoding keeps local sync metadata out of shared payloads")
    func encodingOmitsSyncMetadata() throws {
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )
        let message = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let context = KeepTalkingContext(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        )
        context.$messages.value = []
        context.syncMetadata = KeepTalkingContextSyncMetadata(
            chunkSize: 2,
            messageCount: 1,
            senders: [
                .init(sender: sender, messageCount: 1)
            ],
            chunks: [
                .init(
                    sender: sender,
                    index: 0,
                    firstMessage: message,
                    lastMessage: message,
                    messageCount: 1,
                    digest: Data("digest".utf8)
                )
            ]
        )

        let data = try JSONEncoder().encode(context)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let messages = try #require(payload["messages"] as? [Any])
        #expect(messages.isEmpty)
        #expect(payload["syncMetadata"] == nil)
        #expect(payload["sync_metadata"] == nil)
    }

    @Test("saving a context refreshes local sync metadata automatically")
    func saveContextRefreshesSyncMetadata() async throws {
        let localStore = try await KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        )
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )
        let first = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            context: context,
            sender: sender,
            content: "alpha",
            second: 1
        )
        let second = message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            context: context,
            sender: sender,
            content: "beta",
            second: 2
        )
        context.$messages.value = [first, second]

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: UUID()
            ),
            localStore: localStore
        )

        try await client.saveContext(context)

        let contextID = try #require(context.id)
        let storedContext = try #require(
            try await KeepTalkingContext.query(on: localStore.database)
                .filter(\.$id, .equal, contextID)
                .first()
        )
        let metadata = try #require(storedContext.syncMetadata)
        let firstID = try #require(first.id)
        let secondID = try #require(second.id)

        #expect(metadata.messageCount == 2)
        #expect(metadata.senders == [.init(sender: sender, messageCount: 2)])
        #expect(metadata.chunks.count == 1)
        #expect(metadata.chunks[0].firstMessage == firstID)
        #expect(metadata.chunks[0].lastMessage == secondID)
    }

    private func message(
        id: UUID,
        context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender,
        content: String,
        second: TimeInterval
    ) -> KeepTalkingContextMessage {
        KeepTalkingContextMessage(
            id: id,
            context: context,
            sender: sender,
            content: content,
            timestamp: Date(timeIntervalSince1970: second)
        )
    }
}
