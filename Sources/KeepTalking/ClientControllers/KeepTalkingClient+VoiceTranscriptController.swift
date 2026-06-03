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
    /// Append or **upsert** a transcript line for this node's own speech. Pass an
    /// existing `lineID` to revise that line in place (the live path upserts the
    /// current window's line as the transcription evolves); omit it to create a
    /// fresh line. Either way the line is persisted, broadcast, and surfaced via
    /// `onVoiceTranscriptLine`. Opt-in is enforced by the caller.
    @discardableResult
    public func appendVoiceTranscriptLine(
        sessionID: UUID,
        contextID: UUID,
        text: String,
        source: KeepTalkingVoiceTranscriptSource,
        lineID: UUID? = nil
    ) async throws -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onLog?("[voice-transcript] skip empty local line session=\(sessionID.uuidString.prefix(8))")
            return lineID ?? UUID()
        }
        let author = config.node
        // Map the high-level source to a message sender: a human's mic becomes
        // `.node(author)`; the agent's reply becomes `.autonomous` carrying this
        // node's wake keyword (or "ai") as its name, so peers can label it.
        let sender: KeepTalkingContextMessage.Sender
        switch source {
            case .local:
                sender = .node(node: author)
            case .realtime:
                let trimmedName = localVoiceAgentName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let agentName = (trimmedName?.isEmpty == false ? trimmedName! : "ai")
                sender = .autonomous(name: agentName, node: author, model: nil)
        }
        ensureVoiceCall(sessionID: sessionID, contextID: contextID, participant: author)

        // Upsert: when this id already exists, revise the line in place — keeping
        // its sequence + timestamp so it holds its position — instead of appending
        // a new one. The revision re-broadcasts and re-syncs (digest-based, exactly
        // like a mutated context message). No-ops when the text is unchanged.
        if let lineID,
            let existing = try await KeepTalkingVoiceTranscriptLine.find(lineID, on: voiceDB)
        {
            guard existing.text != trimmed else { return lineID }
            existing.text = trimmed
            existing.sender = sender
            try await existing.update(on: voiceDB)
            let payload = KeepTalkingVoiceCallTranscriptLinePayload(
                from: author,
                contextID: contextID,
                sessionID: sessionID,
                lineID: lineID,
                sequence: existing.sequence,
                text: trimmed,
                sender: sender,
                timestampMs: UInt64(existing.timestamp.timeIntervalSince1970 * 1000)
            )
            try? rtcClient.sendEnvelope(payload)
            onLog?(
                "[voice-transcript] ~revise line=\(lineID.uuidString.prefix(8)) seq=\(existing.sequence) chars=\(trimmed.count)"
            )
            onVoiceTranscriptLine?(payload)
            return lineID
        }

        let sequence = try await nextSequence(sessionID: sessionID, author: author)
        let now = Date()
        let newID = lineID ?? UUID()

        let line = KeepTalkingVoiceTranscriptLine(
            id: newID,
            sessionID: sessionID,
            contextID: contextID,
            author: author,
            text: trimmed,
            sender: sender,
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
            lineID: newID,
            sequence: sequence,
            text: trimmed,
            sender: sender,
            timestampMs: UInt64(now.timeIntervalSince1970 * 1000)
        )

        do {
            try rtcClient.sendEnvelope(payload)
            onLog?("[voice-transcript] → broadcast line=\(newID.uuidString.prefix(8)) seq=\(sequence)")
        } catch {
            // Best-effort: the line is persisted locally; sync-backfill will
            // carry it to peers that missed the live broadcast.
            onLog?("[voice-transcript] broadcast FAILED (line persisted, will backfill): \(error.localizedDescription)")
        }

        onVoiceTranscriptLine?(payload)
        return newID
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
        // Mutating sync (like continuation-bubble messages): if we already hold
        // this line, revise it in place when the text changed — the author upserts
        // the current line live as the transcription evolves — rather than
        // dropping it as a duplicate.
        if let existing = try await KeepTalkingVoiceTranscriptLine.find(payload.lineID, on: voiceDB) {
            guard existing.text != payload.text else {
                onLog?("[voice-transcript] dup incoming line=\(payload.lineID.uuidString.prefix(8)) — unchanged")
                return
            }
            existing.text = payload.text
            existing.sender = payload.sender
            try await existing.update(on: voiceDB)
            onLog?(
                "[voice-transcript] ←~ revise line=\(payload.lineID.uuidString.prefix(8)) from=\(payload.from.uuidString.prefix(8)): \"\(payload.text.prefix(60))\""
            )
            onVoiceTranscriptLine?(payload)
            return
        }
        ensureVoiceCall(
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            participant: payload.from
        )
        let line = KeepTalkingVoiceTranscriptLine(
            id: payload.lineID,
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            author: payload.from,
            text: payload.text,
            sender: payload.sender,
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

    /// Distinct voice-call sessions that have transcript lines in `contextID`,
    /// most-recently-active first. Each is surfaced to the agent as a virtual
    /// transcript "attachment" (its `attachment_id` is the session id) and read
    /// back through the existing context-attachment tools — no attachment row or
    /// blob is created; the lines stay in `kt_voice_transcript_lines`.
    public func voiceTranscriptSessionSummaries(
        in contextID: UUID
    ) async throws -> [KeepTalkingVoiceTranscriptSessionSummary] {
        let lines = try await KeepTalkingVoiceTranscriptLine.query(on: voiceDB)
            .filter(\.$contextID == contextID)
            .sort(\.$timestamp, .ascending)
            .sort(\.$sequence, .ascending)
            .all()
        guard !lines.isEmpty else { return [] }

        var order: [UUID] = []
        var grouped: [UUID: [KeepTalkingVoiceTranscriptLine]] = [:]
        for line in lines {
            if grouped[line.sessionID] == nil { order.append(line.sessionID) }
            grouped[line.sessionID, default: []].append(line)
        }

        return
            order
            .compactMap { sessionID -> KeepTalkingVoiceTranscriptSessionSummary? in
                guard let group = grouped[sessionID], !group.isEmpty else { return nil }
                var authorOrder: [UUID] = []
                var seenAuthors = Set<UUID>()
                var byteCount = 0
                for line in group {
                    if seenAuthors.insert(line.author).inserted {
                        authorOrder.append(line.author)
                    }
                    byteCount += line.text.utf8.count
                }
                return KeepTalkingVoiceTranscriptSessionSummary(
                    sessionID: sessionID,
                    contextID: contextID,
                    lineCount: group.count,
                    firstAt: group.first!.timestamp,
                    lastAt: group.last!.timestamp,
                    authors: authorOrder,
                    textByteCount: byteCount
                )
            }
            .sorted { $0.lastAt > $1.lastAt }
    }

    /// Render a session's transcript as agent-facing text with resolved speaker
    /// names and timestamps. Returns nil when the session has no lines in this
    /// context. Optionally clipped to `maxCharacters` (head kept, with a marker).
    /// DB-backed — reads `kt_voice_transcript_lines`, creates nothing.
    func renderVoiceTranscript(
        forSession sessionID: UUID,
        in contextID: UUID,
        aliasLookup: KeepTalkingAliasLookup,
        maxCharacters: Int? = nil
    ) async throws -> String? {
        let lines = try await voiceTranscriptLines(forSession: sessionID)
            .filter { $0.contextID == contextID }
        guard !lines.isEmpty else { return nil }

        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let participantCount = Set(lines.map(\.author)).count
        var out =
            "Voice call transcript · \(participantCount) participant(s) · \(lines.count) line(s)\n"
        for line in lines {
            // The sender both distinguishes the two sides and (for the agent)
            // carries its name, so peers render it exactly as we do — no local
            // wake-keyword lookup. `.autonomous` is the agent (named by its wake
            // keyword, beside its node); `.node` is the human speaker.
            let speaker: String
            switch line.sender {
                case .autonomous(let name, let node, _):
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let agentName = (trimmed.isEmpty ? "ai" : trimmed).uppercased()
                    if let node {
                        let nodeName = aliasLookup.resolve(.node(node)).primary(.uppercase)
                        speaker = "\(agentName) (\(nodeName))"
                    } else {
                        speaker = agentName
                    }
                case .node(let id):
                    speaker = aliasLookup.resolve(.node(id)).primary(.uppercase)
            }
            out += "[\(time.string(from: line.timestamp))] \(speaker): \(line.text)\n"
        }
        if let maxCharacters, out.count > maxCharacters {
            out = String(out.prefix(max(0, maxCharacters - 16))) + "\n… [truncated]"
        }
        return out
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

    /// The local node is leaving the call. Active seal path:
    ///  • no transcript record (transcription was off) ⇒ nothing to seal, return;
    ///  • no peers online ⇒ we're solo, seal immediately;
    ///  • else wait briefly, then seal only if no other participant remains.
    ///
    /// We do NOT send a separate "anyone here?" probe — the voice session already
    /// broadcasts `voiceCallEnded` on `stop()` (which runs before this), and any
    /// node still in the call re-asserts `voiceCallStarted` in response (see
    /// `handleVoiceCallEndedProbe`), repopulating our presence within the wait.
    /// `retainOnline` then drops any participant that has aged out of liveness (a
    /// peer that vanished without an `ended`). What's left is the genuinely-present
    /// set. The *passive* path is `sweepStaleVoiceCalls` on the maintenance
    /// heartbeat.
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
        // Give peers still in the call a moment to re-assert in response to our
        // session's `voiceCallEnded`, then reconcile presence against ground-truth
        // liveness so a vanished peer can't veto the seal.
        try? await Task.sleep(for: .seconds(Self.sealProbeWaitSeconds))
        voiceCallPresence.retainOnline(onlineNodeIDs())
        let others = voiceCallPresence.participants(in: contextID)
            .map(\.nodeID)
            .filter { $0 != config.node }
        guard others.isEmpty else {
            onLog?("[voice-transcript] local leave — \(others.count) peer(s) still present; not sealing \(tag)")
            return
        }
        onLog?(
            "[voice-transcript] local leave — no peers remain after \(Int(Self.sealProbeWaitSeconds))s; sealing \(tag)")
        await sealOnLeave(sessionID)
    }

    private func sealOnLeave(_ sessionID: UUID) async {
        do { try await sealVoiceCall(sessionID: sessionID) } catch {
            onLog?("[voice-transcript] seal failed: \(error.localizedDescription)")
        }
    }

    /// A peer announced it's leaving (its voice session broadcast `voiceCallEnded`
    /// on stop). If we're genuinely still in this call, re-assert our presence so a
    /// leaver deciding whether to seal sees us and holds off. The
    /// `activeVoiceSession != nil` guard is the load-bearing check: it's accurate
    /// only because the session clears it on `stop()` — otherwise a node that has
    /// itself already left would keep re-asserting "still in call" and no one could
    /// ever seal. (`recordEnded` has already dropped the leaver from the registry
    /// by the time this runs.) This is the explicit signal the seal relies on —
    /// NOT the 2 s session heartbeat, which exists to retry a lost connection.
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
        // Reconcile best-effort presence against ground-truth liveness first: a
        // peer that vanished without a clean `voiceCallEnded` leaves a ghost
        // participant that would otherwise veto every seal below (and keep the
        // toolbar lit). Once it ages out of `onlineNodeIDs()` it's dropped here, so
        // the `peerPresent` check sees the call for what it is — abandoned.
        voiceCallPresence.retainOnline(onlineNodeIDs())
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
