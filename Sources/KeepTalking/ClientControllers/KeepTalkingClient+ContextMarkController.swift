import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Stores a mark message in the context. The mark is a plain context message
    /// whose type encodes the annotation intent. It travels through normal
    /// context sync so every node receives it.
    ///
    /// Returns `false` for a chitter-chatter mark whose message is already
    /// marked.
    @discardableResult
    func storeContextMark(
        _ type: KeepTalkingContextMessage.MessageType,
        in context: KeepTalkingContext
    ) async throws -> Bool {
        let contextID = try context.requireID()
        if case .markChitterChatter(let targetMessageID) = type {
            let existing = try await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$context.$id == contextID)
                .all()
            let alreadyMarked = existing.contains { message in
                if case .markChitterChatter(let id) = message.type { return id == targetMessageID }
                return false
            }
            if alreadyMarked { return false }
        }

        let mark = KeepTalkingContextMessage(
            context: context,
            sender: .node(node: config.node),
            content: "",
            type: type
        )
        try await mark.save(on: localStore.database)
        return true
    }

    /// Applies any chitter-chatter marks this node hasn't consumed yet.
    ///
    /// Call this once a context sync **completes**, and after marking locally.
    /// Not per sync page: a mark can only land once a thread owns its message,
    /// and mid-sync the local message list is a suffix of the context.
    ///
    /// Threading itself does not come through here — it rides the sync summary
    /// as a `KeepTalkingThreadDTO` projection and is applied by the sync driver.
    /// Runs behind a per-context gate so two syncs completing together cannot
    /// interleave a read of what is unconsumed with the other's write of it.
    func consumePendingMarks(in contextID: UUID) async throws {
        try await markConsumptionGate.run(for: contextID) { [self] in
            try await consumeMarks(in: contextID)
        }
    }

    private func consumeMarks(in contextID: UUID) async throws {
        let db = localStore.database

        guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
            return
        }
        let consumed = Set(context.consumedMarks ?? [])

        let allMessages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp)
            .all()

        var newlyConsumed: [UUID] = []

        // Chitter-chatter stays a per-message mark: it annotates a message
        // inside a thread rather than describing structure. It needs the threads
        // to exist, hence it runs behind the rebuild.
        let pendingChitterChatter =
            allMessages
            .filter { message in
                guard let id = message.id, !consumed.contains(id) else { return false }
                if case .markChitterChatter = message.type { return true }
                return false
            }
            .sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }

        for mark in pendingChitterChatter {
            guard
                let markID = mark.id,
                case .markChitterChatter(let messageID) = mark.type
            else {
                continue
            }
            do {
                // `false` means "no thread owns this message yet" — not a
                // failure. Leaving it unconsumed lets a later pass apply it
                // rather than dropping the flag for good.
                guard
                    try await setChitterChatter(
                        messageID: messageID,
                        in: contextID,
                        marked: true
                    )
                else {
                    continue
                }
                newlyConsumed.append(markID)
            } catch {
                onLog?(
                    "[marks] failed to consume mark=\(markID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }

        guard !newlyConsumed.isEmpty else { return }

        if !newlyConsumed.isEmpty {
            context.consumedMarks = (context.consumedMarks ?? []) + newlyConsumed
            try await context.save(on: db)
        }
        onThreadsChanged?()

        // Marks mutate persisted thread boundaries and metadata. Semantic
        // documents are a derived cache, so only enqueue reconciliation after
        // the durable state is committed; the reconciler reloads that state.
        await onSemanticIndexNeedsReconciliation?(contextID)
    }
}
