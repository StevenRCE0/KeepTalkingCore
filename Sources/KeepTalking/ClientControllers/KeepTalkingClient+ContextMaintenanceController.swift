import Foundation

/// What kicked off a maintenance pass. ContextMaintenance maps each trigger to a
/// set of tasks, so the passive/triggered upkeep (sync, attachment recovery,
/// stale-call sweep, presence re-broadcast, transcript backfill) lives in ONE
/// place instead of scattered across `connect()`, `handlePeerConnect`, and the
/// sync controller.
enum ContextMaintenanceTrigger: Sendable {
    /// The client just finished connecting its transport.
    case connected
    /// A peer became reachable.
    case nodeOnline(node: UUID)
    /// Periodic heartbeat tick.
    case heartbeat
}

// ContextMaintenance — the dispatcher. `dispatchMaintenance(_:)` is the single
// entry point; the trigger decides which tasks run. transcriptSyncing is gated on
// an ongoing voice session (no passive heartbeat of its own — it only rides a
// trigger when a call is actually happening).
extension KeepTalkingClient {
    private static let maintenanceHeartbeatSeconds: TimeInterval = 30

    // MARK: - Loop lifecycle

    /// Start the periodic `.heartbeat` maintenance loop. Idempotent.
    func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.maintenanceHeartbeatSeconds)
                )
                if Task.isCancelled { break }
                await self?.dispatchMaintenance(.heartbeat)
            }
        }
    }

    func stopMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    // MARK: - Dispatch

    /// Run the task set for `trigger`. The one place that decides what upkeep
    /// happens, and when.
    func dispatchMaintenance(_ trigger: ContextMaintenanceTrigger) async {
        switch trigger {
            case .connected:
                await broadcastLocalNodeState(reason: "connect")
                await reconcileStaleContinuations()

            case .nodeOnline(let node):
                guard node != config.node else { return }
                onPeerConnect?(node)
                rtcClient.debug("peer connected node=\(node.uuidString.lowercased())")
                await broadcastLocalNodeState(
                    reason: "peer-connect node=\(node.uuidString.lowercased())"
                )
                reassertActiveVoiceCall()
                // contextSyncing, then (if a call is live) transcriptSyncing, then
                // attachment recovery — then a fresh channel is the headline cue to
                // drain the outbox.
                await syncCurrentContext(with: node)
                await syncOngoingTranscripts(with: node)
                await drainOutbox()
                recoverAttachmentsInBackground(with: node)

            case .heartbeat:
                await runHeartbeatMaintenance()
        }
    }

    // MARK: - Heartbeat task set

    /// Periodic upkeep: re-reconcile with every online peer (contextSyncing +
    /// gated transcriptSyncing + attachment recovery), then sweep stale voice
    /// calls (the passive seal backstop).
    private func runHeartbeatMaintenance() async {
        let peers = onlineNodeIDs().filter { $0 != config.node }
        for peer in peers {
            await syncCurrentContext(with: peer)
            await syncOngoingTranscripts(with: peer)
            recoverAttachmentsInBackground(with: peer)
        }
        await sweepStaleVoiceCalls()
    }

    // MARK: - Task bodies (centralized from the scattered call sites)

    /// Re-announce our live voice call to a (re)connected peer so its presence
    /// set repopulates — also the "feedback" that answers a peer's end-probe
    /// during sealing (see `handleVoiceCallEndedProbe`). Stamps the shared
    /// session id.
    func reassertActiveVoiceCall() {
        guard let activeVoiceSession else { return }
        let payload = KeepTalkingVoiceCallStartedPayload(
            from: config.node,
            contextID: config.contextID,
            effectiveTransport: activeVoiceSession.effectiveTransport.rawValue,
            sessionID: activeVoiceSession.sessionID
        )
        do {
            try rtcClient.sendEnvelope(payload)
        } catch {
            onLog?("failed to send voice call started: \(error)")
        }
    }

    /// transcriptSyncing, gated: only when a voice session is ongoing in this
    /// context (hybrid detection). No call ⇒ nothing happens — the "no passive
    /// heartbeat for transcripts" rule.
    private func syncOngoingTranscripts(with node: UUID) async {
        let sessions = ongoingVoiceSessionIDs(in: config.contextID)
        guard !sessions.isEmpty else { return }
        for session in sessions {
            await syncTranscriptLines(
                session: session,
                contextID: config.contextID,
                with: node
            )
        }
    }

    /// Fire-and-forget the attachment recovery so it never blocks the rest of a
    /// maintenance pass (the outbox drain, the next peer's sync) — matching the
    /// detached behavior it had when it lived inside `syncCurrentContext`.
    private func recoverAttachmentsInBackground(with node: UUID) {
        Task.detached(priority: .background) { [weak self] in
            await self?.recoverAttachments(with: node)
        }
    }

    /// Recover attachment records (orphans) then missing blob bytes. Extracted
    /// from `syncCurrentContext` so it's a first-class maintenance task that also
    /// runs on the heartbeat, not just on connect.
    private func recoverAttachments(with node: UUID) async {
        guard config.recentAttachmentSyncLookback > 0 else { return }
        let since = Date(timeIntervalSinceNow: -config.recentAttachmentSyncLookback)
        do {
            try await requestRecentMissingAttachmentRecords(
                in: config.contextID,
                since: since,
                from: node
            )
            try await requestRecentMissingAttachmentBlobs(
                in: config.contextID,
                since: since
            )
        } catch {
            rtcClient.debug(
                "attachment recovery failed peer=\(node.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
    }
}
