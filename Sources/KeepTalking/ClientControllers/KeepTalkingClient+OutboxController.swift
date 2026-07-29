import FluentKit
import Foundation

/// Low-level delivery ledger for messages that already exist locally.
/// `KeepTalkingClient.persistAndBroadcastMessage` creates an entry after
/// persisting the outgoing message and its attachments; the entry is removed
/// once `rtcClient.sendEnvelope` accepts the envelopes.
///
/// The send pipeline attempts an immediate push after enqueueing — the row
/// only survives while channels are not open, or indefinitely if delivery
/// keeps failing. Either way the message itself remains the source of truth,
/// so context sync can still replicate it to peers; the outbox only records
/// whether an active push remains pending.
///
/// `KeepTalkingOutboxEntry` is a child of both `KeepTalkingContext` and
/// `KeepTalkingContextMessage`, with a unique index on `context_message`
/// keeping the row count at exactly one per message.
///
/// Distinct from `AgentCoordinator` (which orchestrates AI turns). Nothing
/// in here talks to the LLM.
extension KeepTalkingClient {

    // MARK: - Enqueue / remove

    /// Inserts an outbox row for the given message. Called by the messaging
    /// controller after local persistence and delivery prerequisites complete,
    /// but before the first transport attempt. Idempotent — the unique index on
    /// `context_message` makes a repeat insert a no-op that logs.
    func enqueueOutboxEntry(
        contextMessage: KeepTalkingContextMessage,
        context: KeepTalkingContext
    ) async {
        do {
            let entry = try KeepTalkingOutboxEntry(
                contextMessage: contextMessage,
                context: context
            )
            try await entry.create(on: localStore.database)
        } catch {
            onLog?(
                "[outbox] failed enqueueing entry messageID=\((try? contextMessage.requireID().uuidString.lowercased()) ?? "?") error=\(error.localizedDescription)"
            )
        }
    }

    /// Removes the outbox row after a successful `rtcClient.sendEnvelope`.
    func clearOutboxEntry(contextMessageID: UUID) async {
        do {
            try await KeepTalkingOutboxEntry.query(on: localStore.database)
                .filter(\.$contextMessage.$id, .equal, contextMessageID)
                .delete()
        } catch {
            onLog?(
                "[outbox] failed clearing entry messageID=\(contextMessageID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Drain

    /// Re-attempts delivery for every queued row. Called on transport state
    /// changes (peer connect, broadcast ready) and after each fresh enqueue.
    /// Failures are logged but don't stop the drain.
    func drainOutbox() async {
        let rows: [KeepTalkingOutboxEntry]
        do {
            rows = try await KeepTalkingOutboxEntry.query(on: localStore.database)
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
            } catch let error as KeepTalkingTransportError {
                // The outbox is "existence is retry" — it keeps no attempt
                // count, so a row that can never succeed would be retried on
                // every drain for the lifetime of the database. Oversize is the
                // one transport failure that is certain not to be transient:
                // the same bytes fail the same check every time. Drop the retry
                // row (the message row itself stays) so the drain stays honest.
                guard case .envelopeTooLarge(_, let bytes, let limit) = error else {
                    onLog?(
                        "[outbox] redelivery failed messageID=\(messageID.uuidString.lowercased()) error=\(error.localizedDescription)"
                    )
                    continue
                }
                onLog?(
                    "[outbox] dropping undeliverable entry messageID=\(messageID.uuidString.lowercased()) bytes=\(bytes) limit=\(limit) — exceeds the envelope ceiling and cannot succeed on retry"
                )
                await clearOutboxEntry(contextMessageID: messageID)
            } catch {
                onLog?(
                    "[outbox] redelivery failed messageID=\(messageID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    /// Re-pushes the persisted message + its attachments. The message row
    /// already exists, so this is just an envelope re-send — the same flow the
    /// original `send` would have used after `save`.
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
