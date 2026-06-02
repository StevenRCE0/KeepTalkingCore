import FluentKit
import Foundation

// The `transcriptSyncing` use of the context-sync engine: a per-session mirror of
// the message summary → tail → chunk reconcile, but over the flat transcript-line
// table. Dispatched by ContextMaintenance only while a voice session is ongoing
// (no passive heartbeat). Repairs lines a peer missed live — and, because it's
// the same three-phase reconcile as messages, it's correct even when lines
// arrived out of order or with mid-stream gaps (not just an append-only tail).
extension KeepTalkingClient {
    private static let transcriptSyncTimeoutSeconds: TimeInterval = 15

    // MARK: - Orchestration

    /// Reconcile one session's transcript with `node`: pull its metadata, then the
    /// tail delta, then any diverging chunk. Best-effort — failures are logged, not
    /// thrown (it runs inside maintenance).
    func syncTranscriptLines(session: UUID, contextID: UUID, with node: UUID) async {
        guard node != config.node else { return }
        let sessionTag = session.uuidString.prefix(8)
        let peerTag = node.uuidString.prefix(8)
        do {
            // Same shared summary→tail→chunk reconcile as messages — just over
            // the transcript-line stream, scoped to this session.
            try await runSyncReconcile(
                KeepTalkingSyncReconcile(
                    localSummary: {
                        try await self.localTranscriptSyncSnapshot(session: session).summary
                    },
                    remoteSummary: {
                        try await self.dispatchContextSyncTranscriptSummaryRequest(
                            to: node, session: session, contextID: contextID
                        ).summary
                    },
                    makeTail: { local, remote in
                        KeepTalkingContextSyncTranscriptTailRequest(
                            context: contextID, requester: self.config.node,
                            recipient: node, session: session, local: local, remote: remote
                        )
                    },
                    dispatchTail: { try await self.dispatchContextSyncTranscriptTailRequest($0) },
                    makeChunk: { local, remote in
                        KeepTalkingContextSyncTranscriptChunkRequest(
                            context: contextID, requester: self.config.node,
                            recipient: node, session: session, local: local, remote: remote
                        )
                    },
                    dispatchChunk: { try await self.dispatchContextSyncTranscriptChunkRequest($0) },
                    persist: { try await self.persistTranscriptLines($0) }
                )
            )
            onLog?("[voice-transcript] sync done session=\(sessionTag) peer=\(peerTag)")
        } catch {
            onLog?(
                "[voice-transcript] sync failed session=\(sessionTag) peer=\(peerTag): \(error.localizedDescription)")
        }
    }

    private func localTranscriptSyncSnapshot(
        session: UUID
    ) async throws -> KeepTalkingVoiceTranscriptSyncSnapshot {
        let lines = try await voiceTranscriptLines(forSession: session)
        return KeepTalkingVoiceTranscriptSyncSnapshot(session: session, lines: lines)
    }

    /// Persist backfilled lines, dedup by id, recording authors as participants.
    /// Fires `onVoiceTranscriptLine` so the live caption UI folds them in too.
    private func persistTranscriptLines(
        _ result: KeepTalkingContextSyncTranscriptLinesResult
    ) async throws {
        guard !result.lines.isEmpty else { return }
        var persisted = 0
        for dto in result.lines {
            if try await KeepTalkingVoiceTranscriptLine.find(dto.id, on: localStore.database) != nil {
                continue
            }
            ensureVoiceCall(
                sessionID: dto.sessionID,
                contextID: dto.contextID,
                participant: dto.author
            )
            try await dto.makeModel().create(on: localStore.database)
            persisted += 1
            onVoiceTranscriptLine?(
                KeepTalkingVoiceCallTranscriptLinePayload(
                    from: dto.author,
                    contextID: dto.contextID,
                    sessionID: dto.sessionID,
                    lineID: dto.id,
                    sequence: dto.sequence,
                    text: dto.text,
                    source: dto.source.rawValue,
                    timestampMs: UInt64(dto.timestamp.timeIntervalSince1970 * 1000)
                )
            )
        }
        if persisted > 0 {
            onLog?(
                "[voice-transcript] backfilled \(persisted)/\(result.lines.count) line(s) session=\(result.session.uuidString.prefix(8))"
            )
        }
    }

    // MARK: - Responder side (execute)

    func executeContextSyncTranscriptSummaryRequest(
        _ request: KeepTalkingContextSyncTranscriptSummaryRequest
    ) async throws -> KeepTalkingContextSyncTranscriptSummaryResult {
        let snapshot = try await localTranscriptSyncSnapshot(session: request.session)
        return KeepTalkingContextSyncTranscriptSummaryResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            session: request.session,
            summary: snapshot.summary
        )
    }

    func executeContextSyncTranscriptTailRequest(
        _ request: KeepTalkingContextSyncTranscriptTailRequest
    ) async throws -> KeepTalkingContextSyncTranscriptLinesResult {
        let snapshot = try await localTranscriptSyncSnapshot(session: request.session)
        let lines = snapshot.items(after: request.senders)
        return KeepTalkingContextSyncTranscriptLinesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            session: request.session,
            lines: lines.compactMap(KeepTalkingVoiceTranscriptLineDTO.init)
        )
    }

    func executeContextSyncTranscriptChunkRequest(
        _ request: KeepTalkingContextSyncTranscriptChunkRequest
    ) async throws -> KeepTalkingContextSyncTranscriptLinesResult {
        let snapshot = try await localTranscriptSyncSnapshot(session: request.session)
        let lines = snapshot.items(in: request.chunks)
        return KeepTalkingContextSyncTranscriptLinesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            session: request.session,
            lines: lines.compactMap(KeepTalkingVoiceTranscriptLineDTO.init)
        )
    }

    // MARK: - Requester side (dispatch)

    func dispatchContextSyncTranscriptSummaryRequest(
        to node: UUID,
        session: UUID,
        contextID: UUID
    ) async throws -> KeepTalkingContextSyncTranscriptSummaryResult {
        let request = KeepTalkingContextSyncTranscriptSummaryRequest(
            context: contextID,
            requester: config.node,
            recipient: node,
            session: session
        )
        if node == config.node {
            return try await executeContextSyncTranscriptSummaryRequest(request)
        }
        return try await syncTranscriptSummaries.response(
            for: request.request,
            timeout: Self.transcriptSyncTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.transcriptSummaryRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncTranscriptTailRequest(
        _ request: KeepTalkingContextSyncTranscriptTailRequest
    ) async throws -> KeepTalkingContextSyncTranscriptLinesResult {
        if request.recipient == config.node {
            return try await executeContextSyncTranscriptTailRequest(request)
        }
        return try await syncTranscriptLines.response(
            for: request.request,
            timeout: Self.transcriptSyncTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.transcriptTailRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncTranscriptChunkRequest(
        _ request: KeepTalkingContextSyncTranscriptChunkRequest
    ) async throws -> KeepTalkingContextSyncTranscriptLinesResult {
        if request.recipient == config.node {
            return try await executeContextSyncTranscriptChunkRequest(request)
        }
        return try await syncTranscriptLines.response(
            for: request.request,
            timeout: Self.transcriptSyncTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.transcriptChunkRequest(request)
                )
            }
        )
    }

}
