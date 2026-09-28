import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Message deletion: a grow-only tombstone set on the context, merged by union.
///
/// Threading is checked through the real derive path
/// (`turningPointMarkThreading`) on both ends rather than hand-built DTOs — the
/// producer↔consumer agreement is where every live threading failure lived.
struct MessageDeletionTests {
    private struct Node {
        let store: KeepTalkingInMemoryStore
        let client: KeepTalkingClient
        let context: KeepTalkingContext
        let nodeID: UUID
    }

    private let contextID = UUID()

    private func makeNode() async throws -> Node {
        let store = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: store.database)
        let nodeID = UUID()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            localStore: store
        )
        return Node(store: store, client: client, context: context, nodeID: nodeID)
    }

    /// Seeds `count` messages at timestamps 1…count with the given ids.
    private func seed(_ node: Node, ids: [UUID], skipping skipped: Set<Int> = []) async throws {
        for (index, id) in ids.enumerated() where !skipped.contains(index) {
            try await KeepTalkingContextMessage(
                id: id,
                context: node.context,
                sender: .node(node: node.nodeID),
                content: "m\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ).save(on: node.store.database)
        }
    }

    /// Stores a turning-point mark ahead of every message, so mark rows sit in
    /// the leading thread and stay out of the ranges under test.
    private func mark(
        _ node: Node,
        id: UUID = UUID(),
        target: UUID,
        previous: String?,
        current: String,
        at timestamp: TimeInterval
    ) async throws {
        try await KeepTalkingContextMessage(
            id: id,
            context: node.context,
            sender: .node(node: node.nodeID),
            content: "",
            timestamp: Date(timeIntervalSince1970: timestamp),
            type: .markTurningPoint(
                messageID: target,
                previousTopicName: previous,
                currentTopicName: current
            )
        ).save(on: node.store.database)
    }

    private func threads(_ node: Node) async throws -> [KeepTalkingThread] {
        try await node.client.threads(for: contextID)
    }

    private func boundaries(_ node: Node) async throws -> [UUID: (
        start: UUID?, end: UUID?, state: KeepTalkingThreadState
    )] {
        var result: [UUID: (start: UUID?, end: UUID?, state: KeepTalkingThreadState)] = [:]
        for thread in try await threads(node) {
            result[thread.id!] = (thread.$startMessage.id, thread.$endMessage.id, thread.state)
        }
        return result
    }

    private func messageIDs(_ node: Node) async throws -> Set<UUID> {
        Set(
            try await KeepTalkingContextMessage.query(on: node.store.database)
                .filter(\.$context.$id == contextID)
                .all()
                .compactMap(\.id)
        )
    }

    /// Page fetches answered directly by `responder`, standing in for transport.
    private func pages(from responder: Node) -> KeepTalkingContextSyncSetPages {
        let client = responder.client
        return KeepTalkingContextSyncSetPages(
            sideNotes: { try await client.executeSideNotesPageRequest($0) },
            messageDeletions: { try await client.executeMessageDeletionsPageRequest($0) }
        )
    }

    /// One sync round, `requester` pulling from `responder`: the summary
    /// exchange with its whole sets, a stand-in for the message reconcile
    /// (every responder row offered to intake), then what a completed sync
    /// does to threading.
    @discardableResult
    private func sync(_ requester: Node, from responder: Node) async throws -> KeepTalkingContextSyncSummaryResult {
        let result = try await responder.client.executeContextSyncSummaryRequest(
            KeepTalkingContextSyncSummaryRequest(
                context: contextID,
                requester: requester.nodeID,
                recipient: responder.nodeID,
                sideNoteDigest: try await requester.client.sideNoteDigest(in: contextID),
                messageDeletionDigest: try await requester.client.messageDeletionDigest(in: contextID)
            )
        )
        try await requester.client.absorbSummarySets(
            result,
            pages: pages(from: responder)
        )
        let offered = try await KeepTalkingContextMessage.query(on: responder.store.database)
            .filter(\.$context.$id == contextID)
            .all()
            .map {
                KeepTalkingContextMessage(
                    id: $0.id!,
                    context: requester.context,
                    sender: $0.sender,
                    content: $0.content,
                    timestamp: $0.timestamp,
                    type: $0.type,
                    agentTurnID: $0.agentTurnID
                )
            }
        try await requester.client.saveIncomingMessages(offered, in: contextID)
        try await requester.client.threadAfterSync(in: contextID)
        return result
    }

    // MARK: - Thread boundaries

    @Test("deleting a turning-point message keeps every thread and its UUID")
    func turningPointDeletionKeepsThreadIdentity() async throws {
        let node = try await makeNode()
        let ids = (0..<10).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 0.5)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 0.6)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let before = try await boundaries(node)
        #expect(before.count == 3)

        try await node.client.deleteMessages([ids[3]], in: contextID)

        let after = try await boundaries(node)
        #expect(Set(after.keys) == Set(before.keys))
        let middle = try #require(after.values.first { $0.start == ids[4] })
        #expect(middle.end == ids[6])
        #expect(middle.state == .stored)
        #expect(after.values.contains { $0.end == ids[2] })
        #expect(after.values.contains { $0.start == ids[7] && $0.end == nil })
        #expect(!(try await messageIDs(node)).contains(ids[3]))
    }

    @Test("a peer that never held the deleted message derives the same projection")
    func peerWithoutDeletedMessageDerivesSameProjection() async throws {
        let deleter = try await makeNode()
        let peer = try await makeNode()
        let ids = (0..<10).map { _ in UUID() }
        let marks = (UUID(), UUID())
        try await seed(deleter, ids: ids)
        try await seed(peer, ids: ids, skipping: [3])
        for node in [deleter, peer] {
            try await mark(node, id: marks.0, target: ids[3], previous: "First", current: "Middle", at: 0.5)
            try await mark(node, id: marks.1, target: ids[7], previous: "Middle", current: "Last", at: 0.6)
        }

        try await deleter.client.deleteMessages([ids[3]], in: contextID)
        try await sync(peer, from: deleter)

        let expected = try await deleter.client.turningPointMarkThreading(in: contextID)
        #expect(try await peer.client.turningPointMarkThreading(in: contextID) == expected)
        #expect(expected.map(\.startMessageID) == [marks.0, ids[4], ids[7]])
        #expect(expected.map(\.topicName) == ["First", "Middle", "Last"])
    }

    @Test("deleting a thread's every message removes it and its predecessor goes live")
    func emptiedLiveThreadHandsOffToPredecessor() async throws {
        let node = try await makeNode()
        let ids = (0..<10).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[7], previous: "Before", current: "After", at: 0.5)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let before = try await boundaries(node)
        let leading = try #require(before.first { $0.value.state == .stored }?.key)

        try await node.client.deleteMessages([ids[7], ids[8], ids[9]], in: contextID)

        let after = try await boundaries(node)
        #expect(Array(after.keys) == [leading])
        #expect(after[leading]?.end == nil)
        #expect(after[leading]?.state == .contextMain)
    }

    @Test("deleting a stored thread's end moves the end back and keeps it stored")
    func storedThreadEndShrinksBack() async throws {
        let node = try await makeNode()
        let ids = (0..<10).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 0.5)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 0.6)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let middleID = try #require(try await boundaries(node).first { $0.value.start == ids[3] }?.key)

        try await node.client.deleteMessages([ids[6]], in: contextID)

        let middle = try #require(try await boundaries(node)[middleID])
        #expect(middle.start == ids[3])
        #expect(middle.end == ids[5])
        #expect(middle.state == .stored)
    }

    @Test("marks collapsing onto one message keep the closing and opening names apart")
    func collapsedMarksMergeByOriginalPosition() async throws {
        let node = try await makeNode()
        let ids = (0..<10).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 0.5)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 0.6)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)

        // The whole middle thread goes: both marks now land on m7.
        try await node.client.deleteMessages(Array(ids[3...6]), in: contextID)

        let projection = try await node.client.turningPointMarkThreading(in: contextID)
        #expect(projection.map(\.topicName) == ["First", "Last"])
        #expect(projection.last?.startMessageID == ids[7])
        #expect(try await threads(node).count == 2)
    }

    // MARK: - Agent turns

    @Test("a whole-turn deletion takes every row of the turn and nothing else")
    func agentTurnDeletionTakesItsTurn() async throws {
        let node = try await makeNode()
        let turn = UUID()
        let otherTurn = UUID()
        let ai = KeepTalkingContextMessage.Sender.autonomous(name: "ai", node: node.nodeID)
        func row(
            _ second: TimeInterval,
            _ sender: KeepTalkingContextMessage.Sender,
            _ type: KeepTalkingContextMessage.MessageType = .message,
            turn agentTurnID: UUID?
        ) async throws -> UUID {
            let id = UUID()
            try await KeepTalkingContextMessage(
                id: id, context: node.context, sender: sender, content: "r\(second)",
                timestamp: Date(timeIntervalSince1970: second), type: type,
                agentTurnID: agentTurnID
            ).save(on: node.store.database)
            return id
        }
        let before = try await row(1, .node(node: node.nodeID), turn: nil)
        let prompt = try await row(2, .node(node: node.nodeID), turn: turn)
        let thinking = try await row(3, ai, .thinking, turn: turn)
        let toolCall = try await row(3.5, ai, .intermediate(hint: "Inspecting"), turn: turn)
        let reply = try await row(4, ai, turn: turn)
        let haywire = try await row(4.2, ai, .haywire(reason: .failed), turn: turn)
        let otherPrompt = try await row(5, .node(node: node.nodeID), turn: otherTurn)
        let otherReply = try await row(6, ai, turn: otherTurn)
        try await mark(node, target: prompt, previous: nil, current: "Topic", at: 4.5)

        // By default only the named row goes, even from inside a turn.
        #expect(try await node.client.deleteMessages([toolCall], in: contextID) == [toolCall])

        let deleted = try await node.client.deleteMessages([reply], in: contextID, scope: .agentTurns)

        let wholeTurn: Set<UUID> = [prompt, thinking, toolCall, reply, haywire]
        #expect(Set(deleted) == wholeTurn.subtracting([toolCall]))
        let remaining = try await messageIDs(node)
        #expect(remaining.isSuperset(of: [before, otherPrompt, otherReply]))
        #expect(remaining.isDisjoint(with: wholeTurn))
        // The turn's mark is not part of the turn; only its target went.
        #expect(remaining.count == 4)

        // A prompt belongs to its turn too, so from it the whole turn goes.
        #expect(
            Set(try await node.client.deleteMessages([otherPrompt], in: contextID, scope: .agentTurns))
                == [otherPrompt, otherReply])
    }

    // MARK: - Sync

    @Test("a deleted message is not synced back, and the peer deletes it too")
    func deletionSurvivesSyncBothWays() async throws {
        let a = try await makeNode()
        let b = try await makeNode()
        let ids = (0..<5).map { _ in UUID() }
        try await seed(a, ids: ids)
        try await seed(b, ids: ids)

        try await a.client.deleteMessages([ids[2]], in: contextID)

        // A pulls from B, which still holds the row: intake refuses it.
        try await sync(a, from: b)
        #expect(!(try await messageIDs(a)).contains(ids[2]))

        // B pulls from A and learns the tombstone.
        try await sync(b, from: a)
        #expect(!(try await messageIDs(b)).contains(ids[2]))
        #expect(
            try await a.client.messageDeletionDigest(in: contextID)
                == (try await b.client.messageDeletionDigest(in: contextID))
        )
    }

    @Test("a tombstone that arrives first blocks the message and its attachments")
    func earlyTombstoneBlocksIntake() async throws {
        let node = try await makeNode()
        let doomed = UUID()
        try await node.client.mergeMessageDeletions(
            [KeepTalkingMessageTombstone(messageID: doomed, timestamp: Date(timeIntervalSince1970: 5))],
            contextID: contextID
        )

        let saved = try await node.client.saveIncomingMessages(
            [
                KeepTalkingContextMessage(
                    id: doomed, context: node.context, sender: .node(node: UUID()),
                    content: "late", timestamp: Date(timeIntervalSince1970: 5))
            ],
            in: contextID
        )
        let attachments = try await node.client.saveIncomingAttachments([
            KeepTalkingContextAttachmentDTO(
                id: UUID(), contextID: contextID, parentMessageID: doomed,
                sender: .node(node: UUID()), blobID: String(repeating: "d", count: 64),
                filename: "late.png", mimeType: "image/png", byteCount: 1,
                createdAt: Date(timeIntervalSince1970: 5), sortIndex: 0)
        ])

        #expect(saved == false)
        #expect(attachments.isEmpty)
        #expect(try await messageIDs(node).isEmpty)
    }

    @Test("a blob shared by two messages outlives deleting one of them")
    func sharedBlobPrunedOnlyWithLastReference() async throws {
        let node = try await makeNode()
        let ids = (0..<2).map { _ in UUID() }
        try await seed(node, ids: ids)
        let blobID = String(repeating: "c", count: 64)
        try await KeepTalkingBlobRecord(
            blobID: blobID, availability: .ready, mimeType: "image/png",
            byteCount: 1, receivedBytes: 1
        ).save(on: node.store.database)
        for (index, id) in ids.enumerated() {
            try await KeepTalkingContextAttachment(
                id: UUID(), context: node.context, parentMessageID: id,
                sender: .node(node: node.nodeID), blobID: blobID,
                filename: "shared-\(index).png", mimeType: "image/png", byteCount: 1,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)), sortIndex: 0
            ).save(on: node.store.database)
        }
        func blobExists() async throws -> Bool {
            try await KeepTalkingBlobRecord.find(blobID, on: node.store.database) != nil
        }

        try await node.client.deleteMessages([ids[0]], in: contextID)
        #expect(try await blobExists())

        try await node.client.deleteMessages([ids[1]], in: contextID)
        #expect(try await blobExists() == false)
    }

    // MARK: - Set paging

    @Test("a tombstone set spanning several pages converges whole")
    func pagedTombstonesConverge() async throws {
        let a = try await makeNode()
        let b = try await makeNode()
        let tombstones = (0..<150).map {
            KeepTalkingMessageTombstone(messageID: UUID(), timestamp: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        try await a.client.mergeMessageDeletions(tombstones, contextID: contextID)

        let result = try await sync(b, from: a)

        #expect(result.messageDeletionsNextBefore != nil)
        #expect(try await b.client.messageTombstones(in: contextID) == tombstones)
    }

    @Test("a side-note set spanning several pages converges to one digest")
    func pagedSideNotesConverge() async throws {
        let a = try await makeNode()
        let b = try await makeNode()
        let value = String(repeating: "v", count: KeepTalkingSideNoteLimits.maximumValueBytes)
        for index in 0..<KeepTalkingSideNoteLimits.maximumLiveNotes {
            try await a.client.upsertSideNote(key: "note-\(index)", value: value, in: contextID)
        }
        for index in 0..<4 {
            try await a.client.archiveSideNote(key: "note-\(index)", in: contextID)
        }

        let result = try await sync(b, from: a)

        #expect(result.sideNotesNextBefore != nil)
        #expect(
            try await b.client.sideNoteDigest(in: contextID)
                == (try await a.client.sideNoteDigest(in: contextID))
        )
    }

    @Test("a responder repeating its cursor fails instead of spinning")
    func repeatedCursorFailsWithNoProgress() async throws {
        let cursor = KeepTalkingContextSyncPageKey(timestamp: Date(timeIntervalSince1970: 1), id: UUID())
        await #expect(throws: KeepTalkingSyncReconcileError.self) {
            _ = try await collectSyncSetPages(
                firstPage: [KeepTalkingMessageTombstone](),
                nextBefore: cursor,
                request: {
                    KeepTalkingContextSyncMessageDeletionsPageRequest(
                        context: UUID(), requester: UUID(), recipient: UUID(), before: $0)
                },
                dispatch: { request in
                    KeepTalkingContextSyncMessageDeletionsPageResult(
                        request: request.request, context: request.context,
                        requester: request.requester, responder: UUID(),
                        items: [], nextBefore: request.before
                    )
                }
            )
        }
    }
}
