import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// The thread rows of a context partition its message list: every thread
/// resolves, the ranges are contiguous and never overlap, and exactly one —
/// the last — is live.
///
/// Each test drives a path that reached the live database with a second live
/// thread, and checks the invariant rather than one boundary, since an
/// overlap is whatever the next row happens to cover.
struct ThreadPartitionTests {
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

    /// Seeds messages at timestamps 1…count with the given ids.
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

    /// Stores a turning-point mark after every seeded message, as the agent
    /// stores one mid-turn.
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

    /// The thread rows as the timeline lays them out, against every row of the
    /// context in the derivation's `(timestamp, id)` order.
    private struct Layout {
        /// Start of each resolvable thread, in timeline order.
        var starts: [UUID?]
        var liveCount: Int
        var unresolvedCount: Int
        /// Contiguous, gap-free cover of the whole context, the live thread last.
        var isPartition: Bool
    }

    private func layout(_ node: Node) async throws -> Layout {
        let messages = try await KeepTalkingContextMessage.query(on: node.store.database)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        let rows = try await threads(node)
        let resolved =
            rows
            .compactMap { thread in thread.resolvedMessageRange(in: messages).map { (thread, $0) } }
            .sorted { $0.1.lowerBound < $1.1.lowerBound }

        var isPartition =
            resolved.count == rows.count
            && resolved.first?.1.lowerBound == 0
            && resolved.last?.1.upperBound == messages.count - 1
            && resolved.last?.0.state == .contextMain
        for (previous, next) in zip(resolved, resolved.dropFirst())
        where next.1.lowerBound != previous.1.upperBound + 1 {
            isPartition = false
        }
        return Layout(
            starts: resolved.map { $0.0.$startMessage.id },
            liveCount: rows.filter { $0.state == .contextMain }.count,
            unresolvedCount: rows.count - resolved.count,
            isPartition: isPartition
        )
    }

    /// Each thread's derived name, in timeline order.
    private func names(_ node: Node) async throws -> [String?] {
        let messages = try await KeepTalkingContextMessage.query(on: node.store.database)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        return try await threads(node)
            .compactMap { thread in thread.resolvedMessageRange(in: messages).map { ($0.lowerBound, thread.summary) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    private func row(_ node: Node, startingAt messageID: UUID) async throws -> KeepTalkingThread {
        try #require(try await threads(node).first { $0.$startMessage.id == messageID })
    }

    private func pages(from responder: Node) -> KeepTalkingContextSyncSetPages {
        let client = responder.client
        return KeepTalkingContextSyncSetPages(
            sideNotes: { try await client.executeSideNotesPageRequest($0) },
            messageDeletions: { try await client.executeMessageDeletionsPageRequest($0) }
        )
    }

    /// One sync round, `requester` pulling from `responder`: the summary
    /// exchange, a stand-in for the message reconcile, then what
    /// `performContextSync` does once every page has landed.
    private func sync(_ requester: Node, from responder: Node) async throws {
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
    }

    // MARK: - Live threads minted outside the derivation

    @Test("a live thread ensured on an empty context is not left beside the derived one")
    func liveThreadEnsuredBeforeFirstMessage() async throws {
        let node = try await makeNode()
        // Opening a new context's chat ensures a live thread before any
        // message exists, so it has no start.
        try await node.client.ensureContextMainThread(for: contextID)
        let ids = (0..<6).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Second", at: 100)

        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)

        let layout = try await layout(node)
        #expect(layout.liveCount == 1)
        #expect(layout.unresolvedCount == 0)
        #expect(layout.isPartition)
        #expect(layout.starts == [ids[0], ids[3]])
    }

    @Test("a live thread ensured over a partial history does not outlive the full sync")
    func liveThreadEnsuredMidSync() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let full = try await makeNode()
        try await seed(full, ids: ids)
        try await mark(full, target: ids[3], previous: "First", current: "Second", at: 100)
        try await full.client.applyLocalTurningPointMarkThreading(in: contextID)

        // Pages land newest-first: only the suffix is here when something
        // (an action run's workspace, the chat opening) ensures a live thread.
        let joiner = try await makeNode()
        try await seed(joiner, ids: ids, skipping: Set(0..<5))
        try await joiner.client.ensureContextMainThread(for: contextID)

        try await sync(joiner, from: full)

        let layout = try await layout(joiner)
        #expect(layout.liveCount == 1)
        #expect(layout.isPartition)
        #expect(layout.starts == [ids[0], ids[3]])
    }

    // MARK: - Projections that disagree with local rows

    @Test("pulling from a peer that lacks a newer mark keeps this node's threading")
    func stalePeerProjectionDoesNotRegress() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let marker = try await makeNode()
        let peer = try await makeNode()
        let sharedMark = UUID()
        for node in [marker, peer] {
            try await seed(node, ids: ids)
            try await mark(node, id: sharedMark, target: ids[3], previous: "First", current: "Middle", at: 100)
            try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        }
        // The marker's agent marks again; the peer has not pulled it yet —
        // and the marker's heartbeat pulls from the peer first.
        try await mark(marker, target: ids[8], previous: "Middle", current: "Last", at: 200)
        try await marker.client.applyLocalTurningPointMarkThreading(in: contextID)
        let liveThread = try #require(try await threads(marker).first { $0.state == .contextMain }?.id)

        try await sync(marker, from: peer)

        let layout = try await layout(marker)
        #expect(layout.liveCount == 1)
        #expect(layout.isPartition)
        #expect(layout.starts == [ids[0], ids[3], ids[8]])
        // The live thread keeps the UUID its workspace and semantic document hang on.
        #expect(try await threads(marker).first { $0.state == .contextMain }?.id == liveThread)
    }

    @Test("rows split outside the turning points heal to one partition on the next sync")
    func rowLevelSplitHealsOnSync() async throws {
        let ids = (0..<8).map { _ in UUID() }
        let node = try await makeNode()
        let peer = try await makeNode()
        try await seed(node, ids: ids)
        try await seed(peer, ids: ids)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)

        // What the app's split used to do to the rows, before hand-made
        // turning points were marks: a stored thread for the earlier half,
        // and the live thread's start slid forward.
        let live = try #require(try await threads(node).first { $0.state == .contextMain })
        let earlier = KeepTalkingThread(
            context: node.context,
            startMessage: nil,
            endMessage: nil,
            state: .stored
        )
        earlier.$startMessage.id = ids[0]
        earlier.$endMessage.id = ids[4]
        try await earlier.save(on: node.store.database)
        live.$startMessage.id = ids[5]
        try await live.save(on: node.store.database)

        // The next heartbeat pulls from a peer that has no turning points.
        try await sync(node, from: peer)

        let layout = try await layout(node)
        #expect(layout.liveCount == 1)
        #expect(layout.isPartition)
        // The live thread keeps its row, and with it its workspace.
        #expect(try await threads(node).map(\.id) == [live.id])
    }

    @Test("concurrent applies of one projection write one row per thread")
    func concurrentAppliesDoNotDuplicateRows() async throws {
        let node = try await makeNode()
        let ids = (0..<6).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Second", at: 100)
        let projection = try await node.client.turningPointMarkThreading(in: contextID)

        // Two syncs finishing together, or a sync and a local mark.
        async let first = node.client.applyTurningPointMarkThreading(projection, in: contextID)
        async let second = node.client.applyTurningPointMarkThreading(projection, in: contextID)
        _ = try await (first, second)

        #expect(try await threads(node).count == 2)
        #expect(try await layout(node).isPartition)
    }

    // MARK: - Turning points made by hand

    @Test("a hand-made turning point survives the next sync and threads the peer the same way")
    func handMadeTurningPointTravels() async throws {
        let ids = (0..<8).map { _ in UUID() }
        let node = try await makeNode()
        let peer = try await makeNode()
        try await seed(node, ids: ids)
        try await seed(peer, ids: ids)

        #expect(
            try await node.client.markTurningPoint(
                at: ids[5], previousTopicName: "Setup", currentTopicName: "Follow-up", in: contextID))
        // Marking an existing boundary again splits nothing.
        #expect(try await node.client.markTurningPoint(at: ids[5], in: contextID) == false)

        // The node's heartbeat pulls from a peer that hasn't seen the mark.
        try await sync(node, from: peer)
        #expect(try await layout(node).starts == [ids[0], ids[5]])

        try await sync(peer, from: node)
        let peerLayout = try await layout(peer)
        #expect(peerLayout.isPartition)
        #expect(peerLayout.starts == [ids[0], ids[5]])
        #expect(try await names(peer) == ["Setup", "Follow-up"])
    }

    @Test("removing a turning point folds its thread into the one before, on every node")
    func removingTurningPointFolds() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let node = try await makeNode()
        let peer = try await makeNode()
        let marks = (UUID(), UUID())
        for each in [node, peer] {
            try await seed(each, ids: ids)
            try await mark(each, id: marks.0, target: ids[3], previous: "First", current: "Middle", at: 100)
            try await mark(each, id: marks.1, target: ids[7], previous: "Middle", current: "Last", at: 200)
            try await each.client.applyLocalTurningPointMarkThreading(in: contextID)
        }
        // A later, superseded mark on the same message: left behind, it would
        // reopen the thread.
        try await mark(node, target: ids[3], previous: nil, current: "Middle, again", at: 150)
        let leading = try await row(node, startingAt: ids[0])

        try await node.client.removeTurningPoint(at: ids[3], in: contextID)

        let folded = try await layout(node)
        #expect(folded.isPartition)
        #expect(folded.starts == [ids[0], ids[7]])
        #expect(try await row(node, startingAt: ids[0]).id == leading.id)

        try await sync(peer, from: node)
        #expect(try await layout(peer).starts == [ids[0], ids[7]])
    }

    @Test("folding the live thread keeps its row, and with it its workspace")
    func foldingLiveThreadKeepsItsRow() async throws {
        let ids = (0..<8).map { _ in UUID() }
        let node = try await makeNode()
        try await seed(node, ids: ids)
        try await mark(node, target: ids[4], previous: "Before", current: "After", at: 100)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let live = try await row(node, startingAt: ids[4])

        try await node.client.removeTurningPoint(at: ids[4], in: contextID)

        let rows = try await threads(node)
        #expect(rows.map(\.id) == [live.id])
        #expect(rows.first?.$startMessage.id == ids[0])
        #expect(rows.first?.state == .contextMain)
    }

    @Test("moving a turning point keeps the thread's row and its local name")
    func movingTurningPointKeepsRow() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let node = try await makeNode()
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 100)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 200)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let middle = try await row(node, startingAt: ids[3])
        let middleID = try #require(middle.id)
        try await KeepTalkingClient.setAlias("Renamed", for: .thread(middleID), on: node.store.database)

        try await node.client.moveTurningPoint(from: ids[3], to: ids[5], in: contextID)

        let layout = try await layout(node)
        #expect(layout.isPartition)
        #expect(layout.starts == [ids[0], ids[5], ids[7]])
        #expect(try await row(node, startingAt: ids[5]).id == middleID)
        #expect(try await names(node) == ["First", "Middle", "Last"])
        #expect(try await node.client.alias(for: .thread(middleID)) == "Renamed")
    }

    @Test("moving a turning point onto another takes that thread in")
    func movingOntoTurningPointDisplacesIt() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let node = try await makeNode()
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 100)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 200)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let last = try await row(node, startingAt: ids[7])

        // Dragging the last thread's top up to the middle thread's.
        try await node.client.moveTurningPoint(from: ids[7], to: ids[3], in: contextID)

        let layout = try await layout(node)
        #expect(layout.isPartition)
        #expect(layout.starts == [ids[0], ids[3]])
        #expect(try await row(node, startingAt: ids[3]).id == last.id)
        #expect(try await names(node) == ["First", "Last"])
    }

    @Test("deleting a thread folds it into a neighbour instead of regrowing")
    func deletingThreadFolds() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let node = try await makeNode()
        try await seed(node, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Middle", at: 100)
        try await mark(node, target: ids[7], previous: "Middle", current: "Last", at: 200)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)

        let middle = try #require(try await row(node, startingAt: ids[3]).id)
        try await node.client.deleteThread(middle)
        #expect(try await layout(node).starts == [ids[0], ids[7]])

        // The leading thread has nothing before it: the next one takes it in.
        let last = try await row(node, startingAt: ids[7])
        let leading = try #require(try await row(node, startingAt: ids[0]).id)
        try await node.client.deleteThread(leading)

        let rows = try await threads(node)
        #expect(rows.map(\.id) == [last.id])
        #expect(try await layout(node).isPartition)
        #expect(try await names(node) == ["Last"])
    }

    @Test("a local rename survives re-threading and later names")
    func localRenameSurvivesRethreading() async throws {
        let ids = (0..<10).map { _ in UUID() }
        let node = try await makeNode()
        let peer = try await makeNode()
        try await seed(node, ids: ids)
        try await seed(peer, ids: ids)
        try await mark(node, target: ids[3], previous: "First", current: "Second", at: 100)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        let leadingID = try #require(try await row(node, startingAt: ids[0]).id)
        #expect(try await node.client.alias(for: .thread(leadingID)) == "First")

        try await KeepTalkingClient.setAlias("Mine", for: .thread(leadingID), on: node.store.database)
        try await sync(node, from: peer)
        // A later mark renames the thread it closes; the local name stays.
        try await mark(node, target: ids[6], previous: "Second, refined", current: "Third", at: 200)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)

        #expect(try await node.client.alias(for: .thread(leadingID)) == "Mine")
        #expect(try await names(node) == ["First", "Second, refined", "Third"])
    }

    @Test("a chitter-chatter flag follows its message into the thread a split opens")
    func chitterChatterFollowsSplit() async throws {
        let ids = (0..<8).map { _ in UUID() }
        let node = try await makeNode()
        try await seed(node, ids: ids)
        try await node.client.applyLocalTurningPointMarkThreading(in: contextID)
        #expect(try await node.client.setChitterChatter(messageID: ids[6], in: contextID, marked: true))

        try await node.client.markTurningPoint(at: ids[5], in: contextID)

        #expect(try await row(node, startingAt: ids[0]).chitterChatter.isEmpty)
        #expect(try await row(node, startingAt: ids[5]).chitterChatter == [ids[6]])
    }

    @Test("the live thread held before the first message is adopted, not duplicated")
    func liveThreadHeldBeforeFirstMessageIsAdopted() async throws {
        let node = try await makeNode()

        // A skill run's workspace needs a thread before any message exists.
        let held = try await node.client.ensureContextMainThread(for: contextID)
        #expect(held.$startMessage.id == nil)
        #expect(try await node.client.ensureContextMainThread(for: contextID).id == held.id)

        let ids = (0..<3).map { _ in UUID() }
        try await seed(node, ids: ids)
        let live = try await node.client.ensureContextMainThread(for: contextID)

        #expect(live.id == held.id)
        #expect(live.$startMessage.id == ids[0])
        #expect(try await threads(node).count == 1)
        #expect(try await layout(node).isPartition)
    }

    // MARK: - Naming

    @Test("a turning point on the first message names the leading thread")
    func firstMessageMarkNamesLeadingThread() async throws {
        let node = try await makeNode()
        let ids = (0..<4).map { _ in UUID() }
        try await seed(node, ids: ids)
        try await mark(node, target: ids[0], previous: nil, current: "Opening", at: 100)

        let projection = try await node.client.turningPointMarkThreading(in: contextID)

        #expect(projection.map(\.startMessageID) == [ids[0]])
        #expect(projection.map(\.topicName) == ["Opening"])
    }
}
