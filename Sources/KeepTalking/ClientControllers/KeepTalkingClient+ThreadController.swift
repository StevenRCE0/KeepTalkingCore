import FluentKit
import Foundation

extension KeepTalkingClient {
    public func threads(for contextID: UUID) async throws -> [KeepTalkingThread] {
        try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .sort(\.$createdAt)
            .all()
    }

    /// Ensures exactly one `.contextMain` thread exists for the context.
    /// Creates one if missing. Returns the existing or newly created thread.
    @discardableResult
    public func ensureContextMainThread(for contextID: UUID) async throws -> KeepTalkingThread {
        let db = localStore.database

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        let existingThreads = try await KeepTalkingThread.query(on: db)
            .filter(\.$context.$id == contextID)
            .filter(\.$state == .contextMain)
            .sort(\.$createdAt)
            .all()

        if let existing = existingThreads.first(where: {
            messages.isEmpty || $0.resolvedMessageRange(in: messages) != nil
        }) {
            return existing
        }

        if let repair = existingThreads.first {
            repair.$startMessage.id = messages.first?.id
            repair.$endMessage.id = nil
            try await repair.save(on: db)
            return repair
        }

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingNode
        }

        let thread = KeepTalkingThread(
            context: context,
            startMessage: messages.first,
            endMessage: nil,
            state: .contextMain
        )
        try await thread.save(on: db)
        return thread
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
            .sort(\.$timestamp)
            .all()

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
        onThreadsChanged?()
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
        onThreadsChanged?()
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

    public func deleteThread(_ threadID: UUID) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database)
        else {
            return
        }
        await sealThreadWorkspace(threadID)
        try await thread.delete(on: localStore.database)
    }

    /// The AI-marked threading for this context, as it travels to peers.
    ///
    /// Derived from the context: the message list plus every `.markTurningPoint`
    /// in it. Turning points remain the source of truth and the only thing
    /// stored — a range is computed here and never written back into a mark.
    ///
    /// Built from the marks and **never from local thread rows** — those are
    /// this user's memory, holding edits, archives and hand-made threads that
    /// are nobody else's business. Only what the AI marked is common ground, so
    /// only that travels.
    func turningPointMarkThreading(in contextID: UUID) async throws -> [KeepTalkingThreadDTO] {
        let messages = try await KeepTalkingContextMessage.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()
        guard messages.first?.id != nil else { return [] }

        var position: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let id = message.id { position[id] = index }
        }

        // Each turning point opens a thread. Read in document order rather than
        // the order the marks were stored, and let a later mark on the same
        // message win.
        var openings: [Int: (previous: String?, current: String)] = [:]
        for message in messages {
            guard
                case .markTurningPoint(let messageID, let previousTopicName, let currentTopicName) =
                    message.type,
                let index = position[messageID],
                index > 0
            else {
                continue
            }
            openings[index] = (previous: previousTopicName, current: currentTopicName)
        }

        // The leading thread opens at the first message even though no mark
        // names it; every other boundary is a turning point.
        let starts = [0] + openings.keys.sorted()

        var threadDTOs: [KeepTalkingThreadDTO] = []
        for (offset, start) in starts.enumerated() {
            guard let startMessageID = messages[start].id else { continue }
            let nextStart = offset + 1 < starts.count ? starts[offset + 1] : nil

            // A thread is named by the mark that opened it, but the *next*
            // mark's `previousTopicName` is a later and better-informed word on
            // the same thread, so it wins where it exists.
            var topicName = openings[start]?.current
            if let nextStart, let refined = openings[nextStart]?.previous {
                topicName = refined
            }

            threadDTOs.append(
                KeepTalkingThreadDTO(
                    startMessageID: startMessageID,
                    // A nil end is what makes the trailing thread the live one.
                    endMessageID: nextStart.flatMap { messages[$0 - 1].id },
                    topicName: topicName
                )
            )
        }
        return threadDTOs
    }

    /// Materialises this node's own threads from its own turning points.
    ///
    /// The marking node runs the same derivation a peer runs on the projection
    /// it receives, so both ends agree — rather than splitting positionally here
    /// and reproducing there, which is how the two drifted apart before.
    ///
    /// Call after storing a turning-point mark. Safe on a complete context,
    /// which the marking node has by definition.
    @discardableResult
    func applyLocalTurningPointMarkThreading(in contextID: UUID) async throws -> Bool {
        try await applyTurningPointMarkThreading(
            try await turningPointMarkThreading(in: contextID),
            in: contextID
        )
    }

    /// Reproduces the AI's threading locally from a published projection.
    ///
    /// Returns `false` when a thread names a message this node doesn't hold, so
    /// the caller leaves it unconsumed until a later sync —
    /// `kt_threads.start_message`/`end_message` are enforced foreign keys, so
    /// such a row cannot be written at all, and substituting a local stand-in is
    /// what corrupted ranges before.
    ///
    /// Keyed on the starting message, so applying reuses the existing row and
    /// preserves the thread UUID the semantic store and workspaces depend on.
    /// Threads the projection doesn't name are left alone — they are local
    /// memory, which a peer's AI marking has no authority over.
    @discardableResult
    func applyTurningPointMarkThreading(
        _ threadDTOs: [KeepTalkingThreadDTO],
        in contextID: UUID
    ) async throws -> Bool {
        guard !threadDTOs.isEmpty else { return false }
        let db = localStore.database

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }
        let present = Set(
            try await KeepTalkingContextMessage.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
                .compactMap(\.id)
        )
        guard
            threadDTOs.allSatisfy({
                present.contains($0.startMessageID)
                    && ($0.endMessageID.map(present.contains) ?? true)
            })
        else {
            return false
        }

        var existing = try await threads(for: contextID)
        for threadDTO in threadDTOs {
            let thread: KeepTalkingThread
            if let index = existing.firstIndex(where: { $0.$startMessage.id == threadDTO.startMessageID }) {
                thread = existing.remove(at: index)
            } else {
                thread = KeepTalkingThread(
                    context: context,
                    startMessage: nil,
                    endMessage: nil,
                    state: .stored
                )
                thread.$startMessage.id = threadDTO.startMessageID
            }

            thread.$endMessage.id = threadDTO.endMessageID
            // A missing end is what makes a thread live; archiving is a local
            // decision, so an archived thread keeps its state.
            if thread.state != .archived {
                thread.state = threadDTO.endMessageID == nil ? .contextMain : .stored
            }
            try await thread.save(on: db)
            if let topicName = normalizedTopicName(threadDTO.topicName) {
                try await applyTopicName(topicName, to: thread, on: db)
            }
        }

        onThreadsChanged?()
        // Boundaries just moved, and semantic documents are a derived cache of
        // them. Enqueue only now that the durable state is committed — the
        // reconciler reloads it rather than taking anything from here.
        await onSemanticIndexNeedsReconciliation?(contextID)
        return true
    }

    private func applyTopicName(
        _ topicName: String,
        to thread: KeepTalkingThread,
        on database: any Database
    ) async throws {
        thread.summary = topicName
        try await thread.save(on: database)
        if let threadID = thread.id {
            try await Self.setAlias(topicName, for: .thread(threadID), on: database)
            onMappingsChanged?()
        }
    }

    private func normalizedTopicName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func threadTopicName(
        for thread: KeepTalkingThread,
        on database: any Database
    ) async -> String? {
        if let summary = normalizedTopicName(thread.summary) {
            return summary
        }
        guard let threadID = thread.id else { return nil }
        return try? await Self.alias(for: .thread(threadID), on: database)
    }

}
