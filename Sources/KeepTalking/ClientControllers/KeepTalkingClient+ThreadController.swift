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

        let existing = try await KeepTalkingThread.query(on: db)
            .filter(\.$context.$id == contextID)
            .filter(\.$state == .contextMain)
            .first()

        if let existing {
            return existing
        }

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            throw KeepTalkingClientError.missingNode
        }

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        let thread = KeepTalkingThread(
            context: context,
            startMessage: messages.first,
            endMessage: nil,
            state: .contextMain
        )
        try await thread.save(on: db)
        return thread
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

        let threads = try await KeepTalkingThread.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()

        return threads.first { thread in
            let startIdx: Int
            if let startID = thread.$startMessage.id {
                guard let idx = messages.firstIndex(where: { $0.id == startID }) else { return false }
                startIdx = idx
            } else {
                startIdx = 0
            }
            let endIdx: Int
            if let endID = thread.$endMessage.id {
                guard let idx = messages.firstIndex(where: { $0.id == endID }) else { return false }
                endIdx = idx
            } else {
                endIdx = messages.count - 1
            }
            guard startIdx <= endIdx else { return false }
            return (startIdx...endIdx).contains(msgIdx)
        }
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
}
