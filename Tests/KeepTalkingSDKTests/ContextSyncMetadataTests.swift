import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextSyncMetadataTests {
    /// Settles whether the raw-bit-pattern timestamp in `messageDigest` is a
    /// reachable regression or only a theoretical one. The digest feeds chunk
    /// comparison, so if a `Date` does not survive the SQLite round-trip
    /// bit-exactly, two peers holding the *same* message compute different
    /// chunk digests and that chunk can never reconcile.
    @Test("message digest survives a persistence round-trip")
    func messageDigestSurvivesRoundTrips() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
        )
        try await context.save(on: localStore.database)
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        )

        // Timestamps with sub-millisecond fractions are the interesting case:
        // a whole-second value would round-trip trivially.
        var mismatches: [(index: Int, timestamp: Date)] = []
        for index in 0..<200 {
            let timestamp = Date(
                timeIntervalSince1970: 1_700_000_000
                    + Double(index) * 0.000_137_913
            )
            let message = KeepTalkingContextMessage(
                id: UUID.v7(),
                context: context,
                sender: sender,
                content: "round-trip \(index)",
                timestamp: timestamp
            )
            let inMemory = messageDigest(for: message)
            try await message.save(on: localStore.database)

            let persisted = try #require(
                try await KeepTalkingContextMessage.find(
                    message.requireID(),
                    on: localStore.database
                )
            )
            if messageDigest(for: persisted) != inMemory {
                mismatches.append((index, timestamp))
            }
        }

        #expect(
            mismatches.isEmpty,
            "\(mismatches.count)/200 message digests changed across the SQLite round-trip; first at index \(mismatches.first?.index ?? -1)"
        )
    }

    @Test("context refresh stores local sender and chunk summaries")
    func refreshStoresChunkedMetadata() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
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

        // Built on demand from the table — the summary is no longer cached on
        // the context row, so this is the same path a sync request takes.
        let contextID = try #require(context.id)
        let stored = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .all()
        let metadata = KeepTalkingContext.buildSyncMetadata(
            from: stored,
            chunkSize: 2
        )
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

    @Test("context encoding carries no cached sync state")
    func encodingCarriesNoCachedSyncState() throws {
        let context = KeepTalkingContext(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
        )
        context.$messages.value = []

        let data = try JSONEncoder().encode(context)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let messages = try #require(payload["messages"] as? [Any])
        #expect(messages.isEmpty)
        // The summary is derived per request now, so there is no cached copy to
        // leak into a shared payload — this guards against reintroducing one.
        #expect(payload["syncMetadata"] == nil)
        #expect(payload["sync_metadata"] == nil)
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
