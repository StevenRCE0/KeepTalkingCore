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
        let attachmentMessageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000303"
        )!
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
                    id: attachmentMessageID.uuidString,
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
            ],
            attachments: [
                makeAttachment(
                    id: "00000000-0000-0000-0000-000000000306",
                    context: config.contextID,
                    parentMessageID: attachmentMessageID,
                    sender: sender,
                    blobID: String(repeating: "f", count: 64),
                    filename: "three.png",
                    mimeType: "image/png",
                    byteCount: 42,
                    second: 3
                )
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
        #expect(result.attachments.map(\.parentMessageID) == [
            attachmentMessageID
        ])
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

    @Test("incoming attachment dto creates a pending attachment placeholder")
    func saveIncomingAttachmentDTOCreatesPlaceholder() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "81000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "AAAAAAAA-8888-8888-8888-888888888888")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-8888-8888-8888-888888888888")!
        )
        let parentMessageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000411"
        )!
        _ = try await seededContext(
            on: localStore,
            id: config.contextID,
            chunkSize: 2,
            messages: [
                makeMessage(
                    id: parentMessageID.uuidString,
                    context: config.contextID,
                    sender: sender,
                    content: "",
                    second: 1
                )
            ]
        )

        let attachments = try await client.saveIncomingAttachments(
            [
                KeepTalkingContextAttachmentDTO(
                    id: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000412"
                    )!,
                    contextID: config.contextID,
                    parentMessageID: parentMessageID,
                    blobID: String(repeating: "d", count: 64),
                    filename: "pending.png",
                    mimeType: "image/png",
                    byteCount: 1234,
                    sortIndex: 0
                )
            ]
        )

        #expect(attachments.count == 1)
        #expect(attachments.first?.$parentMessage.id == parentMessageID)
        let attachmentID = try #require(attachments[0].id)

        let storedAttachment = try #require(
            try await KeepTalkingContextAttachment.query(on: localStore.database)
                .filter(\.$id, .equal, attachmentID)
                .first()
        )
        #expect(storedAttachment.filename == "pending.png")
        #expect(storedAttachment.sender == sender)

        let blobRecord = try #require(
            try await KeepTalkingBlobRecord.query(on: localStore.database)
                .filter(\.$id, .equal, attachments[0].blobID)
                .first()
        )
        #expect(blobRecord.availability == .missing)
        #expect(blobRecord.byteCount == 1234)
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

    @Test("attachment sync request includes only recent missing hashes")
    func attachmentRequestReturnsRecentMissingHashes() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let config = KeepTalkingConfig(
            signalURL: try #require(URL(string: "ws://127.0.0.1")),
            contextID: UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "EEEEEEEE-1111-1111-1111-111111111111")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )
        let context = KeepTalkingContext(id: config.contextID)
        try await context.save(on: localStore.database)

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "FFFFFFFF-2222-2222-2222-222222222222")!
        )
        let oldAttachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            context: context,
            sender: sender,
            blobID: String(repeating: "a", count: 64),
            filename: "old.png",
            mimeType: "image/png",
            byteCount: 10,
            createdAt: Date(timeIntervalSince1970: 10),
            sortIndex: 0
        )
        let recentAttachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            context: context,
            sender: sender,
            blobID: String(repeating: "b", count: 64),
            filename: "recent.png",
            mimeType: "image/png",
            byteCount: 20,
            createdAt: Date(timeIntervalSince1970: 20),
            sortIndex: 0
        )
        let missingRecentAttachment = KeepTalkingContextAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
            context: context,
            sender: sender,
            blobID: String(repeating: "c", count: 64),
            filename: "missing.png",
            mimeType: "image/png",
            byteCount: 30,
            createdAt: Date(timeIntervalSince1970: 25),
            sortIndex: 1
        )
        try await oldAttachment.save(on: localStore.database)
        try await recentAttachment.save(on: localStore.database)
        try await missingRecentAttachment.save(on: localStore.database)

        let stored = try client.blobStore.put(
            data: Data([0x01, 0x02]),
            blobID: recentAttachment.blobID,
            pathExtension: "png"
        )
        try await client.upsertBlobRecord(
            blobID: recentAttachment.blobID,
            relativePath: stored.relativePath,
            availability: .ready,
            mimeType: recentAttachment.mimeType,
            byteCount: recentAttachment.byteCount,
            receivedBytes: recentAttachment.byteCount
        )

        let request = try await client.contextSyncAttachmentRequest(
            in: config.contextID,
            since: Date(timeIntervalSince1970: 15)
        )

        #expect(request?.hashes == [missingRecentAttachment.blobID])
    }

    private func seededContext(
        on localStore: KeepTalkingInMemoryStore,
        id: UUID,
        chunkSize: Int,
        messages: [KeepTalkingContextMessage],
        attachments: [KeepTalkingContextAttachment] = []
    ) async throws -> KeepTalkingContext {
        let context = KeepTalkingContext(id: id)
        try await context.save(on: localStore.database)
        for message in messages {
            try await message.save(on: localStore.database)
        }
        for attachment in attachments {
            try await attachment.save(on: localStore.database)
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

    private func makeAttachment(
        id: String,
        context: UUID,
        parentMessageID: UUID,
        sender: KeepTalkingContextMessage.Sender,
        blobID: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        second: TimeInterval
    ) -> KeepTalkingContextAttachment {
        KeepTalkingContextAttachment(
            id: UUID(uuidString: id)!,
            context: KeepTalkingContext(id: context),
            parentMessageID: parentMessageID,
            sender: sender,
            blobID: blobID,
            filename: filename,
            mimeType: mimeType,
            byteCount: byteCount,
            createdAt: Date(timeIntervalSince1970: second),
            sortIndex: 0
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
