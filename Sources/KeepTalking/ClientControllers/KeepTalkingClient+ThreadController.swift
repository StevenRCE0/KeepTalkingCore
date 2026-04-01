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
    public func markTurningPoint(
        at messageID: UUID,
        in contextID: UUID
    ) async throws {
        let db = localStore.database

        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        guard
            let turningIndex = messages.firstIndex(where: { $0.id == messageID }),
            turningIndex > 0
        else {
            return
        }

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            return
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
