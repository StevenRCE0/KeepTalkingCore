import FluentKit
import Foundation

extension KeepTalkingClient {
    public func threads(for contextID: UUID) async throws -> [KeepTalkingThread] {
        try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .sort(\.$createdAt)
            .all()
    }

    /// The context's live thread, re-threading the context first when it has
    /// none, or more than one.
    ///
    /// Once the context holds messages this never places a row itself: the
    /// live thread comes out of the turning-point derivation like every other.
    /// A live row placed outside it — say at the oldest message of the suffix
    /// a sync has landed so far — is one the next re-threading cannot place,
    /// and it stayed beside the derived one as a second live thread.
    ///
    /// Before the first message there is nothing to derive, yet a skill run's
    /// workspace needs a thread to hang on; this holds a live row with no
    /// start for it, which the first re-threading adopts as the live thread.
    @discardableResult
    public func ensureContextMainThread(for contextID: UUID) async throws -> KeepTalkingThread {
        let db = localStore.database
        let live = try await liveRows(in: contextID)
        if live.count == 1, live[0].$startMessage.id != nil {
            return live[0]
        }
        let holdsMessages =
            try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .count() > 0
        if holdsMessages {
            try await applyLocalTurningPointMarkThreading(in: contextID)
            if let derived = try await liveRows(in: contextID).first {
                return derived
            }
        }
        return try await threadingGate.run(for: contextID) { [self] in
            if let held = try await liveRows(in: contextID).first {
                return held
            }
            guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
                throw KeepTalkingClientError.missingContext(contextID)
            }
            let thread = KeepTalkingThread(
                context: context,
                startMessage: nil,
                endMessage: nil,
                state: .contextMain
            )
            try await thread.save(on: db)
            return thread
        }
    }

    private func liveRows(in contextID: UUID) async throws -> [KeepTalkingThread] {
        try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$state == .contextMain)
            .sort(\.$createdAt)
            .all()
    }

    private func rangeResolvedThreads(
        for contextID: UUID,
        messages: [KeepTalkingContextMessage]
    ) async throws -> [(thread: KeepTalkingThread, range: ClosedRange<Int>)] {
        try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .all()
            .compactMap { thread in
                guard let range = thread.resolvedMessageRange(in: messages) else {
                    return nil
                }
                return (thread: thread, range: range)
            }
    }

    /// Finds the thread that owns a given message within a context by testing each thread's
    /// [startMessage, endMessage] range against the full sorted message list.
    public func owningThread(for messageID: UUID, in contextID: UUID) async throws -> KeepTalkingThread? {
        let db = localStore.database
        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()

        guard let msgIdx = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        return try await rangeResolvedThreads(for: contextID, messages: messages)
            .filter { $0.range.contains(msgIdx) }
            .sorted {
                let lhsWidth = $0.range.upperBound - $0.range.lowerBound
                let rhsWidth = $1.range.upperBound - $1.range.lowerBound
                if lhsWidth != rhsWidth {
                    return lhsWidth < rhsWidth
                }
                if $0.thread.state != $1.thread.state {
                    return $0.thread.state != .contextMain
                }
                return ($0.thread.createdAt ?? .distantPast)
                    < ($1.thread.createdAt ?? .distantPast)
            }
            .first?
            .thread
    }

    /// Toggles chitter-chatter status for a message within its thread.
    public func toggleChitterChatter(
        messageID: UUID,
        in threadID: UUID
    ) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database)
        else {
            return
        }
        if let index = thread.chitterChatter.firstIndex(of: messageID) {
            thread.chitterChatter.remove(at: index)
        } else {
            thread.chitterChatter.append(messageID)
        }
        try await thread.save(on: localStore.database)
        signals.threadChanges.send(())
    }

    /// Explicitly marks or unmarks a message as chitter-chatter, locating its owning thread
    /// within the context.
    ///
    /// Returns `false` when no thread owns the message yet — mid-sync that means
    /// the surrounding history hasn't landed, not that the message is unknown,
    /// so a mark driving this must stay unconsumed and retry. Returns `true`
    /// when the flag was applied or already had the desired state.
    @discardableResult
    public func setChitterChatter(
        messageID: UUID,
        in contextID: UUID,
        marked: Bool
    ) async throws -> Bool {
        guard let thread = try await owningThread(for: messageID, in: contextID) else {
            return false
        }
        let isMarked = thread.chitterChatter.contains(messageID)
        guard isMarked != marked else { return true }
        if marked {
            thread.chitterChatter.append(messageID)
        } else {
            thread.chitterChatter.removeAll { $0 == messageID }
        }
        try await thread.save(on: localStore.database)
        signals.threadChanges.send(())
        return true
    }

    public func archiveThread(_ threadID: UUID) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database)
        else {
            return
        }
        thread.state = .archived
        try await thread.save(on: localStore.database)
        await sealThreadWorkspace(threadID)
    }

    /// Folds a thread into its neighbour by removing the turning point that
    /// opens it: its messages join the thread before it, and the leading
    /// thread, having none before it, is taken in by the one after.
    ///
    /// Threads are derived from turning points, so deleting the row alone
    /// would only see it regrow at the next re-threading.
    public func deleteThread(_ threadID: UUID) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database),
            let startID = thread.$startMessage.id
        else {
            return
        }
        let contextID = thread.$context.id
        let threading = try await turningPointThreading(in: contextID)
        guard let start = threading.position[startID], start == 0 else {
            try await removeTurningPoint(at: startID, in: contextID)
            return
        }
        guard
            let next = threading.boundaries.first,
            let nextID = threading.messages[next].id
        else {
            return
        }
        try await moveTurningPoint(from: nextID, to: startID, in: contextID)
    }

    // MARK: - Turning points made by hand

    /// Opens a new thread at `messageID`, splitting the thread that holds it.
    ///
    /// Stored as a `.markTurningPoint` exactly like the agent's own, so it
    /// travels to every peer and survives every re-threading. Returns `false`
    /// when the message is not held here, is the first message, or already
    /// opens a thread.
    @discardableResult
    public func markTurningPoint(
        at messageID: UUID,
        previousTopicName: String? = nil,
        currentTopicName: String? = nil,
        in contextID: UUID
    ) async throws -> Bool {
        let threading = try await turningPointThreading(in: contextID)
        guard
            let index = threading.position[messageID],
            index > 0,
            !threading.boundaries.contains(index)
        else {
            return false
        }
        guard let context = try await KeepTalkingContext.find(contextID, on: localStore.database)
        else {
            throw KeepTalkingClientError.missingContext(contextID)
        }
        try await storeContextMark(
            .markTurningPoint(
                messageID: messageID,
                previousTopicName: previousTopicName,
                // Unnamed by hand: an empty name marks the turning point
                // without unnaming anything (see `turningPointThreading`).
                currentTopicName: currentTopicName ?? ""
            ),
            in: context
        )
        try await applyLocalTurningPointMarkThreading(in: contextID)
        return true
    }

    /// Removes the turning point at `messageID`, folding the thread it opens
    /// into the one before.
    ///
    /// Every mark landing there is deleted — superseded ones too, or the
    /// oldest would reopen it — and the deletion reaches every peer the way
    /// any message deletion does.
    public func removeTurningPoint(at messageID: UUID, in contextID: UUID) async throws {
        let threading = try await turningPointThreading(in: contextID)
        let markIDs = threading.position[messageID].flatMap { threading.openings[$0]?.markIDs } ?? []
        guard !markIDs.isEmpty else {
            // Nothing opens there. A row starting there anyway is one the
            // derivation never placed; re-threading retires it.
            try await applyLocalTurningPointMarkThreading(in: contextID)
            return
        }
        try await deleteMessages(markIDs, in: contextID)
    }

    /// Moves the turning point at `messageID` to `newMessageID`, carrying the
    /// names its marks gave.
    ///
    /// The thread it opened keeps its row, and with it the UUID its semantic
    /// document, workspace, alias and tags hang on. A turning point already at
    /// `newMessageID` is displaced: its thread is taken in by the moving one.
    public func moveTurningPoint(
        from messageID: UUID,
        to newMessageID: UUID,
        in contextID: UUID
    ) async throws {
        guard messageID != newMessageID else { return }
        let db = localStore.database
        let threading = try await turningPointThreading(in: contextID)
        guard
            let from = threading.position[messageID],
            let to = threading.position[newMessageID],
            from > 0,
            let opening = threading.openings[from]
        else {
            return
        }
        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }

        // The new mark lands before the old ones go, and the re-threading
        // after the deletion is the only one, so the fold in between never
        // shows. `previous` names the thread that closes at the new position:
        // the same one as before, unless a displaced turning point sat there.
        let displaced = threading.openings[to]
        try await storeContextMark(
            .markTurningPoint(
                messageID: newMessageID,
                previousTopicName: displaced.map(\.previous) ?? opening.previous,
                currentTopicName: opening.current ?? ""
            ),
            in: context
        )
        let rows = try await threads(for: contextID)
        for row in rows where row.$startMessage.id == newMessageID {
            if let id = row.id { await sealThreadWorkspace(id) }
            try await row.delete(on: db)
        }
        for row in rows where row.$startMessage.id == messageID {
            row.$startMessage.id = newMessageID
            try await row.save(on: db)
        }
        try await deleteMessages(opening.markIDs + (displaced?.markIDs ?? []), in: contextID)
    }

    // MARK: - Deriving threads from turning points

    /// The marks that land on one message.
    struct TurningPointOpening {
        /// Every mark landing here, superseded ones included.
        var markIDs: [UUID]
        /// Names the thread this opening closes: from the earliest mark.
        var previous: String?
        /// Names the thread this opening opens: from the latest mark.
        var current: String?
    }

    /// A context's turning points laid over its messages.
    struct TurningPointThreading {
        /// Every row of the context, in the `(timestamp, id)` order threads
        /// are cut in.
        var messages: [KeepTalkingContextMessage]
        var position: [UUID: Int]
        /// Marks by the position they land on. Position 0 can only name the
        /// leading thread; every other key is a boundary.
        var openings: [Int: TurningPointOpening]
        var threadDTOs: [KeepTalkingThreadDTO]

        /// Positions where a thread other than the leading one opens.
        var boundaries: [Int] { openings.keys.filter { $0 > 0 }.sorted() }
    }

    /// The context's threading, as every node that holds the same messages
    /// derives it.
    ///
    /// Derived from the context: the message list plus every `.markTurningPoint`
    /// in it, the agent's and the ones made by hand alike. Turning points are
    /// the source of truth and the only thing stored or synced — a range is
    /// computed here and never written back into a mark.
    ///
    /// Built from the marks and **never from local thread rows** — those carry
    /// this user's memory (names, archives, chitter-chatter), which is nobody
    /// else's business.
    func turningPointMarkThreading(in contextID: UUID) async throws -> [KeepTalkingThreadDTO] {
        try await turningPointThreading(in: contextID).threadDTOs
    }

    /// Cap on a derived topic name. The name is written by a model and
    /// otherwise unbounded; it becomes the thread's alias and is listed in
    /// every prompt's thread map.
    static let maximumTopicNameBytes = 256

    /// `turningPointMarkThreading`, with the marks behind each boundary — what
    /// removing or moving a turning point has to delete.
    ///
    /// A mark whose message was deleted is re-targeted to the first surviving
    /// message after the tombstone, which is where that thread's start moved
    /// on the deleting node (see `shrinkThreadBoundaries`). Marks that land on
    /// one message this way merge: the earliest original target names the
    /// thread that closes there, the latest names the one that opens. A mark
    /// made by hand without a name marks the turning point without unnaming it.
    func turningPointThreading(in contextID: UUID) async throws -> TurningPointThreading {
        let messages = try await KeepTalkingContextMessage.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        var position: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let id = message.id { position[id] = index }
        }
        guard messages.first?.id != nil else {
            return TurningPointThreading(messages: messages, position: position, openings: [:], threadDTOs: [])
        }
        let keys = messages.map(messagePageKey)
        var tombstones: [UUID: KeepTalkingMessageTombstone] = [:]
        for tombstone in try await messageTombstones(in: contextID) {
            tombstones[tombstone.messageID] = tombstone
        }

        // Marks grouped by their original target, read in document order so a
        // later mark on the same message gives the names.
        var marksByTarget:
            [UUID: (
                key: KeepTalkingContextSyncPageKey, index: Int, markIDs: [UUID], previous: String?, current: String?
            )] =
                [:]
        for message in messages {
            guard
                let markID = message.id,
                case .markTurningPoint(let messageID, let previousTopicName, let currentTopicName) =
                    message.type
            else {
                continue
            }
            var mark:
                (key: KeepTalkingContextSyncPageKey, index: Int, markIDs: [UUID], previous: String?, current: String?)
            if let existing = marksByTarget[messageID] {
                mark = existing
            } else if let held = position[messageID] {
                mark = (keys[held], held, [], nil, nil)
            } else if let tombstone = tombstones[messageID],
                let next = keys.firstIndex(where: { $0 > tombstone.pageKey })
            {
                mark = (tombstone.pageKey, next, [], nil, nil)
            } else {
                // Not synced yet, or deleted with nothing after it.
                continue
            }
            mark.markIDs.append(markID)
            if let previous = normalizedTopicName(previousTopicName) { mark.previous = previous }
            if let current = normalizedTopicName(currentTopicName) { mark.current = current }
            marksByTarget[messageID] = mark
        }

        var landing:
            [Int: [(key: KeepTalkingContextSyncPageKey, markIDs: [UUID], previous: String?, current: String?)]] = [:]
        for mark in marksByTarget.values {
            landing[mark.index, default: []].append((mark.key, mark.markIDs, mark.previous, mark.current))
        }
        var openings: [Int: TurningPointOpening] = [:]
        for (index, marks) in landing {
            let ordered = marks.sorted { $0.key < $1.key }
            openings[index] = TurningPointOpening(
                markIDs: ordered.flatMap { $0.markIDs },
                previous: ordered.lazy.compactMap { $0.previous }.first,
                current: ordered.reversed().lazy.compactMap { $0.current }.first
            )
        }

        // The leading thread opens at the first message whether or not a mark
        // names it; every other boundary is a turning point.
        let starts = [0] + openings.keys.filter { $0 > 0 }.sorted()

        var threadDTOs: [KeepTalkingThreadDTO] = []
        for (offset, start) in starts.enumerated() {
            guard let startMessageID = messages[start].id else { continue }
            let nextStart = offset + 1 < starts.count ? starts[offset + 1] : nil

            // A thread is named by the mark that opened it — a mark on the
            // first message names the leading thread — but the *next* mark's
            // `previousTopicName` is a later and better-informed word on the
            // same thread, so it wins where it exists.
            let topicName = nextStart.flatMap { openings[$0]?.previous } ?? openings[start]?.current

            threadDTOs.append(
                KeepTalkingThreadDTO(
                    startMessageID: startMessageID,
                    // A nil end is what makes the trailing thread the live one.
                    endMessageID: nextStart.flatMap { messages[$0 - 1].id },
                    topicName: topicName.map(Self.cappedTopicName)
                )
            )
        }
        return TurningPointThreading(
            messages: messages,
            position: position,
            openings: openings,
            threadDTOs: threadDTOs
        )
    }

    static func cappedTopicName(_ name: String) -> String {
        guard name.utf8.count > maximumTopicNameBytes else { return name }
        var capped = ""
        var bytes = 0
        for character in name {
            let size = character.utf8.count
            guard bytes + size <= maximumTopicNameBytes else { break }
            capped.append(character)
            bytes += size
        }
        return capped
    }

    // MARK: - Applying the derivation

    /// Re-threads this node from the turning points it holds: after a mark is
    /// stored or removed, after a sync lands, after a delete.
    ///
    /// Each node derives from what it holds rather than taking a peer's
    /// threading, so a node already holding a mark its peer hasn't pulled
    /// keeps it instead of reopening the thread that mark closed.
    @discardableResult
    func applyLocalTurningPointMarkThreading(in contextID: UUID) async throws -> Bool {
        try await threadingGate.run(for: contextID) { [self] in
            try await rethread(try await turningPointMarkThreading(in: contextID), in: contextID)
        }
    }

    /// Makes the context's thread rows exactly `threadDTOs`.
    ///
    /// Returns `false` when a thread names a message this node doesn't hold —
    /// `kt_threads.start_message`/`end_message` are enforced foreign keys, so
    /// such a row cannot be written at all.
    @discardableResult
    func applyTurningPointMarkThreading(
        _ threadDTOs: [KeepTalkingThreadDTO],
        in contextID: UUID
    ) async throws -> Bool {
        try await threadingGate.run(for: contextID) { [self] in
            try await rethread(threadDTOs, in: contextID)
        }
    }

    /// The context's rows become the partition `threadDTOs` describes:
    /// contiguous, never overlapping, one live thread and it the last.
    ///
    /// Rows are reused wherever one can be placed, so a thread keeps the UUID
    /// its semantic document, workspace, alias and tags hang on: the row
    /// starting where the thread starts; for the live thread a live row comes
    /// first, since its start may have moved while its workspace has not.
    /// Every other row is retired. Leaving them alone is what overlapped: the
    /// partition covers the whole context, so an unplaced row sits on top of a
    /// placed one, and an unplaced live row runs to the newest message beside
    /// the real live thread.
    ///
    /// Archiving and chitter-chatter are this node's own. An archived thread
    /// stays archived unless it becomes the live one, and a chitter-chatter
    /// flag follows its message to whichever thread now holds it. A derived
    /// name replaces the alias only while the alias still reads as the name
    /// the derivation gave before, so a rename made here survives.
    private func rethread(
        _ threadDTOs: [KeepTalkingThreadDTO],
        in contextID: UUID
    ) async throws -> Bool {
        guard !threadDTOs.isEmpty else { return false }
        let db = localStore.database

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }
        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        var position: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let id = message.id { position[id] = index }
        }
        guard
            threadDTOs.allSatisfy({
                position[$0.startMessageID] != nil
                    && ($0.endMessageID.map { position[$0] != nil } ?? true)
            })
        else {
            return false
        }
        let bounds = threadDTOs.map { dto in
            position[dto.startMessageID]!...(dto.endMessageID.map { position[$0]! } ?? messages.count - 1)
        }

        // Place rows: closed threads by start, then the live thread.
        let rows = try await threads(for: contextID)
        var unplaced = rows
        var placed = [KeepTalkingThread?](repeating: nil, count: threadDTOs.count)
        for (index, dto) in threadDTOs.enumerated() where dto.endMessageID != nil {
            if let found = unplaced.firstIndex(where: { $0.$startMessage.id == dto.startMessageID }) {
                placed[index] = unplaced.remove(at: found)
            }
        }
        if let liveIndex = threadDTOs.lastIndex(where: { $0.endMessageID == nil }) {
            let startID = threadDTOs[liveIndex].startMessageID
            func start(_ row: KeepTalkingThread) -> Int? {
                row.$startMessage.id.flatMap { position[$0] }
            }
            // Of several live rows — only ever left by the overlapping writes
            // this replaces — the latest-starting one is the tail the agent
            // has been working in, and holds its workspace.
            let live = unplaced.indices.filter { unplaced[$0].state == .contextMain }
            let found =
                live.filter { start(unplaced[$0]) != nil }
                .max { start(unplaced[$0])! < start(unplaced[$1])! }
                ?? unplaced.indices.first { unplaced[$0].$startMessage.id == startID }
                // A live row that never resolved: held before the first message.
                ?? live.first
            if let found {
                placed[liveIndex] = unplaced.remove(at: found)
            }
        }

        // Chitter-chatter follows its message.
        var flagsByThread = [[UUID]](repeating: [], count: threadDTOs.count)
        var flagged = Set<UUID>()
        for row in placed.compactMap({ $0 }) + unplaced {
            for id in row.chitterChatter where flagged.insert(id).inserted {
                guard
                    let index = position[id],
                    let owner = bounds.firstIndex(where: { $0.contains(index) })
                else {
                    continue
                }
                flagsByThread[owner].append(id)
            }
        }

        var changed = false
        var mappingsChanged = false
        for row in unplaced {
            if let id = row.id { await sealThreadWorkspace(id) }
            try await row.delete(on: db)
            changed = true
        }

        for (index, dto) in threadDTOs.enumerated() {
            let thread: KeepTalkingThread
            var dirty = false
            if let row = placed[index] {
                thread = row
            } else {
                thread = KeepTalkingThread(
                    context: context,
                    startMessage: nil,
                    endMessage: nil,
                    state: .stored
                )
                dirty = true
            }
            let state: KeepTalkingThreadState =
                dto.endMessageID == nil
                ? .contextMain
                : (thread.state == .archived ? .archived : .stored)
            if thread.$startMessage.id != dto.startMessageID {
                thread.$startMessage.id = dto.startMessageID
                dirty = true
            }
            if thread.$endMessage.id != dto.endMessageID {
                thread.$endMessage.id = dto.endMessageID
                dirty = true
            }
            if thread.state != state {
                thread.state = state
                dirty = true
            }
            if Set(thread.chitterChatter) != Set(flagsByThread[index]) {
                let kept = thread.chitterChatter.filter(flagsByThread[index].contains)
                thread.chitterChatter = kept + flagsByThread[index].filter { !kept.contains($0) }
                dirty = true
            }

            let formerName = normalizedTopicName(thread.summary)
            let topicName = normalizedTopicName(dto.topicName)
            if let topicName, topicName != formerName {
                thread.summary = topicName
                dirty = true
            }
            if dirty {
                try await thread.save(on: db)
                changed = true
            }
            if let topicName, topicName != formerName, let threadID = thread.id {
                let alias = try await Self.alias(for: .thread(threadID), on: db)
                if alias == nil || normalizedTopicName(alias) == formerName {
                    try await Self.setAlias(topicName, for: .thread(threadID), on: db)
                    mappingsChanged = true
                }
            }
        }

        if mappingsChanged {
            signals.mappingChanges.send(())
        }
        if changed || mappingsChanged {
            signals.threadChanges.send(())
        }
        if changed {
            // Boundaries moved, and semantic documents are a derived cache of
            // them. Enqueue only now that the durable state is committed — the
            // reconciler reloads it rather than taking anything from here.
            signals.semanticIndexReconciliations.send(contextID)
        }
        return true
    }

    private func normalizedTopicName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
