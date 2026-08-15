import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Turning points are the source of truth and the only thing stored; a
/// `KeepTalkingThreadDTO` projection of them rides the sync summary so a peer
/// reproduces the same AI threading. Sync pages arrive newest-first, so until a
/// sync completes a peer holds only a *suffix* of the context — these cover that
/// window, and the derive→apply round trip between two nodes.
struct ContextMarkPartialSyncTests {
    private struct Fixture {
        let store: KeepTalkingInMemoryStore
        let client: KeepTalkingClient
        let context: KeepTalkingContext
        let contextID: UUID
        let messageIDs: [UUID]
    }

    /// Builds a context holding only `present` out of `total` messages, keeping
    /// the ids of all of them so a projection can name ones not yet synced.
    private func makeFixture(
        total: Int,
        present: Range<Int>,
        contextID: UUID = UUID(),
        messageIDs: [UUID]? = nil
    ) async throws -> Fixture {
        let store = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: store.database)

        let ids = messageIDs ?? (0..<total).map { _ in UUID() }
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: UUID()),
            localStore: store
        )
        let fixture = Fixture(
            store: store,
            client: client,
            context: context,
            contextID: contextID,
            messageIDs: ids
        )
        try await deliver(fixture, indices: present)
        return fixture
    }

    /// Persists the given messages, standing in for a sync page landing.
    private func deliver(_ fixture: Fixture, indices: some Sequence<Int>) async throws {
        for index in indices {
            let message = KeepTalkingContextMessage(
                id: fixture.messageIDs[index],
                context: fixture.context,
                sender: .node(node: UUID()),
                content: "m\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
            try await message.save(on: fixture.store.database)
        }
    }

    /// Stores a turning-point mark — unchanged from how the agent tool stores it.
    private func markTurningPoint(
        _ fixture: Fixture,
        at index: Int,
        previousTopicName: String?,
        currentTopicName: String,
        timestamp: TimeInterval
    ) async throws {
        let mark = KeepTalkingContextMessage(
            id: UUID(),
            context: fixture.context,
            sender: .node(node: UUID()),
            content: "",
            timestamp: Date(timeIntervalSince1970: timestamp),
            type: .markTurningPoint(
                messageID: fixture.messageIDs[index],
                previousTopicName: previousTopicName,
                currentTopicName: currentTopicName
            )
        )
        try await mark.save(on: fixture.store.database)
    }

    private func threads(_ fixture: Fixture) async throws -> [KeepTalkingThread] {
        try await KeepTalkingThread.query(on: fixture.store.database)
            .filter(\.$context.$id == fixture.contextID)
            .sort(\.$createdAt)
            .all()
    }

    private func resolvedRanges(_ fixture: Fixture) async throws -> [ClosedRange<Int>] {
        let messages = try await KeepTalkingContextMessage.query(on: fixture.store.database)
            .filter(\.$context.$id == fixture.contextID)
            .sort(\.$timestamp)
            .all()
        // Marks are context messages too; index against real messages only so
        // the expected ranges read as message positions.
        let ordered = messages.filter { if case .message = $0.type { true } else { false } }
        return try await threads(fixture)
            .compactMap { $0.resolvedMessageRange(in: ordered) }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    private func topicNames(_ fixture: Fixture) async throws -> [String] {
        let messages = try await KeepTalkingContextMessage.query(on: fixture.store.database)
            .filter(\.$context.$id == fixture.contextID)
            .sort(\.$timestamp)
            .all()
        let ordered = messages.filter { if case .message = $0.type { true } else { false } }
        return try await threads(fixture)
            .compactMap { thread -> (Int, String)? in
                guard
                    let range = thread.resolvedMessageRange(in: ordered),
                    let summary = thread.summary
                else {
                    return nil
                }
                return (range.lowerBound, summary)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Indices, so DTO expectations read as message positions.
    private func indexed(
        _ fixture: Fixture,
        _ threadDTOs: [KeepTalkingThreadDTO]
    ) -> [(start: Int, end: Int?, name: String?)] {
        threadDTOs.map { dto in
            (
                start: fixture.messageIDs.firstIndex(of: dto.startMessageID) ?? -1,
                end: dto.endMessageID.flatMap { fixture.messageIDs.firstIndex(of: $0) },
                name: dto.topicName
            )
        }
    }

    @Test("turning points derive a complete, contiguous projection")
    func marksDeriveProjection() async throws {
        let fixture = try await makeFixture(total: 10, present: 0..<10)
        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Middle", timestamp: 100)
        try await markTurningPoint(
            fixture, at: 8, previousTopicName: "Middle", currentTopicName: "Last", timestamp: 200)

        let threadDTOs = try await fixture.client.turningPointMarkThreading(in: fixture.contextID)
        let rows = indexed(fixture, threadDTOs)

        #expect(rows.map(\.start) == [0, 3, 8])
        #expect(rows.map(\.end) == [2, 7, nil])
        #expect(rows.map(\.name) == ["First", "Middle", "Last"])
    }

    @Test("marks stored out of document order still derive in order")
    func outOfOrderMarksDeriveInOrder() async throws {
        let fixture = try await makeFixture(total: 10, present: 0..<10)
        // The later turning point is marked first, as newest-first paging
        // delivers it.
        try await markTurningPoint(
            fixture, at: 8, previousTopicName: "Middle", currentTopicName: "Last", timestamp: 100)
        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Middle", timestamp: 200)

        let rows = indexed(fixture, try await fixture.client.turningPointMarkThreading(in: fixture.contextID))

        #expect(rows.map(\.start) == [0, 3, 8])
        #expect(rows.map(\.end) == [2, 7, nil])
    }

    @Test("a projection naming unsynced messages is not applied")
    func projectionDeferredWhileMessagesMissing() async throws {
        // Only the newest half is local: m5 is present, m0–m4 are not.
        let fixture = try await makeFixture(total: 10, present: 5..<10)
        let threadDTOs = [
            KeepTalkingThreadDTO(
                startMessageID: fixture.messageIDs[0],
                endMessageID: fixture.messageIDs[4],
                topicName: "First"
            ),
            KeepTalkingThreadDTO(
                startMessageID: fixture.messageIDs[5],
                topicName: "Second"
            ),
        ]

        let applied = try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID)

        #expect(applied == false)
        // Nothing written: no thread anchored on a substitute boundary. The FKs
        // on start/end would reject it anyway.
        #expect(try await threads(fixture).isEmpty)
    }

    @Test("the projection applies once the remaining history lands")
    func projectionAppliesAfterHistoryArrives() async throws {
        let fixture = try await makeFixture(total: 10, present: 5..<10)
        let threadDTOs = [
            KeepTalkingThreadDTO(
                startMessageID: fixture.messageIDs[0],
                endMessageID: fixture.messageIDs[4],
                topicName: "First"
            ),
            KeepTalkingThreadDTO(startMessageID: fixture.messageIDs[5], topicName: "Second"),
        ]
        #expect(try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID) == false)

        try await deliver(fixture, indices: 0..<5)
        #expect(try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID))

        #expect(try await resolvedRanges(fixture) == [0...4, 5...9])
        #expect(try await topicNames(fixture) == ["First", "Second"])
        let live = try await threads(fixture).filter { $0.state == .contextMain }
        #expect(live.count == 1)
        #expect(live.first?.$endMessage.id == nil)
    }

    @Test("a peer reproduces the marking node's threading exactly")
    func peerReproducesThreading() async throws {
        // Node A marks; node B holds the same messages and applies A's
        // projection, arriving over the sync summary.
        let contextID = UUID()
        let messageIDs = (0..<10).map { _ in UUID() }
        let nodeA = try await makeFixture(
            total: 10, present: 0..<10, contextID: contextID, messageIDs: messageIDs)
        let nodeB = try await makeFixture(
            total: 10, present: 0..<10, contextID: contextID, messageIDs: messageIDs)

        try await markTurningPoint(
            nodeA, at: 3, previousTopicName: "First", currentTopicName: "Middle", timestamp: 100)
        try await markTurningPoint(
            nodeA, at: 8, previousTopicName: "Middle", currentTopicName: "Last", timestamp: 200)

        let projection = try await nodeA.client.turningPointMarkThreading(in: contextID)
        #expect(try await nodeB.client.applyTurningPointMarkThreading(projection, in: contextID))

        #expect(try await resolvedRanges(nodeB) == [0...2, 3...7, 8...9])
        #expect(try await topicNames(nodeB) == ["First", "Middle", "Last"])
        #expect(try await threads(nodeB).filter { $0.state == .contextMain }.count == 1)
    }

    @Test("re-applying the same projection is idempotent")
    func reapplyingIsIdempotent() async throws {
        let fixture = try await makeFixture(total: 6, present: 0..<6)
        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Second", timestamp: 100)
        let threadDTOs = try await fixture.client.turningPointMarkThreading(in: fixture.contextID)

        #expect(try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID))
        let firstPass = try await threads(fixture).map(\.id)
        #expect(try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID))

        // Same partition and the same rows — thread UUIDs are what the semantic
        // store and workspaces key on, so a re-apply must not churn them.
        #expect(try await resolvedRanges(fixture) == [0...2, 3...5])
        #expect(try await threads(fixture).map(\.id) == firstPass)
    }

    @Test("a later mark's previous name refines the thread it closed")
    func laterMarkRefinesEarlierName() async throws {
        let fixture = try await makeFixture(total: 8, present: 0..<8)
        try await markTurningPoint(
            fixture, at: 4, previousTopicName: nil, currentTopicName: "Provisional", timestamp: 100)
        // The next turn names the thread that just closed, having seen all of it.
        try await markTurningPoint(
            fixture, at: 6, previousTopicName: "Considered", currentTopicName: "Latest",
            timestamp: 200)

        let rows = indexed(fixture, try await fixture.client.turningPointMarkThreading(in: fixture.contextID))

        #expect(rows.map(\.start) == [0, 4, 6])
        #expect(rows.map(\.name) == [nil, "Considered", "Latest"])
    }

    @Test("threads the projection doesn't name are left alone")
    func unnamedThreadsSurvive() async throws {
        let fixture = try await makeFixture(total: 10, present: 0..<10)
        // A hand-made thread the AI knows nothing about.
        let local = KeepTalkingThread(
            context: fixture.context,
            startMessage: nil,
            endMessage: nil,
            state: .stored
        )
        local.$startMessage.id = fixture.messageIDs[6]
        local.$endMessage.id = fixture.messageIDs[7]
        local.summary = "Mine"
        try await local.save(on: fixture.store.database)

        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Second", timestamp: 100)
        let threadDTOs = try await fixture.client.turningPointMarkThreading(in: fixture.contextID)
        #expect(try await fixture.client.applyTurningPointMarkThreading(threadDTOs, in: fixture.contextID))

        // Local memory is not the AI's to restate.
        let survivor = try await threads(fixture).first { $0.id == local.id }
        #expect(survivor?.summary == "Mine")
        #expect(survivor?.$endMessage.id == fixture.messageIDs[7])
    }

    @Test("a context with no turning points derives a single open thread")
    func unmarkedContextDerivesOneThread() async throws {
        let fixture = try await makeFixture(total: 5, present: 0..<5)

        let rows = indexed(fixture, try await fixture.client.turningPointMarkThreading(in: fixture.contextID))

        #expect(rows.count == 1)
        #expect(rows.first?.start == 0)
        #expect(rows.first?.end == nil)
    }

    @Test("marking a turning point threads the marking node too")
    func markingNodeThreadsItself() async throws {
        // The agent stores a mark; the node that stored it must end up with the
        // same threading its peers will reproduce, not just publish for them.
        let fixture = try await makeFixture(total: 8, present: 0..<8)
        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Second", timestamp: 100)

        try await fixture.client.applyLocalTurningPointMarkThreading(in: fixture.contextID)

        #expect(try await resolvedRanges(fixture) == [0...2, 3...7])
        #expect(try await topicNames(fixture) == ["First", "Second"])
        let live = try await threads(fixture).filter { $0.state == .contextMain }
        #expect(live.count == 1)
        #expect(live.first?.$startMessage.id == fixture.messageIDs[3])
    }

    @Test("a second turning point splits again on the marking node")
    func markingNodeThreadsSuccessiveMarks() async throws {
        let fixture = try await makeFixture(total: 10, present: 0..<10)
        try await markTurningPoint(
            fixture, at: 3, previousTopicName: "First", currentTopicName: "Middle", timestamp: 100)
        try await fixture.client.applyLocalTurningPointMarkThreading(in: fixture.contextID)
        #expect(try await resolvedRanges(fixture) == [0...2, 3...9])

        try await markTurningPoint(
            fixture, at: 8, previousTopicName: "Middle", currentTopicName: "Last", timestamp: 200)
        try await fixture.client.applyLocalTurningPointMarkThreading(in: fixture.contextID)

        #expect(try await resolvedRanges(fixture) == [0...2, 3...7, 8...9])
        #expect(try await topicNames(fixture) == ["First", "Middle", "Last"])
        #expect(try await threads(fixture).filter { $0.state == .contextMain }.count == 1)
    }

    @Test("a chitter-chatter mark with no resolvable owner stays unconsumed")
    func chitterChatterDefersWithoutOwningThread() async throws {
        let fixture = try await makeFixture(total: 6, present: 3..<6)
        let markID = UUID()
        let mark = KeepTalkingContextMessage(
            id: markID,
            context: fixture.context,
            sender: .node(node: UUID()),
            content: "",
            timestamp: Date(timeIntervalSince1970: 100),
            type: .markChitterChatter(messageID: fixture.messageIDs[4])
        )
        try await mark.save(on: fixture.store.database)

        try await fixture.client.consumePendingMarks(in: fixture.contextID)

        let saved = try #require(
            try await KeepTalkingContext.find(fixture.contextID, on: fixture.store.database)
        )
        // No thread owns m4 yet, so the flag would be dropped for good if the
        // mark were consumed here.
        #expect(saved.consumedMarks?.contains(markID) != true)
    }
}
