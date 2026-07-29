import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextSyncTransportTests {
    @Test("context sync callback preserves structured lifecycle order")
    func contextSyncCallbackEmission() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        let nodeID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: contextID,
                node: nodeID
            ),
            localStore: localStore
        )

        let syncID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let peerID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        let messageIDs = [
            UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        ]
        let expected = [
            KeepTalkingContextSyncEvent(
                syncID: syncID,
                contextID: contextID,
                peerID: peerID,
                phase: .started
            ),
            KeepTalkingContextSyncEvent(
                syncID: syncID,
                contextID: contextID,
                peerID: peerID,
                phase: .messagesApplied(messageIDs)
            ),
            KeepTalkingContextSyncEvent(
                syncID: syncID,
                contextID: contextID,
                peerID: peerID,
                phase: .completed
            ),
        ]
        let observed = ContextSyncEventRecorder()
        client.onContextSync = { event in
            await observed.append(event)
        }

        for event in expected {
            await client.notifyContextSync(event)
        }

        #expect(await observed.events() == expected)
    }

    @Test("summary dispatch returns locally maintained context sync metadata")
    func summaryDispatchReturnsMetadata() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
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
        // Derived from the table on demand — the same computation the responder
        // performs, which is now the only place a summary comes from.
        let metadata = KeepTalkingContext.buildSyncMetadata(
            from: try await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$context.$id, .equal, config.contextID)
                .all(),
            chunkSize: config.contextSyncChunkSize
        )

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
                .init(sender: sender, startIndex: 1, endIndex: 3)
            ]
        )
        #expect(request.before == nil)
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
                .init(sender: sender, index: 1, endIndex: 4)
            ]
        )
        #expect(request.before == nil)
    }

    @Test("chunk dispatch returns one bounded page and its attachments")
    func chunkDispatchReturnsBoundedPage() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        // Two messages per chunk, so five messages produce several chunks
        // without seeding a realistically-sized context.
        let config = KeepTalkingConfig(
            contextID: UUID(uuidString: "70000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "33333333-9999-9999-9999-999999999999")!,
            contextSyncChunkSize: 2
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
                ),
                makeAttachment(
                    id: "00000000-0000-0000-0000-000000000307",
                    context: config.contextID,
                    parentMessageID: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000305"
                    )!,
                    sender: sender,
                    blobID: String(repeating: "e", count: 64),
                    filename: "five.png",
                    mimeType: "image/png",
                    byteCount: 42,
                    second: 5
                ),
            ]
        )

        let snapshot = try await client.contextSyncSnapshot(
            for: config.contextID
        )
        let request = KeepTalkingContextSyncChunkRequest(
            context: config.contextID,
            requester: config.node,
            recipient: config.node,
            chunks: [
                .init(sender: sender, index: 1, endIndex: 5)
            ]
        )
        let result = try await client.dispatchContextSyncChunkRequest(request)

        let ids = result.messages.compactMap(\.id)
        #expect(
            ids == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
            ]
        )
        #expect(
            result.attachments.compactMap(\.parentMessageID) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
            ])
        let firstNextBefore = result.nextBefore
        let nextRequest = request.continuing(
            before: try #require(firstNextBefore)
        )
        let next = try await client.dispatchContextSyncChunkRequest(nextRequest)

        #expect(next.request != result.request)
        #expect(
            next.messages.compactMap(\.id) == [
                attachmentMessageID
            ])
        #expect(
            next.attachments.compactMap(\.parentMessageID) == [
                attachmentMessageID
            ])
        #expect(next.nextBefore == nil)
    }

    @Test("large context items are split by the encoded byte budget")
    func largeContextItemsAreSplitByByteBudget() throws {
        let contextID = UUID(
            uuidString: "71000000-0000-0000-0000-000000000000"
        )!
        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(
                uuidString: "55555555-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!
        )
        let snapshot = KeepTalkingContextSyncSnapshot(
            context: contextID,
            messages: [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000311",
                    context: contextID,
                    sender: sender,
                    content: String(repeating: "a", count: 40_000),
                    second: 1
                ),
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000312",
                    context: contextID,
                    sender: sender,
                    content: String(repeating: "b", count: 40_000),
                    second: 2
                ),
            ],
            attachments: [],
            chunkSize: 2
        )

        let firstTailPage = snapshot.items(
            after: [
                .init(sender: sender, startIndex: 0, endIndex: 2)
            ],
            before: nil
        )

        #expect(
            firstTailPage.items.compactMap(\.id) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
            ])
        let tailBefore = try #require(firstTailPage.nextBefore)

        let secondTailPage = snapshot.items(
            after: [
                .init(sender: sender, startIndex: 0, endIndex: 2)
            ],
            before: tailBefore
        )
        #expect(
            secondTailPage.items.compactMap(\.id) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
            ])
        #expect(secondTailPage.nextBefore == nil)

        let firstChunkPage = snapshot.items(
            in: [.init(sender: sender, index: 0, endIndex: 2)],
            before: nil
        )
        #expect(
            firstChunkPage.items.compactMap(\.id) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
            ])
        let chunkBefore = try #require(firstChunkPage.nextBefore)

        let secondChunkPage = snapshot.items(
            in: [.init(sender: sender, index: 0, endIndex: 2)],
            before: chunkBefore
        )
        #expect(
            secondChunkPage.items.compactMap(\.id) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
            ])
        #expect(secondChunkPage.nextBefore == nil)
    }

    @Test("reconcile persists and publishes each tail page before dispatching the next")
    func reconcilePersistsEveryTailPage() async throws {
        let contextID = UUID()
        let requester = UUID()
        let responder = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(node: responder)
        let messages = (1...5).map { index in
            makeMessage(
                id: String(
                    format: "00000000-0000-0000-0000-%012d",
                    index
                ),
                context: contextID,
                sender: sender,
                content: "\(index)",
                second: TimeInterval(index)
            )
        }
        let snapshot = KeepTalkingContextSyncSnapshot(
            context: contextID,
            messages: messages,
            attachments: [],
            chunkSize: 2
        )
        let state = SnapshotRestartState(chunkSize: 2)
        let steps = KeepTalkingSyncReconcile<
            KeepTalkingContextSyncTailRequest,
            KeepTalkingContextSyncTailRequest,
            KeepTalkingContextSyncMessagesResult
        >(
            localSummary: { await state.metadata() },
            remoteSummary: {
                snapshot.summary
            },
            makeTail: { local, remote in
                KeepTalkingContextSyncTailRequest(
                    context: contextID,
                    requester: requester,
                    recipient: responder,
                    local: local,
                    remote: remote
                )
            },
            dispatchTail: { request in
                await state.recordDispatch(kind: .tail, before: request.before)
                let page = snapshot.items(
                    after: request.senders,
                    before: request.before
                )
                return KeepTalkingContextSyncMessagesResult(
                    request: request.request,
                    context: contextID,
                    requester: requester,
                    responder: responder,
                    messages: page.items,
                    nextBefore: page.nextBefore
                )
            },
            makeChunk: { _, _ in nil },
            dispatchChunk: { request in
                Issue.record("Unexpected chunk request")
                return KeepTalkingContextSyncMessagesResult(
                    request: request.request,
                    context: contextID,
                    requester: requester,
                    responder: responder,
                    messages: []
                )
            },
            persist: { result in
                await state.persist(result.messages)
                await state.publish(result.messages)
            }
        )

        try await runSyncReconcile(steps)

        #expect(await state.messageIDs().count == 5)
        #expect(await state.publicationOrderingIsValid())
        #expect(await state.dispatchCount() == 3)
        #expect(await state.publicationCount() == 3)
    }

    @Test("a stalled tail falls through to mid-stream chunk repair")
    func stalledTailFallsThroughToChunkRepair() async throws {
        let contextID = UUID()
        let requester = UUID()
        let recipient = UUID()
        let sender = KeepTalkingContextMessage.Sender.node(node: UUID())
        let remoteMessages = (0..<5).map {
            makeMessage(
                id: String(
                    format: "00000000-0000-0000-0000-%012d",
                    $0 + 1
                ),
                context: contextID,
                sender: sender,
                content: String($0),
                second: TimeInterval($0)
            )
        }
        let remote = KeepTalkingContext.buildSyncMetadata(
            from: remoteMessages,
            chunkSize: 2
        )
        let localMessages = [
            remoteMessages[0],
            remoteMessages[2],
            remoteMessages[3],
            remoteMessages[4],
        ]
        let localState = LockedValue(
            Dictionary(
                uniqueKeysWithValues: localMessages.map {
                    (try! #require($0.id), $0)
                }
            )
        )
        let chunkRepairCount = LockedValue(0)
        let steps = KeepTalkingSyncReconcile<
            KeepTalkingContextSyncTailRequest,
            KeepTalkingContextSyncChunkRequest,
            KeepTalkingContextSyncMessagesResult
        >(
            localSummary: {
                KeepTalkingContext.buildSyncMetadata(
                    from: Array(localState.get().values),
                    chunkSize: 2
                )
            },
            remoteSummary: {
                remote
            },
            makeTail: { local, remote in
                KeepTalkingContextSyncTailRequest(
                    context: contextID,
                    requester: requester,
                    recipient: recipient,
                    local: local,
                    remote: remote
                )
            },
            dispatchTail: { request in
                KeepTalkingContextSyncMessagesResult(
                    request: request.request,
                    context: contextID,
                    requester: requester,
                    responder: recipient,
                    messages: [remoteMessages[4]]
                )
            },
            makeChunk: { local, remote in
                KeepTalkingContextSyncChunkRequest(
                    context: contextID,
                    requester: requester,
                    recipient: recipient,
                    local: local,
                    remote: remote
                )
            },
            dispatchChunk: { request in
                chunkRepairCount.set(chunkRepairCount.get() + 1)
                return KeepTalkingContextSyncMessagesResult(
                    request: request.request,
                    context: contextID,
                    requester: requester,
                    responder: recipient,
                    messages: [remoteMessages[1]]
                )
            },
            persist: { result in
                var messagesByID = localState.get()
                for message in result.messages {
                    messagesByID[try #require(message.id)] = message
                }
                localState.set(messagesByID)
            }
        )

        try await runSyncReconcile(steps)

        #expect(
            KeepTalkingContext.buildSyncMetadata(
                from: Array(localState.get().values),
                chunkSize: 2
            ) == remote
        )
        #expect(chunkRepairCount.get() == 1)
    }

    @Test("overlapping sync triggers share one per-peer operation")
    func overlappingSyncTriggersShareOneOperation() async {
        let singleFlight = KeepTalkingContextSyncSingleFlight()
        let counter = SingleFlightCounter()
        let peer = UUID()

        async let first: Void = singleFlight.run(for: peer) {
            await counter.run()
        }
        async let second: Void = singleFlight.run(for: peer) {
            await counter.run()
        }
        _ = await (first, second)

        #expect(await counter.value() == 1)
    }

    @Test("a reconnect waits for its cancelled peer sync to drain")
    func reconnectWaitsForCancelledSingleFlight() async {
        let singleFlight = KeepTalkingContextSyncSingleFlight()
        let probe = SingleFlightBarrierProbe()
        let peer = UUID()

        let stale = Task {
            await singleFlight.run(for: peer) {
                await probe.blockFirstRun()
            }
        }
        while await probe.value() == 0 {
            await Task.yield()
        }

        singleFlight.cancelAll()
        singleFlight.open(generation: 2)
        await singleFlight.run(for: peer, generation: 1) {
            await probe.increment()
        }
        #expect(await probe.value() == 1)

        let freshStarted = LockedValue(false)
        let fresh = Task {
            freshStarted.set(true)
            await singleFlight.run(for: peer, generation: 2) {
                await probe.increment()
            }
        }
        while !freshStarted.get() {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(await probe.value() == 1)

        await probe.releaseFirstRun()
        await stale.value
        await fresh.value

        #expect(await probe.value() == 2)
    }

    @Test("incoming sync skips messages that already exist locally")
    func saveIncomingMessagesSkipsExistingRows() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
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
            messages: [
                makeMessage(
                    id: "00000000-0000-0000-0000-000000000401",
                    context: config.contextID,
                    sender: sender,
                    content: "one",
                    second: 1
                )
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

        #expect(
            storedMessages.compactMap(\.id) == [
                UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            ])
        #expect(storedMessages.map(\.content) == ["one", "two"])

        #expect(storedMessages.count == 2)
    }

    @Test("incoming attachment dto creates a pending attachment placeholder")
    func saveIncomingAttachmentDTOCreatesPlaceholder() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
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

    @Test("incoming parentless attachment dto creates a context attachment placeholder")
    func saveIncomingParentlessAttachmentDTOCreatesPlaceholder() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
            contextID: UUID(uuidString: "82000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "AAAAAAAA-9999-9999-9999-999999999999")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )

        let sender = KeepTalkingContextMessage.Sender.node(
            node: UUID(uuidString: "BBBBBBBB-9999-9999-9999-999999999999")!
        )
        let attachmentID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000512"
        )!

        let attachments = try await client.saveIncomingAttachments(
            [
                KeepTalkingContextAttachmentDTO(
                    id: attachmentID,
                    contextID: config.contextID,
                    parentMessageID: nil,
                    sender: sender,
                    blobID: String(repeating: "e", count: 64),
                    filename: "fulfilled.pdf",
                    mimeType: "application/pdf",
                    byteCount: 4321,
                    sortIndex: 0
                )
            ]
        )

        #expect(attachments.count == 1)
        #expect(attachments.first?.$parentMessage.id == nil)
        #expect(attachments.first?.sender == sender)
        #expect(attachments.first?.$context.id == config.contextID)

        let storedAttachment = try #require(
            try await KeepTalkingContextAttachment.query(on: localStore.database)
                .filter(\.$id, .equal, attachmentID)
                .first()
        )
        #expect(storedAttachment.filename == "fulfilled.pdf")
        #expect(storedAttachment.$parentMessage.id == nil)

        let blobRecord = try #require(
            try await KeepTalkingBlobRecord.query(on: localStore.database)
                .filter(\.$id, .equal, attachments[0].blobID)
                .first()
        )
        #expect(blobRecord.availability == .missing)
        #expect(blobRecord.byteCount == 4321)
    }

    @Test("summary wait resolves when the reply arrives immediately during send")
    func immediateSummaryReplyDoesNotRaceThePendingWait() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
            contextID: UUID(uuidString: "90000000-0000-0000-0000-000000000000")!,
            node: UUID(uuidString: "CCCCCCCC-9999-9999-9999-999999999999")!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )
        let request = UUID(uuidString: "00000000-0000-0000-0000-000000000999")!
        let summary = KeepTalkingContextSyncMetadata(
            chunkSize: 64,
            messageCount: 0,
            senders: [],
            chunks: []
        )
        let expected = KeepTalkingContextSyncSummaryResult(
            request: request,
            context: config.contextID,
            requester: config.node,
            responder: UUID(uuidString: "DDDDDDDD-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            summary: summary
        )

        let result = try await client.syncSummaries.response(
            for: request,
            timeout: 0.2,
            send: {
                #expect(client.syncSummaries.resolve(request, with: expected))
            }
        )

        #expect(result == expected)
    }

    @Test("peer failure terminates a response wait without timing out")
    func peerFailureTerminatesResponseWait() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
            contextID: UUID(
                uuidString: "91000000-0000-0000-0000-000000000000"
            )!,
            node: UUID(
                uuidString: "CCCCCCCC-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!
        )
        let client = KeepTalkingClient(
            config: config,
            localStore: localStore
        )
        let request = UUID(
            uuidString: "00000000-0000-0000-0000-000000000998"
        )!
        let failure = KeepTalkingContextSyncFailureResult(
            request: request,
            context: config.contextID,
            requester: config.node,
            responder: UUID(
                uuidString: "DDDDDDDD-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
            )!,
            message: "snapshot unavailable"
        )
        let didSend = LockedValue(false)
        let response = Task {
            try await client.syncSummaries.response(
                for: request,
                timeout: 1,
                send: { didSend.set(true) }
            )
        }
        while !didSend.get() {
            await Task.yield()
        }

        try await client.handleIncomingContextSyncEnvelope(
            .failureResult(failure)
        )

        do {
            _ = try await response.value
            Issue.record("Peer failure unexpectedly resolved as a summary.")
        } catch KeepTalkingClientError.contextSyncRemoteFailure(
            let receivedRequest,
            let receivedResponder,
            let receivedMessage
        ) {
            #expect(receivedRequest == failure.request)
            #expect(receivedResponder == failure.responder)
            #expect(receivedMessage == failure.message)
        } catch {
            Issue.record("Unexpected peer failure error: \(error)")
        }
    }

    @Test("cancelling a response wait drains its continuation")
    func cancellingResponseWaitDrainsContinuation() async {
        let registry = KeepTalkingSyncResponseRegistry<Int>()
        let request = UUID()
        let didSend = LockedValue(false)
        let task = Task {
            try await registry.response(
                for: request,
                timeout: 30,
                send: { didSend.set(true) }
            )
        }
        while !didSend.get() {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancelled response unexpectedly succeeded.")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(!registry.resolve(request, with: 1))
    }

    @Test("a synchronous response send failure returns immediately")
    func synchronousResponseSendFailureReturnsImmediately() async {
        let registry = KeepTalkingSyncResponseRegistry<Int>()

        do {
            _ = try await registry.response(
                for: UUID(),
                timeout: 30,
                send: { throw ExpectedSyncTestError.sendFailed }
            )
            Issue.record("Throwing send unexpectedly succeeded.")
        } catch ExpectedSyncTestError.sendFailed {
        } catch {
            Issue.record("Unexpected send error: \(error)")
        }
    }

    @Test("a response registry rejects closed and stale-generation work")
    func responseRegistryRejectsStaleLifecycleWork() async {
        let registry = KeepTalkingSyncResponseRegistry<Int>()
        let didSend = LockedValue(false)
        registry.close(error: KeepTalkingClientError.clientDisconnected)

        do {
            _ = try await registry.response(
                for: UUID(),
                timeout: 30,
                send: { didSend.set(true) }
            )
            Issue.record("Closed response registry unexpectedly accepted work.")
        } catch KeepTalkingClientError.clientDisconnected {
        } catch {
            Issue.record("Unexpected closed-registry error: \(error)")
        }

        #expect(!didSend.get())

        registry.open(generation: 2)
        do {
            _ = try await registry.response(
                for: UUID(),
                timeout: 30,
                generation: 1,
                send: { didSend.set(true) }
            )
            Issue.record("Stale response generation unexpectedly sent work.")
        } catch KeepTalkingClientError.clientDisconnected {
        } catch {
            Issue.record("Unexpected stale-generation error: \(error)")
        }

        #expect(!didSend.get())

        let currentRequest = UUID()
        do {
            let value = try await registry.response(
                for: currentRequest,
                timeout: 30,
                generation: 2,
                send: {
                    #expect(registry.resolve(currentRequest, with: 7))
                }
            )
            #expect(value == 7)
        } catch {
            Issue.record("Current response generation failed: \(error)")
        }
    }

    @Test("a timed-out response drains its continuation")
    func timedOutResponseDrainsContinuation() async {
        let registry = KeepTalkingSyncResponseRegistry<Int>()
        let request = UUID()

        do {
            _ = try await registry.response(
                for: request,
                timeout: 0.01,
                send: {}
            )
            Issue.record("Timed-out response unexpectedly succeeded.")
        } catch KeepTalkingClientError.contextSyncTimeout(let timedOutRequest) {
            #expect(timedOutRequest == request)
        } catch {
            Issue.record("Unexpected timeout error: \(error)")
        }
        #expect(!registry.resolve(request, with: 1))
    }

    @Test("attachment sync request includes only recent missing hashes")
    func attachmentRequestReturnsRecentMissingHashes() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let config = KeepTalkingConfig(
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

private actor ContextSyncEventRecorder {
    private var recordedEvents: [KeepTalkingContextSyncEvent] = []

    func append(_ event: KeepTalkingContextSyncEvent) {
        recordedEvents.append(event)
    }

    func events() -> [KeepTalkingContextSyncEvent] {
        recordedEvents
    }
}

private enum SnapshotSyncPageKind: Sendable, Equatable {
    case tail
    case chunk
}

private enum SnapshotRestartTraceEntry: Sendable, Equatable {
    case dispatch(
        kind: SnapshotSyncPageKind,
        before: KeepTalkingContextSyncPageKey?
    )
    case persist([UUID])
    case publish([UUID])
}

private actor SnapshotRestartState {
    private let chunkSize: Int
    private var messagesByID: [UUID: KeepTalkingContextMessage] = [:]
    private var persistedTotal = 0
    private var publishedPages: [[UUID]] = []
    private var entries: [SnapshotRestartTraceEntry] = []

    init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }

    func metadata() -> KeepTalkingContextSyncMetadata {
        KeepTalkingContext.buildSyncMetadata(
            from: Array(messagesByID.values),
            chunkSize: chunkSize
        )
    }

    func recordDispatch(
        kind: SnapshotSyncPageKind,
        before: KeepTalkingContextSyncPageKey?
    ) {
        entries.append(.dispatch(kind: kind, before: before))
    }

    func persist(_ messages: [KeepTalkingContextMessage]) {
        let ids = messages.compactMap(\.id)
        persistedTotal += ids.count
        for message in messages {
            guard let id = message.id else { continue }
            messagesByID[id] = message
        }
        entries.append(.persist(ids))
    }

    func publish(_ messages: [KeepTalkingContextMessage]) {
        let ids = messages.compactMap(\.id)
        publishedPages.append(ids)
        entries.append(.publish(ids))
    }

    func firstPublishedIDs() -> [UUID]? {
        publishedPages.first
    }

    func persistedMessageCount() -> Int {
        persistedTotal
    }

    func messageIDs() -> Set<UUID> {
        Set(messagesByID.keys)
    }

    func dispatchCount() -> Int {
        entries.reduce(into: 0) { count, entry in
            if case .dispatch = entry {
                count += 1
            }
        }
    }

    func publicationCount() -> Int {
        publishedPages.count
    }

    func publicationOrderingIsValid() -> Bool {
        for (index, entry) in entries.enumerated() {
            switch entry {
                case .persist(let ids):
                    guard
                        entries.indices.contains(index + 1),
                        entries[index + 1] == .publish(ids)
                    else {
                        return false
                    }
                case .publish(let ids):
                    guard
                        index > entries.startIndex,
                        entries[index - 1] == .persist(ids)
                    else {
                        return false
                    }
                case .dispatch:
                    continue
            }
        }
        return true
    }
}

private actor SingleFlightCounter {
    var count = 0
    let delay: Duration

    init(delay: Duration = .milliseconds(50)) {
        self.delay = delay
    }

    func run() async {
        count += 1
        try? await Task.sleep(for: delay)
    }

    func value() -> Int {
        count
    }
}

private actor SingleFlightBarrierProbe {
    private var count = 0
    private var firstRunContinuation: CheckedContinuation<Void, Never>?

    func blockFirstRun() async {
        count += 1
        await withCheckedContinuation {
            firstRunContinuation = $0
        }
    }

    func releaseFirstRun() {
        firstRunContinuation?.resume()
        firstRunContinuation = nil
    }

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private enum ExpectedSyncTestError: Error {
    case sendFailed
}
