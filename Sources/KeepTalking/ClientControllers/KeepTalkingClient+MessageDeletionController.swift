import FluentKit
import Foundation

/// Message deletion: a grow-only tombstone set on the context, merged by union.
///
/// Every path that learns of a tombstone — a local delete, a peer's push, a
/// summary exchange — goes through `mergeMessageDeletions`, so the cleanup a
/// deleted row needs is written once:
///
/// - thread boundaries move off it *before* it goes, because `kt_threads`'
///   start/end foreign keys are `onDelete: .setNull`, and a nulled end turns a
///   stored thread into a second live one;
/// - its attachments cascade away, and the blobs they held are pruned through
///   the usual reference check, so a blob another message shares stays;
/// - intake refuses the id from then on, so no peer can sync it back.
extension KeepTalkingClient {

    // MARK: - Public

    /// Deletes messages from a context, for every node in it.
    ///
    /// With `.agentTurns`, each message that belongs to an agent turn takes
    /// every row sharing its `agentTurnID` along — the prompt, thinking, tool
    /// calls, continuations, status rows and replies. Turning-point and
    /// chitter-chatter marks are stored outside any turn, so threading is never
    /// deleted this way.
    ///
    /// Ids this node does not hold are ignored — a tombstone needs the row's
    /// timestamp, and only the row has it. Returns the ids tombstoned.
    @discardableResult
    public func deleteMessages(
        _ messageIDs: [UUID],
        in contextID: UUID,
        scope: KeepTalkingMessageDeletionScope = .messages
    ) async throws -> [UUID] {
        guard !messageIDs.isEmpty else { return [] }
        let db = localStore.database
        var messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .filter(\.$id ~~ messageIDs)
            .all()
        let agentTurnIDs =
            scope == .agentTurns ? Set(messages.compactMap(\.agentTurnID)) : []
        if !agentTurnIDs.isEmpty {
            let held = Set(messages.compactMap(\.id))
            messages += try await KeepTalkingContextMessage.query(on: db)
                .filter(\.$context.$id == contextID)
                .filter(\.$agentTurnID ~~ Array(agentTurnIDs))
                .all()
                .filter { $0.id.map { !held.contains($0) } ?? false }
        }
        let tombstones =
            messages
            .compactMap { message in
                message.id.map {
                    KeepTalkingMessageTombstone(messageID: $0, timestamp: message.timestamp)
                }
            }

        let fresh = try await mergeMessageDeletions(tombstones, contextID: contextID)
        guard !fresh.isEmpty else { return [] }

        // The same move the marking node makes after storing a mark. Peers
        // shrink their boundaries when the tombstones reach them, and
        // re-thread from their own turning points once their next sync lands.
        try await applyLocalTurningPointMarkThreading(in: contextID)
        publishMessageDeletions(fresh, in: contextID)

        // Only `.message` rows ever raised a context wake.
        let notified = Set(messages.filter { $0.type == .message }.compactMap(\.id))
        let revoked = fresh.map(\.messageID).filter(notified.contains)
        if !revoked.isEmpty {
            Task { [weak self] in
                await self?.sendContextWakeRevocationsIfNeeded(
                    in: contextID,
                    messageIDs: revoked
                )
            }
        }
        return fresh.map(\.messageID)
    }

    /// Every tombstone the context holds, in canonical order.
    public func messageTombstones(in contextID: UUID) async throws -> [KeepTalkingMessageTombstone] {
        try await Self.messageTombstones(in: contextID, on: localStore.database)
    }

    // MARK: - Merge

    /// Unions `tombstones` into the context's set and deletes whatever they
    /// name locally. Returns the tombstones that were new here; an empty result
    /// means nothing changed.
    @discardableResult
    func mergeMessageDeletions(
        _ tombstones: [KeepTalkingMessageTombstone],
        contextID: UUID
    ) async throws -> [KeepTalkingMessageTombstone] {
        guard !tombstones.isEmpty else { return [] }
        return try await messageDeletionGate.run(for: contextID) { [self] in
            // The shrink rewrites thread rows too; a re-threading reading them
            // mid-shrink would write back boundaries on rows about to go.
            try await threadingGate.run(for: contextID) { [self] in
                try await applyMessageDeletions(tombstones, contextID: contextID)
            }
        }
    }

    private func applyMessageDeletions(
        _ tombstones: [KeepTalkingMessageTombstone],
        contextID: UUID
    ) async throws -> [KeepTalkingMessageTombstone] {
        let outcome = try await localStore.database.transaction {
            db -> MessageDeletionOutcome? in
            guard let context = try await KeepTalkingContext.find(contextID, on: db) else {
                // A push for a context this node never joined.
                return nil
            }
            var held = context.deletedMessages ?? []
            var known = Set(held.map(\.messageID))
            var fresh: [KeepTalkingMessageTombstone] = []
            for tombstone in tombstones where known.insert(tombstone.messageID).inserted {
                fresh.append(tombstone)
            }
            guard !fresh.isEmpty else { return nil }

            held.append(contentsOf: fresh)
            context.deletedMessages = held.sorted { $0.pageKey < $1.pageKey }
            try await context.save(on: db)

            var outcome = MessageDeletionOutcome(fresh: fresh)
            try await Self.removeMessages(
                Set(fresh.map(\.messageID)),
                in: context,
                outcome: &outcome,
                on: db
            )
            return outcome
        }
        guard let outcome else { return [] }

        let freshIDs = outcome.fresh.map(\.messageID)
        discardOrphanAttachments(forParentMessageIDs: freshIDs)
        for threadID in outcome.deletedThreadIDs {
            await sealThreadWorkspace(threadID)
        }
        let prunedBlobIDs = try await Self.pruneStrayBlobs(
            among: outcome.blobIDs,
            on: localStore.database,
            blobStore: blobStore
        )

        if outcome.threadsChanged {
            signals.threadChanges.send(contextID)
        }
        if !outcome.removedMessageIDs.isEmpty {
            // Thread text changed under the semantic documents, and emptied
            // threads left documents the reconciler prunes as stale.
            signals.semanticIndexReconciliations.send(contextID)
        }
        signals.messageDeletions.send(
            KeepTalkingMessageDeletion(
                contextID: contextID,
                messageIDs: freshIDs,
                prunedBlobIDs: prunedBlobIDs
            )
        )
        onLog?(
            "[delete] context=\(contextID.uuidString.lowercased()) tombstoned=\(freshIDs.count) removed=\(outcome.removedMessageIDs.count) threadsDeleted=\(outcome.deletedThreadIDs.count) blobsPruned=\(prunedBlobIDs.count)"
        )
        return outcome.fresh
    }

    /// What one merge removed, carried out of its transaction.
    private struct MessageDeletionOutcome: Sendable {
        let fresh: [KeepTalkingMessageTombstone]
        var removedMessageIDs: [UUID] = []
        var blobIDs: Set<String> = []
        var deletedThreadIDs: [UUID] = []
        var threadsChanged = false
    }

    /// Deletes the doomed rows this node holds, after moving every thread
    /// boundary off them. Runs inside the merge's transaction.
    private static func removeMessages(
        _ doomed: Set<UUID>,
        in context: KeepTalkingContext,
        outcome: inout MessageDeletionOutcome,
        on db: any Database
    ) async throws {
        let contextID = try context.requireID()
        let messages = try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
            .sortedForSync()
        let removed = messages.compactMap(\.id).filter(doomed.contains)
        guard !removed.isEmpty else { return }
        outcome.removedMessageIDs = removed

        // Captured before the cascade on `parent_message` takes the rows.
        outcome.blobIDs = Set(
            try await KeepTalkingContextAttachment.query(on: db)
                .filter(\.$parentMessage.$id ~~ removed)
                .all(\.$blobID)
        )

        let threads = try await KeepTalkingThread.query(on: db)
            .filter(\.$context.$id == contextID)
            .all()
        try await shrinkThreadBoundaries(
            threads,
            around: doomed,
            in: messages,
            outcome: &outcome,
            on: db
        )

        if var consumed = context.consumedMarks {
            let before = consumed.count
            consumed.removeAll(where: doomed.contains)
            if consumed.count != before {
                context.consumedMarks = consumed
                try await context.save(on: db)
            }
        }

        // Attachments and outbox entries cascade with the rows.
        try await KeepTalkingContextMessage.query(on: db)
            .filter(\.$id ~~ removed)
            .delete()
    }

    /// Moves each boundary sitting on a doomed message toward the thread's
    /// other end — a start forward, an end back — to the nearest surviving
    /// message in its range. A thread with nothing left in range is deleted.
    ///
    /// Positions come from the same `(timestamp, id)` order the turning-point
    /// derivation uses, and the derivation re-targets a mark on a deleted
    /// message to the next surviving one, so a start moved here is exactly the
    /// start every peer derives: `applyTurningPointMarkThreading` then finds
    /// the row by it and the thread keeps its UUID.
    private static func shrinkThreadBoundaries(
        _ threads: [KeepTalkingThread],
        around doomed: Set<UUID>,
        in messages: [KeepTalkingContextMessage],
        outcome: inout MessageDeletionOutcome,
        on db: any Database
    ) async throws {
        var position: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let id = message.id { position[id] = index }
        }
        func survives(_ index: Int) -> Bool {
            guard let id = messages[index].id else { return true }
            return !doomed.contains(id)
        }

        var emptied: [(thread: KeepTalkingThread, start: Int)] = []
        var kept: [KeepTalkingThread] = []
        for thread in threads {
            guard
                let startID = thread.$startMessage.id,
                let start = position[startID]
            else {
                kept.append(thread)
                continue
            }
            let isLive = thread.state == .contextMain
            let end: Int
            if isLive {
                end = messages.count - 1
            } else if let endID = thread.$endMessage.id, let index = position[endID] {
                end = index
            } else {
                kept.append(thread)
                continue
            }
            guard start <= end else {
                kept.append(thread)
                continue
            }

            // A live thread's end is "the newest message", not a row, so only
            // its start can sit on a deleted message. The chitter-chatter list
            // may name deleted rows either way.
            let startDoomed = !survives(start)
            let endDoomed = !isLive && !survives(end)
            let strippedChitterChatter = thread.chitterChatter.filter { !doomed.contains($0) }
            let chitterChatterChanged = strippedChitterChatter.count != thread.chitterChatter.count

            guard startDoomed || endDoomed || chitterChatterChanged else {
                kept.append(thread)
                continue
            }
            guard let newStart = (start...end).first(where: survives) else {
                emptied.append((thread, start))
                continue
            }
            thread.$startMessage.id = messages[newStart].id
            if !isLive, let newEnd = (start...end).last(where: survives) {
                thread.$endMessage.id = messages[newEnd].id
            }
            thread.chitterChatter = strippedChitterChatter
            try await thread.save(on: db)
            kept.append(thread)
            outcome.threadsChanged = true
        }

        for (thread, start) in emptied {
            // The live thread emptied: the conversation's tail is now wherever
            // the thread before it ended. Hand the live state to that thread,
            // as the derivation does once the mark that opened this one has
            // nothing left to point at.
            if thread.state == .contextMain,
                let lastSurviving = (0..<start).last(where: survives),
                let predecessor = kept.first(where: {
                    $0.state == .stored
                        && $0.$endMessage.id == messages[lastSurviving].id
                })
            {
                predecessor.$endMessage.id = nil
                predecessor.state = .contextMain
                try await predecessor.save(on: db)
            }
            if let threadID = thread.id {
                outcome.deletedThreadIDs.append(threadID)
            }
            try await thread.delete(on: db)
            outcome.threadsChanged = true
        }
    }

    // MARK: - Reads

    static func messageTombstones(
        in contextID: UUID,
        on database: any Database
    ) async throws -> [KeepTalkingMessageTombstone] {
        try await KeepTalkingContext.find(contextID, on: database)?.deletedMessages ?? []
    }

    func deletedMessageIDs(in contextID: UUID) async throws -> Set<UUID> {
        Set(try await messageTombstones(in: contextID).map(\.messageID))
    }

    func messageDeletionDigest(in contextID: UUID) async throws -> Data {
        KeepTalkingMessageDeletionDigest.digest(of: try await messageTombstones(in: contextID))
    }

    // MARK: - Push

    /// Broadcasts tombstones, split into pages: a large delete must not produce
    /// an envelope transport refuses to send.
    func publishMessageDeletions(
        _ tombstones: [KeepTalkingMessageTombstone],
        in contextID: UUID
    ) {
        var remaining = tombstones.sorted { $0.pageKey < $1.pageKey }
        while !remaining.isEmpty {
            let page = KeepTalkingContextSyncPage.page(remaining).items
            // `page` skips an item only when it alone exceeds the per-item
            // ceiling, which a tombstone never does; guard anyway so a skip
            // cannot spin this loop.
            guard !page.isEmpty else { break }
            remaining.removeFirst(page.count)
            do {
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.messageDeletionsPush(
                        KeepTalkingContextSyncMessageDeletionsPush(
                            context: contextID,
                            origin: config.node,
                            tombstones: page
                        )
                    )
                )
            } catch {
                // The digest compare on the next summary exchange catches up.
                onLog?(
                    "[delete] push failed context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
                return
            }
        }
    }
}
