import FluentKit
import Foundation

/// Low-level delivery ledger for messages that already exist locally.
/// `KeepTalkingClient.persistAndBroadcastMessage` creates an entry after
/// persisting the outgoing message and its attachments; the entry is removed
/// once `rtcClient.sendEnvelope` accepts the envelopes.
///
/// The send pipeline attempts an immediate push after enqueueing — the row is only
/// observable to the app for the brief moment while channels are not
/// open, or indefinitely if delivery keeps failing. Either way the
/// message itself remains the source of truth, so context sync can still
/// replicate it to peers; the outbox only records whether active push remains
/// pending.
///
/// `KeepTalkingOutboxEntry` is a child of both `KeepTalkingContext` and
/// `KeepTalkingContextMessage` (via Fluent `@Parent`), so most queries
/// here filter on `$contextMessage.$id` / `$context.$id` rather than a
/// hand-maintained denormalised column. The schema is enforced by a
/// `.unique(on: "context_message")` index — one outbox entry per message
/// at most.
///
/// Distinct from `AgentCoordinator` (which orchestrates AI turns). Nothing
/// in here talks to the LLM.
extension KeepTalkingClient {

    // MARK: - Enqueue / remove

    /// Inserts an outbox row for the given message. Called by the messaging
    /// controller after local persistence and delivery prerequisites complete,
    /// but before the first transport attempt. Idempotent — the unique
    /// constraint on `context_message` plus the upfront query guard
    /// keep the row count at exactly one per message.
    func enqueueOutboxEntry(
        contextMessage: KeepTalkingContextMessage,
        context: KeepTalkingContext
    ) async {
        do {
            // Use the @Children relation to check for an existing entry —
            // the DB-level unique index on `context_message` makes this a
            // pure correctness guard, but eagerly loading via the relation
            // keeps the lookup cohesive with the model definition.
            try await contextMessage.$outboxEntries.load(on: localStore.database)
            if !contextMessage.outboxEntries.isEmpty { return }

            let entry = try KeepTalkingOutboxEntry(
                contextMessage: contextMessage,
                context: context
            )
            try await entry.save(on: localStore.database)
            onOutboxChanged?()
        } catch {
            onLog?(
                "[outbox] failed enqueueing entry messageID=\((try? contextMessage.requireID().uuidString.lowercased()) ?? "?") error=\(error.localizedDescription)"
            )
        }
    }

    /// Removes the outbox row after a successful `rtcClient.sendEnvelope`.
    /// Silent on missing row — the entry may have been cancelled by the
    /// user between the enqueue and the send completing.
    func clearOutboxEntry(contextMessageID: UUID) async {
        do {
            try await KeepTalkingOutboxEntry.query(on: localStore.database)
                .filter(\.$contextMessage.$id, .equal, contextMessageID)
                .delete()
            onOutboxChanged?()
        } catch {
            onLog?(
                "[outbox] failed clearing entry messageID=\(contextMessageID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
    }

    /// Records a failed delivery attempt — increments `attempts` and
    /// stores `error.localizedDescription` on the row. Used so the UI
    /// can surface "tried 5 times" hints if we want them later.
    func recordOutboxFailure(
        contextMessageID: UUID,
        error: any Error
    ) async {
        do {
            guard
                let entry = try await KeepTalkingOutboxEntry.query(
                    on: localStore.database
                )
                .filter(\.$contextMessage.$id, .equal, contextMessageID)
                .first()
            else { return }
            entry.attempts += 1
            entry.lastError = error.localizedDescription
            try await entry.save(on: localStore.database)
            onOutboxChanged?()
        } catch {
            onLog?(
                "[outbox] failed recording failure messageID=\(contextMessageID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Read

    /// Snapshot of every queued message ID across all contexts. The app
    /// uses this to render the leading-edge indicator on bubbles.
    public func outboxMessageIDs() async -> Set<UUID> {
        do {
            let rows = try await KeepTalkingOutboxEntry.query(
                on: localStore.database
            ).all()
            return Set(rows.map(\.$contextMessage.id))
        } catch {
            onLog?("[outbox] snapshot query failed error=\(error.localizedDescription)")
            return []
        }
    }

    /// Per-context snapshot. Convenient when the UI only renders one
    /// context at a time and we want to skip rows for other contexts.
    public func outboxMessageIDs(for contextID: UUID) async -> Set<UUID> {
        do {
            let rows = try await KeepTalkingOutboxEntry.query(
                on: localStore.database
            )
            .filter(\.$context.$id, .equal, contextID)
            .all()
            return Set(rows.map(\.$contextMessage.id))
        } catch {
            onLog?(
                "[outbox] per-context snapshot query failed context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            return []
        }
    }

    // MARK: - Public user actions

    /// User cancelled the pending push for `contextMessageID`. The
    /// underlying `KeepTalkingContextMessage` is NOT deleted — it stays
    /// in the context and will be replicated through ordinary context
    /// sync the next time peers reconnect. We just stop actively
    /// pushing it.
    public func cancelOutboxEntry(contextMessageID: UUID) async {
        await clearOutboxEntry(contextMessageID: contextMessageID)
    }

    // MARK: - Drain

    /// Re-attempts delivery for every queued row. Called on transport
    /// state changes (peer connect, broadcast ready) and after each
    /// fresh enqueue. Failures are logged on the row but don't stop the
    /// drain.
    func drainOutbox() async {
        let rows: [KeepTalkingOutboxEntry]
        do {
            rows = try await KeepTalkingOutboxEntry.query(on: localStore.database)
                .with(\.$contextMessage)
                .sort(\.$createdAt, .ascending)
                .all()
        } catch {
            onLog?("[outbox] drain query failed error=\(error.localizedDescription)")
            return
        }
        guard !rows.isEmpty else { return }
        onLog?("[outbox] draining \(rows.count) entries")

        for row in rows {
            let messageID = row.$contextMessage.id
            do {
                try await redeliverOutboxEntry(messageID: messageID)
                await clearOutboxEntry(contextMessageID: messageID)
            } catch {
                await recordOutboxFailure(
                    contextMessageID: messageID,
                    error: error
                )
                onLog?(
                    "[outbox] redelivery failed messageID=\(messageID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    /// Re-pushes the persisted message + its attachments. The message
    /// row already exists, so this is just an envelope re-send — same
    /// flow the original `send` would have used after `save`. Attachments
    /// come straight off `message.attachments` (the new `@Children`
    /// relation), avoiding a hand-rolled filter on `parentMessageID`.
    private func redeliverOutboxEntry(messageID: UUID) async throws {
        guard
            let message = try await KeepTalkingContextMessage.find(
                messageID,
                on: localStore.database
            )
        else {
            throw KeepTalkingOutboxError.messageNotFound(messageID)
        }
        try rtcClient.sendEnvelope(message)

        try await message.$attachments.load(on: localStore.database)
        for attachment in message.attachments {
            guard let dto = KeepTalkingContextAttachmentDTO(attachment) else {
                continue
            }
            try rtcClient.sendEnvelope(dto)
        }
        scheduleOutgoingBlobTransfers(for: message.attachments)
    }
}

/// Errors raised inside outbox redelivery. Surfaced only on log lines.
enum KeepTalkingOutboxError: Error, LocalizedError {
    case messageNotFound(UUID)

    var errorDescription: String? {
        switch self {
            case .messageNotFound(let id):
                return
                    "Outbox referenced a missing message \(id.uuidString.lowercased())."
        }
    }
}
