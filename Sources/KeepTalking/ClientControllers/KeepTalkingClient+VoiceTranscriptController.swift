import FluentKit
import Foundation

// Federated voice-call transcript: the live (pre-seal) path.
//
// Each node transcribes its OWN mic and publishes lines under its own identity;
// the lines sync via the reliable context transport (NOT voice-UDP) and merge,
// on every participant, into the flat `kt_voice_transcript_lines` table keyed by
// the shared session id. The call itself is in-memory only (`voiceCalls`) — it
// is never persisted. This file owns: ensure-record, local append (persist +
// broadcast), incoming persist (dedup), querying, and sealing.
extension KeepTalkingClient {

    /// The store the transcript *lines* live in. (Calls are in-memory; see
    /// `voiceCalls`.)
    private var voiceDB: any Database { localStore.database }

    /// How long the active end-probe waits for a peer still in the call to
    /// re-assert its presence before we conclude we were the last one out.
    private static let sealProbeWaitSeconds: TimeInterval = 3

    // MARK: - Call record (in-memory)

    /// Find-or-create the in-memory call record for `sessionID` (keyed by the
    /// shared session id so every node converges on the same record without
    /// syncing it), recording `participant` if given. Synchronous and durable-free.
    @discardableResult
    func ensureVoiceCall(
        sessionID: UUID,
        contextID: UUID,
        participant: UUID? = nil,
        startedAt: Date = Date()
    ) -> KeepTalkingVoiceCallRecord {
        let result = voiceCalls.ensure(
            id: sessionID,
            contextID: contextID,
            participant: participant,
            startedAt: startedAt
        )
        if result.created {
            onLog?(
                "[voice-transcript] new call record=\(sessionID.uuidString.prefix(8)) context=\(contextID.uuidString.prefix(8)) participant=\(participant?.uuidString.prefix(8) ?? "—")"
            )
        } else if result.addedParticipant, let participant {
            onLog?(
                "[voice-transcript] call=\(sessionID.uuidString.prefix(8)) +participant=\(participant.uuidString.prefix(8)) (\(result.record.participants.count) total)"
            )
        }
        return result.record
    }

    // MARK: - Local append (publish)

    /// Append a transcript line for *this* node's own speech: assign the next
    /// per-author sequence, persist it, broadcast the envelope to peers, and
    /// fire `onVoiceTranscriptLine`. Opt-in is enforced by the caller (only
    /// publish when transcription is on).
    @discardableResult
    public func appendVoiceTranscriptLine(
        sessionID: UUID,
        contextID: UUID,
        text: String,
        source: KeepTalkingVoiceTranscriptSource
    ) async throws -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onLog?("[voice-transcript] skip empty local line session=\(sessionID.uuidString.prefix(8))")
            return UUID()
        }
        let author = config.node
        ensureVoiceCall(sessionID: sessionID, contextID: contextID, participant: author)

        let sequence = try await nextSequence(sessionID: sessionID, author: author)
        let now = Date()
        let lineID = UUID()

        let line = KeepTalkingVoiceTranscriptLine(
            id: lineID,
            sessionID: sessionID,
            contextID: contextID,
            author: author,
            text: trimmed,
            source: source,
            timestamp: now,
            sequence: sequence
        )
        // Persist first — the line is durable regardless of whether the broadcast
        // below reaches anyone. A throw here propagates to the caller (which logs).
        try await line.create(on: voiceDB)
        onLog?(
            "[voice-transcript] +local line session=\(sessionID.uuidString.prefix(8)) seq=\(sequence) src=\(source.rawValue) chars=\(trimmed.count): \"\(trimmed.prefix(60))\""
        )

        let payload = KeepTalkingVoiceCallTranscriptLinePayload(
            from: author,
            contextID: contextID,
            sessionID: sessionID,
            lineID: lineID,
            sequence: sequence,
            text: trimmed,
            source: source.rawValue,
            timestampMs: UInt64(now.timeIntervalSince1970 * 1000)
        )

        do {
            try rtcClient.sendEnvelope(payload)
            onLog?("[voice-transcript] → broadcast line=\(lineID.uuidString.prefix(8)) seq=\(sequence)")
        } catch {
            // Best-effort: the line is persisted locally; sync-backfill will
            // carry it to peers that missed the live broadcast.
            onLog?("[voice-transcript] broadcast FAILED (line persisted, will backfill): \(error.localizedDescription)")
        }

        onVoiceTranscriptLine?(payload)
        return lineID
    }

    // MARK: - Incoming (receive)

    /// Persist a transcript line received from a peer. Idempotent — a line we
    /// already hold (by id) is dropped. Ensures the local call record exists and
    /// records the author as a participant, then fires `onVoiceTranscriptLine`.
    func handleIncomingVoiceTranscriptLine(
        _ payload: KeepTalkingVoiceCallTranscriptLinePayload
    ) async throws {
        // Our own broadcast echoed back — already persisted on append.
        if payload.from == config.node {
            return
        }
        if try await KeepTalkingVoiceTranscriptLine.find(payload.lineID, on: voiceDB) != nil {
            onLog?("[voice-transcript] dup incoming line=\(payload.lineID.uuidString.prefix(8)) — skipped")
            return
        }
        ensureVoiceCall(
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            participant: payload.from
        )
        let source = KeepTalkingVoiceTranscriptSource(rawValue: payload.source) ?? .local
        let line = KeepTalkingVoiceTranscriptLine(
            id: payload.lineID,
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            author: payload.from,
            text: payload.text,
            source: source,
            timestamp: Date(timeIntervalSince1970: Double(payload.timestampMs) / 1000),
            sequence: payload.sequence
        )
        try await line.create(on: voiceDB)
        onLog?(
            "[voice-transcript] ← line session=\(payload.sessionID.uuidString.prefix(8)) from=\(payload.from.uuidString.prefix(8)) seq=\(payload.sequence): \"\(payload.text.prefix(60))\""
        )
        onVoiceTranscriptLine?(payload)
    }

    // MARK: - Query

    /// All transcript lines for a session, ordered by time then per-author
    /// sequence (a stable total order across the interleaved authors).
    public func voiceTranscriptLines(
        forSession sessionID: UUID
    ) async throws -> [KeepTalkingVoiceTranscriptLine] {
        try await KeepTalkingVoiceTranscriptLine.query(on: voiceDB)
            .filter(\.$sessionID == sessionID)
            .sort(\.$timestamp, .ascending)
            .sort(\.$sequence, .ascending)
            .all()
    }

    /// Highest per-(session, author) sequence + 1. Authors number their own
    /// lines independently; (author, sequence) is the dedup/ordering key.
    private func nextSequence(sessionID: UUID, author: UUID) async throws -> Int {
        let last = try await KeepTalkingVoiceTranscriptLine.query(on: voiceDB)
            .filter(\.$sessionID == sessionID)
            .filter(\.$author == author)
            .sort(\.$sequence, .descending)
            .first()
        return (last?.sequence ?? -1) + 1
    }

    // MARK: - Seal (P2P last-leaver + stale-sweep backstop)

    /// The local node is leaving the call. Hybrid seal — the *active* path:
    ///  • no transcript record (transcription was off) ⇒ nothing to seal, return;
    ///  • no peers online ⇒ we're solo, seal immediately (no one to probe);
    ///  • else broadcast the leave probe (a `voiceCallEnded`) and wait briefly —
    ///    any node still in the call re-asserts `voiceCallStarted` via
    ///    `handleVoiceCallEndedProbe`, repopulating presence. Silence ⇒ we were
    ///    the last one out ⇒ seal.
    /// The *passive* path is `sweepStaleVoiceCalls` on the maintenance heartbeat.
    public func localLeaveVoiceCall(sessionID: UUID, contextID: UUID) async {
        let tag = sessionID.uuidString.prefix(8)
        guard voiceCalls.record(sessionID) != nil else {
            onLog?("[voice-transcript] local leave — no transcript record for \(tag); nothing to seal")
            return
        }
        let peersOnline = onlineNodeIDs().filter { $0 != config.node }
        if peersOnline.isEmpty {
            onLog?("[voice-transcript] local leave — solo (no peers online); sealing \(tag)")
            await sealOnLeave(sessionID)
            return
        }
        // Active end-probe: announce we're stopping, then give any node still in
        // the call a moment to re-assert its presence.
        broadcastVoiceLeaveProbe(sessionID: sessionID, contextID: contextID)
        try? await Task.sleep(for: .seconds(Self.sealProbeWaitSeconds))
        let others = voiceCallPresence.participants(in: contextID)
            .map(\.nodeID)
            .filter { $0 != config.node }
        guard others.isEmpty else {
            onLog?("[voice-transcript] leave probe — \(others.count) peer(s) re-asserted; not sealing \(tag)")
            return
        }
        onLog?("[voice-transcript] leave probe — silence after \(Int(Self.sealProbeWaitSeconds))s; sealing \(tag)")
        await sealOnLeave(sessionID)
    }

    private func sealOnLeave(_ sessionID: UUID) async {
        do { try await sealVoiceCall(sessionID: sessionID) } catch {
            onLog?("[voice-transcript] seal failed: \(error.localizedDescription)")
        }
    }

    /// Broadcast the leave probe — a `voiceCallEnded` that doubles as the "still
    /// anyone here?" trigger. Idempotent with the voice session's own teardown
    /// `ended` (both `recordEnded` and the re-assert are idempotent).
    private func broadcastVoiceLeaveProbe(sessionID: UUID, contextID: UUID) {
        let payload = KeepTalkingVoiceCallEndedPayload(
            from: config.node,
            contextID: contextID,
            sessionID: sessionID
        )
        do {
            try rtcClient.sendEnvelope(payload)
            onLog?("[voice-transcript] → leave probe (ended) session=\(sessionID.uuidString.prefix(8))")
        } catch {
            onLog?("[voice-transcript] leave probe send failed: \(error.localizedDescription)")
        }
    }

    /// Feedback to a peer's leave probe: if we're still in this call, re-assert
    /// our presence so the leaver sees the call continues and doesn't seal.
    func handleVoiceCallEndedProbe(_ ended: KeepTalkingVoiceCallEndedPayload) {
        guard ended.from != config.node else { return }
        guard activeVoiceSession != nil, ended.contextID == config.contextID else { return }
        onLog?("[voice-transcript] peer \(ended.from.uuidString.prefix(8)) left; re-asserting presence (still in call)")
        reassertActiveVoiceCall()
    }

    /// Backstop sweep: seal any still-`active` call whose context has no present
    /// participants and whose last activity is older than `staleness`. Idempotent
    /// (sealed calls are skipped), and safe to call from any node — the
    /// deterministic sealed-entry id makes concurrent seals converge.
    public func sweepStaleVoiceCalls(staleness: TimeInterval = 120) async {
        let now = Date()
        for call in voiceCalls.activeCalls() {
            let sessionID = call.id
            let peerPresent =
                voiceCallPresence
                .participants(in: call.contextID)
                .contains { $0.nodeID != config.node }
            if peerPresent { continue }
            do {
                let lastLine = try await KeepTalkingVoiceTranscriptLine.query(on: voiceDB)
                    .filter(\.$sessionID == sessionID)
                    .sort(\.$timestamp, .descending)
                    .first()
                let lastActivity = lastLine?.timestamp ?? call.startedAt
                guard now.timeIntervalSince(lastActivity) >= staleness else { continue }
                onLog?(
                    "[voice-transcript] stale-sweep sealing \(sessionID.uuidString.prefix(8)) idle=\(Int(now.timeIntervalSince(lastActivity)))s"
                )
                try await sealVoiceCall(sessionID: sessionID)
            } catch {
                onLog?(
                    "[voice-transcript] stale-sweep failed for \(sessionID.uuidString.prefix(8)): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Materialize the call's transcript and mark it sealed. Idempotent: the
    /// registry's `claimSeal` compare-and-set means only one caller (fast path,
    /// sweep, or a racing observer) wins the seal; the rest bail. The sealed-entry
    /// id is derived deterministically from the session id so concurrent sealers
    /// across nodes converge to one chat entry.
    public func sealVoiceCall(sessionID: UUID) async throws {
        guard let rec = voiceCalls.record(sessionID) else {
            onLog?("[voice-transcript] seal skipped — no call record \(sessionID.uuidString.prefix(8))")
            return
        }
        guard rec.state != .sealed else {
            onLog?("[voice-transcript] seal skipped — already sealed \(sessionID.uuidString.prefix(8))")
            return
        }
        let lines = try await voiceTranscriptLines(forSession: sessionID)
        let now = Date()

        guard !lines.isEmpty else {
            if voiceCalls.claimSeal(id: sessionID, endedAt: now, sealedEntryID: nil) != nil {
                onLog?("[voice-transcript] sealed EMPTY call \(sessionID.uuidString.prefix(8)) — nothing said")
            }
            return
        }

        let entryID = Self.sealedEntryID(for: sessionID)
        guard let sealed = voiceCalls.claimSeal(id: sessionID, endedAt: now, sealedEntryID: entryID) else {
            onLog?("[voice-transcript] seal raced — already claimed \(sessionID.uuidString.prefix(8))")
            return
        }
        let rendered = Self.renderTranscript(record: sealed, lines: lines)
        let summary = Self.sealSummary(record: sealed, lineCount: lines.count)
        onLog?(
            "[voice-transcript] SEALED call=\(sessionID.uuidString.prefix(8)) lines=\(lines.count) participants=\(sealed.participants.count) entry=\(entryID.uuidString.prefix(8))\n\(rendered)"
        )

        // Emit the single durable chat entry: a `.voiceCallSeal` message keyed by
        // the deterministic `entryID`, so concurrent sealers across nodes dedup to
        // one. Skip if it already exists (e.g. a peer sealed first and it synced
        // in). Goes through the normal message path (persist + notify + sync).
        guard try await KeepTalkingContextMessage.find(entryID, on: voiceDB) == nil else {
            onLog?("[voice-transcript] seal entry \(entryID.uuidString.prefix(8)) already present — skip emit")
            return
        }
        do {
            try await send(
                summary,
                preparedAttachments: [],
                in: KeepTalkingContext(id: sealed.contextID),
                type: .voiceCallSeal(sessionID: sessionID),
                id: entryID,
                emitLocalEnvelope: true
            )
            onLog?("[voice-transcript] seal entry message=\(entryID.uuidString.prefix(8)) emitted")
        } catch {
            onLog?("[voice-transcript] seal entry emit failed: \(error.localizedDescription)")
        }
    }

    /// Deterministic, cross-node-stable entry id for a sealed session: XOR the
    /// session bytes with a fixed 16-byte key. Bijective ⇒ distinct sessions
    /// never collide; same session ⇒ same id on every node.
    static func sealedEntryID(for sessionID: UUID) -> UUID {
        let key = Array("VOICE-SEAL-v1!!!".utf8)  // exactly 16 bytes
        let s = sessionID.uuid
        let b = [s.0, s.1, s.2, s.3, s.4, s.5, s.6, s.7, s.8, s.9, s.10, s.11, s.12, s.13, s.14, s.15]
        var o = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { o[i] = b[i] ^ key[i] }
        return UUID(
            uuid: (o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15])
        )
    }

    /// One-line summary used as the seal entry's `content` (the chip label).
    private static func sealSummary(record: KeepTalkingVoiceCallRecord, lineCount: Int) -> String {
        let duration = Int((record.endedAt ?? Date()).timeIntervalSince(record.startedAt))
        return "Voice call · \(record.participants.count) participant(s) · \(lineCount) line(s) · \(duration)s"
    }

    private static func renderTranscript(
        record: KeepTalkingVoiceCallRecord,
        lines: [KeepTalkingVoiceTranscriptLine]
    ) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let duration = Int((record.endedAt ?? Date()).timeIntervalSince(record.startedAt))
        var out = "Voice call · \(record.participants.count) participant(s) · \(lines.count) line(s) · \(duration)s\n"
        for line in lines {
            out += "[\(time.string(from: line.timestamp))] \(line.author.uuidString.prefix(8)): \(line.text)\n"
        }
        return out
    }
}
