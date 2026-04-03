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
    /// within the context. A no-op if the message isn't found or already has the desired state.
    public func setChitterChatter(messageID: UUID, in contextID: UUID, marked: Bool) async throws {
        guard let thread = try await owningThread(for: messageID, in: contextID) else {
            return
        }
        let isMarked = thread.chitterChatter.contains(messageID)
        guard isMarked != marked else { return }
        if marked {
            thread.chitterChatter.append(messageID)
        } else {
            thread.chitterChatter.removeAll { $0 == messageID }
        }
        try await thread.save(on: localStore.database)
        onThreadsChanged?()
    }

    public func archiveThread(_ threadID: UUID) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database)
        else {
            return
        }
        thread.state = .archived
        try await thread.save(on: localStore.database)
    }

    public func deleteThread(_ threadID: UUID) async throws {
        guard
            let thread = try await KeepTalkingThread.find(threadID, on: localStore.database)
        else {
            return
        }
        try await thread.delete(on: localStore.database)
    }

    /// Marks a turning point at the given message.
    ///
    /// The current `.contextMain` thread is frozen as `.stored` with its range
    /// set to [contextMainStart ... turningMessage - 1].
    /// A new `.contextMain` is created starting at the turning-point message.
    /// Returns the frozen stored thread representing the previous topic.
    @discardableResult
    public func markTurningPoint(
        at messageID: UUID,
        in contextID: UUID
    ) async throws -> KeepTalkingThread {
        let db = localStore.database

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        guard
            let turningIndex = messages.firstIndex(where: { $0.id == messageID }),
            turningIndex > 0
        else {
            throw KeepTalkingClientError.invalidTurningPoint(messageID)
        }

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }

        let contextMain = try await ensureContextMainThread(for: contextID)
        let endMessage = messages[turningIndex - 1]

        // Freeze the current contextMain as stored.
        contextMain.state = .stored
        contextMain.$endMessage.id = endMessage.id
        try await contextMain.save(on: db)

        // Create the new contextMain starting at the turning-point message.
        let newMain = KeepTalkingThread(
            context: context,
            startMessage: messages[turningIndex],
            endMessage: nil,
            state: .contextMain
        )
        try await newMain.save(on: db)
        onThreadsChanged?()
        return contextMain
    }

    func applyTurningPointMark(
        at messageID: UUID,
        in contextID: UUID,
        previousTopicName: String?,
        currentTopicName: String
    ) async throws {
        let db = localStore.database

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        guard
            let turningIndex = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw KeepTalkingClientError.invalidTurningPoint(messageID)
        }

        let currentTopicName = normalizedTopicName(currentTopicName)
        guard let currentTopicName, !currentTopicName.isEmpty else {
            throw KeepTalkingClientError.invalidToolArguments(
                #"{"current_topic_name":""}"#
            )
        }

        let contextMain = try await ensureContextMainThread(for: contextID)

        if contextMain.$startMessage.id == messageID {
            try await applyTopicName(
                currentTopicName,
                to: contextMain,
                on: db
            )
            return
        }

        if turningIndex == 0 {
            try await applyTopicName(
                currentTopicName,
                to: contextMain,
                on: db
            )
            return
        }

        let endMessage = messages[turningIndex - 1]
        contextMain.state = .stored
        contextMain.$endMessage.id = endMessage.id
        try await contextMain.save(on: db)

        let existingTopicName = await threadTopicName(for: contextMain, on: db)
        let previousTopicName =
            normalizedTopicName(previousTopicName)
            ?? existingTopicName
            ?? currentTopicName
        try await applyTopicName(previousTopicName, to: contextMain, on: db)

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingContext(contextID)
        }

        let newMain = KeepTalkingThread(
            context: context,
            startMessage: messages[turningIndex],
            endMessage: nil,
            state: .contextMain
        )
        try await newMain.save(on: db)
        try await applyTopicName(currentTopicName, to: newMain, on: db)
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
