import Foundation

/// Lifecycle state of a voice call.
public enum KeepTalkingVoiceCallState: String, Codable, Sendable, CaseIterable {
    /// The call is (believed to be) live; transcript lines are still arriving.
    case active
    /// The call has ended and its transcript has been materialized into the
    /// sealed `.voiceCallSeal` chat entry.
    case sealed
}

/// In-memory record of one voice call, keyed by the shared voice-session id.
///
/// **Voice calls are never persisted** — there is no `kt_voice_calls` table.
/// A call exists only in memory for the span it's live (plus a brief sealed
/// tail); the sole durable artifact is the `.voiceCallSeal`
/// `KeepTalkingContextMessage` emitted on seal. Transcript *lines*, by contrast,
/// ARE persisted as a flat table — see `KeepTalkingVoiceTranscriptLine`.
///
/// Keyed by the shared session id (not a random per-node UUID) so every
/// participant converges on the same record id from the id carried on the call
/// envelopes — the call never has to sync, only the lines do.
public struct KeepTalkingVoiceCallRecord: Sendable {
    /// == the shared voice-session id.
    public let id: UUID
    public let contextID: UUID
    public var state: KeepTalkingVoiceCallState
    /// Node IDs known to have participated (union observed locally).
    public var participants: [UUID]
    public var startedAt: Date
    public var endedAt: Date?
    /// The deterministic id of the `.voiceCallSeal` chat entry once sealed —
    /// derived from the session id so concurrent sealers converge. Nil while active.
    public var sealedEntryID: UUID?
}

/// Thread-safe in-memory registry of voice calls, keyed by session id.
///
/// Mirrors `KeepTalkingVoiceCallPresenceRegistry`'s lock-guarded style. Holds no
/// database — this is the ephemeral call bookkeeping that replaces the former
/// `kt_voice_calls` Fluent table.
final class KeepTalkingVoiceCallRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [UUID: KeepTalkingVoiceCallRecord] = [:]

    /// The record for `id`, if any.
    func record(_ id: UUID) -> KeepTalkingVoiceCallRecord? {
        lock.withLock { calls[id] }
    }

    /// All still-`active` calls (snapshot copy).
    func activeCalls() -> [KeepTalkingVoiceCallRecord] {
        lock.withLock { calls.values.filter { $0.state == .active } }
    }

    /// Find-or-create the record for `id`, recording `participant` if given.
    /// Returns the (possibly new) record plus whether it was just created and
    /// whether a new participant was added — for caller-side logging.
    @discardableResult
    func ensure(
        id: UUID,
        contextID: UUID,
        participant: UUID?,
        startedAt: Date
    ) -> (record: KeepTalkingVoiceCallRecord, created: Bool, addedParticipant: Bool) {
        lock.withLock {
            if var existing = calls[id] {
                var added = false
                if let participant, !existing.participants.contains(participant) {
                    existing.participants.append(participant)
                    calls[id] = existing
                    added = true
                }
                return (existing, false, added)
            }
            let rec = KeepTalkingVoiceCallRecord(
                id: id,
                contextID: contextID,
                state: .active,
                participants: participant.map { [$0] } ?? [],
                startedAt: startedAt,
                endedAt: nil
            )
            calls[id] = rec
            return (rec, true, participant != nil)
        }
    }

    /// Atomically claim the seal: flip `active`→`sealed` and stamp `endedAt` /
    /// `sealedEntryID`. Returns the updated record, or nil if the call is unknown
    /// or already sealed — so a racing sealer treats nil as "someone else sealed,
    /// bail". This compare-and-set is what makes `sealVoiceCall` idempotent.
    func claimSeal(id: UUID, endedAt: Date, sealedEntryID: UUID?) -> KeepTalkingVoiceCallRecord? {
        lock.withLock {
            guard var rec = calls[id], rec.state != .sealed else { return nil }
            rec.state = .sealed
            rec.endedAt = endedAt
            rec.sealedEntryID = sealedEntryID
            calls[id] = rec
            return rec
        }
    }
}
