import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextSyncTransportTests {
    @Test("context sync callback is emitted after a sync completes")
    func contextSyncCallbackEmission() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let contextID = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: contextID,
                node: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
            ),
            localStore: localStore
        )

        let observed = LockedValue<UUID?>(nil)
        client.onContextSync = { observed.set($0) }

        client.notifyContextDidSync(contextID)

        #expect(observed.get() == contextID)
    }

    @Test("summary dispatch returns locally maintained context sync metadata")
    func summaryDispatchReturnsMetadata() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "40000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222")!
        )
        let context = try await seededContext(
            on: localStore,
            id: config.contextID,
            chunkSize: 2,
            messages: [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000101",
                    context: config.contextID,
                    sender: sender,
                    content: "one",
                    second: 1
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000102",
                    context: config.contextID,
                    sender: sender,
                    content: "two",
                    second: 2
                ),
            ]
        )

        let result = try await client.dispatchContextSyncSummaryRequest(
            to: config.node,
            in: context
        )
        let metadata = try #require(context.syncMetadata)

        #expect(result.context == config.contextID)
        #expect(result.requester == config.node)
        #expect(result.responder == config.node)
        #expect(result.summary == metadata)
    }

    @Test("tail request planning asks only for senders with more remote messages")
    func tailRequestPlanning() throws {
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "CCCCCCCC-3333-3333-3333-333333333333")!
        )
        let local = KeepTalkingContextSyncMetadata(
            chunkSize: 2,
            messageCount: 1,
            senders: [
                .init(sender: sender, messageCount: 1)
            ],
            chunks: []
        )
        let remote = KeepTalkingContextSyncMetadata(
            chunkSize: 2,
            messageCount: 3,
            senders: [
                .init(sender: sender, messageCount: 3)
            ],
            chunks: []
        )

        let request = try #require(
            KeepTalkingContextSyncTailRequest(
                context: UUID(uuidString: "50000000-0000-0000-0000-000000000000")!,
                requester: UUID(uuidString: "DDDDDDDD-4444-4444-4444-444444444444")!,
                recipient: UUID(uuidString: "EEEEEEEE-5555-5555-5555-555555555555")!,
                local: local,
                remote: remote
            )
        )

        #expect(
            request.senders == [
                .init(sender: sender, messageCount: 1)
            ]
        )
    }

    @Test("chunk request planning picks the first mismatched chunk per sender")
    func chunkRequestPlanning() throws {
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "FFFFFFFF-6666-6666-6666-666666666666")!
        )
        let remote = KeepTalkingContextSyncMetadata(
            chunkSize: 2,
            messageCount: 4,
            senders: [
                .init(sender: sender, messageCount: 4)
            ],
            chunks: [
                .init(
                    sender: sender,
                    index: 0,
                    firstMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                    lastMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                    messageCount: 2,
                    digest: Data("same".utf8)
                ),
                .init(
                    sender: sender,
                    index: 1,
                    firstMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
                    lastMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
                    messageCount: 2,
                    digest: Data("remote".utf8)
                ),
            ]
        )
        let local = KeepTalkingContextSyncMetadata(
            chunkSize: 2,
            messageCount: 4,
            senders: remote.senders,
            chunks: [
                remote.chunks[0],
                .init(
                    sender: sender,
                    index: 1,
                    firstMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
                    lastMessage: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
                    messageCount: 2,
                    digest: Data("local".utf8)
                ),
            ]
        )

        let request = try #require(
            KeepTalkingContextSyncChunkRequest(
                context: UUID(uuidString: "60000000-0000-0000-0000-000000000000")!,
                requester: UUID(uuidString: "11111111-7777-7777-7777-777777777777")!,
                recipient: UUID(uuidString: "22222222-8888-8888-8888-888888888888")!,
                local: local,
                remote: remote
            )
        )

        #expect(
            request.chunks == [
                .init(sender: sender, index: 1)
            ]
        )
    }

    @Test("chunk dispatch returns messages from the requested chunk onward")
    func chunkDispatchReturnsChunkTail() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "70000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "33333333-9999-9999-9999-999999999999")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "44444444-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        _ = try await seededContext(
            on: localStore,
            id: config.contextID,
            chunkSize: 2,
            messages: [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000301",
                    context: config.contextID,
                    sender: sender,
                    content: "one",
                    second: 1
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000302",
                    context: config.contextID,
                    sender: sender,
                    content: "two",
                    second: 2
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000303",
                    context: config.contextID,
                    sender: sender,
                    content: "three",
                    second: 3
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000304",
                    context: config.contextID,
                    sender: sender,
                    content: "four",
                    second: 4
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000305",
                    context: config.contextID,
                    sender: sender,
                    content: "five",
                    second: 5
                ),
            ]
        )

        let result = try await client.dispatchContextSyncChunkRequest(
            KeepTalkingContextSyncChunkRequest(
                context: config.contextID,
                requester: config.node,
                recipient: config.node,
                chunks: [
                    .init(sender: sender, index: 1)
                ]
            )
        )

        let ids = result.messages.compactMap(\.id)
        #expect(
            ids == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
            ]
        )
    }

    @Test("incoming sync skips messages that already exist locally")
    func saveIncomingMessagesSkipsExistingRows() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "80000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "AAAAAAAA-9999-9999-9999-999999999999")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        _ = try await seededContext(
            on: localStore,
            id: config.contextID,
            chunkSize: 2,
            messages: [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000401",
                    context: config.contextID,
                    sender: sender,
                    content: "one",
                    second: 1
                ),
            ]
        )

        try await client.saveIncomingMessages(
            [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000401",
                    context: config.contextID,
                    sender: sender,
                    content: "duplicate",
                    second: 1
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000402",
                    context: config.contextID,
                    sender: sender,
                    content: "two",
                    second: 2
                ),
            ],
            in: config.contextID
        )

        let storedMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, config.contextID)
        .sort(\.$timestamp, .ascending)
        .all()

        #expect(storedMessages.compactMap(\.id) == [
            UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
        ])
        #expect(storedMessages.map(\.content) == ["one", "two"])

        let storedContext = try #require(
            try await KeepTalkingContext.query(on: localStore.database)
                .filter(\.$id, .equal, config.contextID)
                .first()
        )
        let metadata = try #require(storedContext.syncMetadata)
        #expect(metadata.messageCount == 2)
    }

    @Test("summary wait resolves when the reply arrives immediately during send")
    func immediateSummaryReplyDoesNotRaceThePendingWait() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "90000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "CCCCCCCC-9999-9999-9999-999999999999")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )
        let request = UUID(uuidString: "00000000-0000-0000-0000-000000000999")!
        let expected = KeepTalkingContextSyncSummaryResult(
            request: request,
            context: config.contextID,
            requester: config.node,
            responder: UUID(uuidString: "DDDDDDDD-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            summary: KeepTalkingContextSyncMetadata(
                chunkSize: 64,
                messageCount: 0,
                senders: [],
                chunks: []
            )
        )

        let result = try await client.waitForContextSyncSummary(
            request: request,
            timeoutSeconds: 0.2,
            send: {
                #expect(client.resolvePendingContextSyncSummary(expected))
            }
        )

        #expect(result == expected)
    }

    private func seededContext(
        on localStore: KeepTalkingInMemoryStore,
        id: UUID,
        chunkSize: Int,
        messages: [KeepTalkingContextMessage]
    ) async throws -> KeepTalkingContext {
        let context = KeepTalkingContext(id: id)
        try await context.save(on: localStore.database)
        for message in messages {
            try await message.save(on: localStore.database)
        }
        try await context.refreshSyncMetadata(
            on: localStore.database,
            chunkSize: chunkSize
        )
        return try #require(
            try await KeepTalkingContext.query(on: localStore.database)
                .filter(\.$id, .equal, id)
                .first()
        )
    }

    private func makeMessage(
        id: String,
        context: UUID,
        sender: KeepTalkingContextMessage.Sender,
        content: String,
        second: TimeInterval
    ) -> KeepTalkingContextMessage {
        KeepTalkingContextMessage(
            id: UUID(uuidString: id)!,
            context: KeepTalkingContext(id: context),
            sender: sender,
            content: content,
            timestamp: Date(timeIntervalSince1970: second)
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KeepTalking.tests.locked-value")
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        queue.sync {
            value = newValue
        }
    }

    func get() -> Value {
        queue.sync { value }
    }
}
