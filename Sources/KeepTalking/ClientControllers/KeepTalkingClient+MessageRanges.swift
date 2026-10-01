import FluentKit
import Foundation

// Keyed message reads: pages, counts, offsets and thread boundaries, all
// exact and all off the `(context, timestamp, id)` index. What the app pages
// with and what thread features resolve ranges with, instead of holding a
// context's messages in memory. See `MessageRangeReader`.
extension KeepTalkingClient {
    // MARK: - Keys

    /// The store's key for each of `ids` that exists in `contextID`.
    public static func messageKeys(
        for ids: some Collection<UUID>,
        in contextID: UUID,
        on database: any Database
    ) async throws -> [UUID: KeepTalkingMessageKey] {
        try await MessageRangeReader.keys(forIDs: ids, in: contextID, on: MessageRangeReader.sql(database))
    }

    public func messageKeys(
        for ids: some Collection<UUID>,
        in contextID: UUID
    ) async throws -> [UUID: KeepTalkingMessageKey] {
        try await Self.messageKeys(for: ids, in: contextID, on: localStore.database)
    }

    /// Up to `limit` keys from `range`, walking from the edge `direction`
    /// starts at, in that direction's order.
    public static func messageKeys(
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all,
        direction: KeepTalkingMessagePageDirection = .forward,
        limit: Int,
        on database: any Database
    ) async throws -> [KeepTalkingMessageKey] {
        try await MessageRangeReader.keys(
            in: contextID, range: range, direction: direction, limit: limit,
            on: MessageRangeReader.sql(database)
        )
    }

    // MARK: - Pages

    /// Up to `limit` messages from `range`, taken from its newest edge for
    /// `.backward` or its oldest for `.forward`, returned oldest first. Page
    /// on by cutting the range at the page's edge key: `range.before(first)`
    /// for the next older page, `range.after(last)` for the next newer.
    public static func messagePage(
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all,
        direction: KeepTalkingMessagePageDirection,
        limit: Int,
        attachments: KeepTalkingMessagePageAttachments = .rows,
        on database: any Database
    ) async throws -> KeepTalkingMessagePage {
        let sql = try MessageRangeReader.sql(database)
        // One past the page tells whether the range goes on.
        var keys = try await MessageRangeReader.keys(
            in: contextID, range: range, direction: direction, limit: limit + 1, on: sql
        )
        let hasMore = keys.count > limit
        if hasMore { keys.removeLast() }
        if direction == .backward { keys.reverse() }
        var page = try await MessageRangeReader.rows(for: keys, attachments: attachments, on: database)
        page.hasMore = hasMore
        return page
    }

    public func messagePage(
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all,
        direction: KeepTalkingMessagePageDirection,
        limit: Int,
        attachments: KeepTalkingMessagePageAttachments = .rows
    ) async throws -> KeepTalkingMessagePage {
        try await Self.messagePage(
            in: contextID, range: range, direction: direction, limit: limit,
            attachments: attachments, on: localStore.database
        )
    }

    /// The messages among `ids` that exist in `contextID`, oldest first.
    public static func messages(
        withIDs ids: some Collection<UUID>,
        in contextID: UUID,
        attachments: KeepTalkingMessagePageAttachments = .rows,
        on database: any Database
    ) async throws -> KeepTalkingMessagePage {
        let keys = try await messageKeys(for: ids, in: contextID, on: database).values.sorted()
        return try await MessageRangeReader.rows(for: keys, attachments: attachments, on: database)
    }

    public func messages(
        withIDs ids: some Collection<UUID>,
        in contextID: UUID,
        attachments: KeepTalkingMessagePageAttachments = .rows
    ) async throws -> KeepTalkingMessagePage {
        try await Self.messages(withIDs: ids, in: contextID, attachments: attachments, on: localStore.database)
    }

    // MARK: - Counts and offsets

    public static func messageCount(
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all,
        on database: any Database
    ) async throws -> Int {
        try await MessageRangeReader.count(in: contextID, range: range, on: MessageRangeReader.sql(database))
    }

    public func messageCount(
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all
    ) async throws -> Int {
        try await Self.messageCount(in: contextID, range: range, on: localStore.database)
    }

    /// The key of the row `offset` rows into `range`, oldest first.
    public static func messageKey(
        atOffset offset: Int,
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all,
        on database: any Database
    ) async throws -> KeepTalkingMessageKey? {
        try await MessageRangeReader.key(
            atOffset: offset, in: contextID, range: range, on: MessageRangeReader.sql(database)
        )
    }

    public func messageKey(
        atOffset offset: Int,
        in contextID: UUID,
        range: KeepTalkingMessageRange = .all
    ) async throws -> KeepTalkingMessageKey? {
        try await Self.messageKey(atOffset: offset, in: contextID, range: range, on: localStore.database)
    }

    // MARK: - Threads

    /// Every thread of `contextID` with its start and end keys.
    public static func threadBoundaries(
        in contextID: UUID,
        on database: any Database
    ) async throws -> [KeepTalkingThreadBoundary] {
        let threads = try await KeepTalkingThread.query(on: database)
            .filter(\.$context.$id == contextID)
            .sort(\.$createdAt)
            .all()
        let ids = threads.flatMap { [$0.$startMessage.id, $0.$endMessage.id].compactMap { $0 } }
        let keys = try await messageKeys(for: ids, in: contextID, on: database)
        return threads.compactMap { thread in
            guard let threadID = thread.id else { return nil }
            return KeepTalkingThreadBoundary(
                threadID: threadID,
                state: thread.state,
                createdAt: thread.createdAt,
                start: thread.$startMessage.id.flatMap { keys[$0] },
                end: thread.$endMessage.id.flatMap { keys[$0] }
            )
        }
    }

    public func threadBoundaries(in contextID: UUID) async throws -> [KeepTalkingThreadBoundary] {
        try await Self.threadBoundaries(in: contextID, on: localStore.database)
    }

    /// The thread `threadID` rows, or nil when it does not resolve.
    public static func threadRange(
        _ threadID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingMessageRange? {
        guard let thread = try await KeepTalkingThread.find(threadID, on: database) else { return nil }
        let contextID = thread.$context.id
        let ids = [thread.$startMessage.id, thread.$endMessage.id].compactMap { $0 }
        let keys = try await messageKeys(for: ids, in: contextID, on: database)
        return KeepTalkingThreadBoundary(
            threadID: threadID,
            state: thread.state,
            createdAt: thread.createdAt,
            start: thread.$startMessage.id.flatMap { keys[$0] },
            end: thread.$endMessage.id.flatMap { keys[$0] }
        ).range
    }

    public func threadRange(_ threadID: UUID) async throws -> KeepTalkingMessageRange? {
        try await Self.threadRange(threadID, on: localStore.database)
    }

    /// Every resolving thread laid over the context's rows: the timeline's
    /// geometry, from one count of rows before each start and one of each
    /// thread's rows — no row itself is read.
    public static func threadLayout(
        in contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingThreadLayout {
        let sql = try MessageRangeReader.sql(database)
        let total = try await MessageRangeReader.count(in: contextID, range: .all, on: sql)
        var spans: [KeepTalkingThreadSpan] = []
        for boundary in try await threadBoundaries(in: contextID, on: database) {
            guard let range = boundary.range, let start = boundary.start else { continue }
            let offset = try await MessageRangeReader.count(in: contextID, range: .before(start), on: sql)
            let count = try await MessageRangeReader.count(in: contextID, range: range, on: sql)
            guard count > 0 else { continue }
            spans.append(KeepTalkingThreadSpan(boundary: boundary, offset: offset, count: count))
        }
        spans.sort { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return lhs.count > rhs.count
        }
        return KeepTalkingThreadLayout(total: total, spans: spans)
    }

    public func threadLayout(in contextID: UUID) async throws -> KeepTalkingThreadLayout {
        try await Self.threadLayout(in: contextID, on: localStore.database)
    }

    /// The thread owning the row `key`, by `KeepTalkingThreadBoundary.owner`,
    /// with row counts consulted only when more than one thread contains it.
    public static func owningThread(
        forKey key: KeepTalkingMessageKey,
        in contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingThreadBoundary? {
        let boundaries = try await threadBoundaries(in: contextID, on: database)
        let containing = boundaries.filter { $0.range?.contains(key) ?? false }
        guard containing.count > 1 else {
            return containing.first
        }
        let sql = try MessageRangeReader.sql(database)
        var counts: [UUID: Int] = [:]
        for boundary in containing {
            guard let range = boundary.range else { continue }
            counts[boundary.threadID] = try await MessageRangeReader.count(in: contextID, range: range, on: sql)
        }
        return KeepTalkingThreadBoundary.owner(of: key, among: containing, counts: counts)
    }

    public func owningThread(
        forKey key: KeepTalkingMessageKey,
        in contextID: UUID
    ) async throws -> KeepTalkingThreadBoundary? {
        try await Self.owningThread(forKey: key, in: contextID, on: localStore.database)
    }
}
