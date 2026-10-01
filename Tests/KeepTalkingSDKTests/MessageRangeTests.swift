import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Keyed reads against a real store, checked against the in-memory order
/// (`sortedForSync`) and range math (`resolvedMessageRange`) they replace.
struct MessageRangeTests {
    @Test("keys come back in the store's order, which is the in-memory order")
    func keysFollowCanonicalOrder() async throws {
        let fixture = try await Fixture.make(messages: 300)
        defer { fixture.finish() }

        let keys = try await KeepTalkingClient.messageKeys(
            in: fixture.contextID, limit: 1_000, on: fixture.database
        )
        #expect(keys.map(\.id) == fixture.sortedIDs)
        #expect(keys == keys.sorted())

        // Keys by id are the same keys, and within Fluent's rounding of the
        // stored timestamp.
        let byID = try await KeepTalkingClient.messageKeys(
            for: fixture.sortedIDs, in: fixture.contextID, on: fixture.database
        )
        #expect(byID.count == fixture.sortedIDs.count)
        for message in fixture.sorted {
            let key = try #require(byID[message.id!])
            #expect(key == keys.first { $0.id == message.id })
            #expect(abs(key.timestamp - message.timestamp.timeIntervalSince1970) < 1e-5)
        }
    }

    @Test("pages in either direction cover every row once", arguments: [1, 2, 7, 256])
    func pagesCoverEveryRow(pageSize: Int) async throws {
        let fixture = try await Fixture.make(messages: 300)
        defer { fixture.finish() }

        var forward: [UUID] = []
        var range = KeepTalkingMessageRange.all
        while true {
            let page = try await KeepTalkingClient.messagePage(
                in: fixture.contextID, range: range, direction: .forward,
                limit: pageSize, attachments: .none, on: fixture.database
            )
            forward += page.messages.compactMap(\.id)
            guard page.hasMore, let last = page.lastKey else { break }
            range = range.after(last)
        }
        #expect(forward == fixture.sortedIDs)

        var backward: [UUID] = []
        range = .all
        while true {
            let page = try await KeepTalkingClient.messagePage(
                in: fixture.contextID, range: range, direction: .backward,
                limit: pageSize, attachments: .none, on: fixture.database
            )
            backward = page.messages.compactMap(\.id) + backward
            guard page.hasMore, let first = page.firstKey else { break }
            range = range.before(first)
        }
        #expect(backward == fixture.sortedIDs)
    }

    @Test("a range bounded by tied rows keeps exactly the rows inside it")
    func boundsAreExactAcrossTies() async throws {
        let fixture = try await Fixture.make(messages: 60)
        defer { fixture.finish() }
        let keys = try await KeepTalkingClient.messageKeys(
            in: fixture.contextID, limit: 1_000, on: fixture.database
        )
        // The fixture gives rows 5–9 (0-based) one timestamp, so only ids
        // order them; the range takes the three in the middle.
        let tie = keys.filter { $0.timestamp == keys[6].timestamp }
        #expect(tie == Array(keys[5...9]))
        let inner = Array(tie.dropFirst().dropLast())
        let start = try #require(inner.first)
        let end = try #require(inner.last)
        let range = KeepTalkingMessageRange.thread(start: start, end: end)
        let inside = try await KeepTalkingClient.messageKeys(
            in: fixture.contextID, range: range, limit: 1_000, on: fixture.database
        )
        #expect(inside == inner)
        #expect(
            try await KeepTalkingClient.messageCount(in: fixture.contextID, range: range, on: fixture.database)
                == inner.count)
    }

    @Test("counts and offsets match the in-memory order")
    func countsAndOffsets() async throws {
        let fixture = try await Fixture.make(messages: 120)
        defer { fixture.finish() }
        let database = fixture.database
        let keys = try await KeepTalkingClient.messageKeys(in: fixture.contextID, limit: 1_000, on: database)

        #expect(try await KeepTalkingClient.messageCount(in: fixture.contextID, on: database) == 120)
        let range = KeepTalkingMessageRange.thread(start: keys[10], end: keys[50])
        #expect(try await KeepTalkingClient.messageCount(in: fixture.contextID, range: range, on: database) == 41)
        #expect(
            try await KeepTalkingClient.messageCount(in: fixture.contextID, range: .before(keys[10]), on: database)
                == 10)
        #expect(
            try await KeepTalkingClient.messageCount(in: fixture.contextID, range: .after(keys[10]), on: database)
                == 109)

        for offset in [0, 1, 10, 59, 119] {
            let key = try await KeepTalkingClient.messageKey(atOffset: offset, in: fixture.contextID, on: database)
            #expect(key == keys[offset])
        }
        #expect(try await KeepTalkingClient.messageKey(atOffset: 120, in: fixture.contextID, on: database) == nil)
        let within = try await KeepTalkingClient.messageKey(
            atOffset: 3, in: fixture.contextID, range: range, on: database)
        #expect(within == keys[13])
    }

    @Test("a page by id carries attachments and their blob records")
    func pageByIDCarriesAttachments() async throws {
        let fixture = try await Fixture.make(messages: 5)
        defer { fixture.finish() }
        let database = fixture.database
        let target = fixture.sorted[2]
        let blobID = String(repeating: "b", count: 64)
        try await KeepTalkingContextAttachment(
            id: UUID(), context: KeepTalkingContext(id: fixture.contextID),
            parentMessageID: target.id!, sender: target.sender, blobID: blobID,
            filename: "b.png", mimeType: "image/png", byteCount: 1,
            createdAt: Date(timeIntervalSince1970: 0), sortIndex: 0
        ).save(on: database)
        try await KeepTalkingBlobRecord(
            blobID: blobID, availability: .ready, mimeType: "image/png", byteCount: 1, receivedBytes: 1
        ).save(on: database)

        let page = try await KeepTalkingClient.messages(
            withIDs: [target.id!, UUID()], in: fixture.contextID,
            attachments: .rowsAndBlobRecords, on: database
        )
        #expect(page.messages.compactMap(\.id) == [target.id!])
        #expect(page.messages.first?.attachments.map(\.blobID) == [blobID])
        #expect(page.blobRecords[blobID] != nil)
        #expect(!page.hasMore)
    }

    @Test("the thread layout equals the index-based ranges")
    func threadLayoutMatchesResolvedRanges() async throws {
        let fixture = try await Fixture.make(messages: 100)
        defer { fixture.finish() }
        let sorted = fixture.sorted
        let threads = try await fixture.partition(cuts: [0, 20, 45, 80])

        let layout = try await KeepTalkingClient.threadLayout(in: fixture.contextID, on: fixture.database)
        #expect(layout.total == 100)
        #expect(layout.spans.count == threads.count)
        for thread in threads {
            let range = try #require(thread.resolvedMessageRange(in: sorted))
            let span = try #require(layout.span(for: thread.id!))
            #expect(span.offset == range.lowerBound)
            #expect(span.count == range.count)

            let keyed = try #require(try await KeepTalkingClient.threadRange(thread.id!, on: fixture.database))
            let ids = try await KeepTalkingClient.messageKeys(
                in: fixture.contextID, range: keyed, limit: 1_000, on: fixture.database
            ).map(\.id)
            #expect(ids == Array(fixture.sortedIDs[range]))
        }
        #expect(layout.spans.map(\.offset) == [0, 20, 45, 80])
    }

    @Test("the keyed owner is the index-based owner, nested threads included")
    func ownerMatchesIndexRule() async throws {
        let fixture = try await Fixture.make(messages: 40)
        defer { fixture.finish() }
        let sorted = fixture.sorted
        var threads = try await fixture.partition(cuts: [0, 25])
        // A nested stored thread inside the first, and a wide one overlapping
        // both — the shapes the narrowest-range rule was written for.
        threads.append(try await fixture.thread(from: 5, to: 9, state: .archived))
        threads.append(try await fixture.thread(from: 2, to: 30, state: .stored))

        for (offset, message) in sorted.enumerated() {
            let key = try #require(
                try await KeepTalkingClient.messageKeys(
                    for: [message.id!], in: fixture.contextID, on: fixture.database)[message.id!]
            )
            let keyed = try await KeepTalkingClient.owningThread(
                forKey: key, in: fixture.contextID, on: fixture.database)
            let reference = Self.referenceOwner(at: offset, threads: threads, messages: sorted)
            #expect(keyed?.threadID == reference?.id, "offset \(offset)")
        }
    }

    /// The rule `KeepTalkingClient.owningThread(for:in:)` applied in memory.
    private static func referenceOwner(
        at index: Int,
        threads: [KeepTalkingThread],
        messages: [KeepTalkingContextMessage]
    ) -> KeepTalkingThread? {
        threads
            .compactMap { thread in thread.resolvedMessageRange(in: messages).map { (thread, $0) } }
            .filter { $0.1.contains(index) }
            .sorted { lhs, rhs in
                let l = lhs.1.upperBound - lhs.1.lowerBound
                let r = rhs.1.upperBound - rhs.1.lowerBound
                if l != r { return l < r }
                if lhs.0.state != rhs.0.state { return lhs.0.state != .contextMain }
                return (lhs.0.createdAt ?? .distantPast) < (rhs.0.createdAt ?? .distantPast)
            }
            .first?.0
    }
}

// MARK: - Fixture

private struct Fixture {
    let store: KeepTalkingInMemoryStore
    let contextID: UUID
    let sorted: [KeepTalkingContextMessage]

    var database: any Database { store.database }
    var sortedIDs: [UUID] { sorted.compactMap(\.id) }

    /// `count` messages with sub-millisecond spacing; of every five rows the
    /// last four share one timestamp, so ties are broken by id alone.
    static func make(messages count: Int) async throws -> Fixture {
        let store = try await KeepTalkingInMemoryStore.make()
        let contextID = UUID()
        try await KeepTalkingContext(id: contextID).save(on: store.database)
        let sender = KeepTalkingContextMessage.Sender.node(node: UUID())
        var generator = SystemRandomNumberGenerator()
        var previous = 1_700_000_000.0
        var messages: [KeepTalkingContextMessage] = []
        for index in 0..<count {
            let timestamp: Double
            if index % 5 != 0 {
                timestamp = previous
            } else {
                timestamp = previous + Double.random(in: 0.000_1...0.02, using: &generator)
            }
            previous = timestamp
            let message = KeepTalkingContextMessage(
                id: UUID(), context: KeepTalkingContext(id: contextID), sender: sender,
                content: "message \(index)", timestamp: Date(timeIntervalSince1970: timestamp)
            )
            try await message.save(on: store.database)
            messages.append(message)
        }
        // Re-read so the in-memory reference holds the rounded timestamps the
        // store returns, as any caller of the old array-based APIs did.
        let stored = try await KeepTalkingContextMessage.query(on: store.database)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        return Fixture(store: store, contextID: contextID, sorted: stored)
    }

    /// Stored threads over `[cuts[i], cuts[i+1])` and a live thread from the
    /// last cut on.
    func partition(cuts: [Int]) async throws -> [KeepTalkingThread] {
        var threads: [KeepTalkingThread] = []
        for (index, cut) in cuts.enumerated() {
            if index + 1 < cuts.count {
                threads.append(try await thread(from: cut, to: cuts[index + 1] - 1, state: .stored))
            } else {
                threads.append(try await thread(from: cut, to: nil, state: .contextMain))
            }
        }
        return threads
    }

    func thread(from start: Int, to end: Int?, state: KeepTalkingThreadState) async throws -> KeepTalkingThread {
        let thread = KeepTalkingThread(
            context: KeepTalkingContext(id: contextID),
            startMessage: sorted[start],
            endMessage: end.map { sorted[$0] },
            state: state
        )
        try await thread.save(on: database)
        return thread
    }

    func finish() {
        let store = self.store
        Task { await store.shutdown() }
    }
}
