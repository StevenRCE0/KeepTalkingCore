import Foundation

extension KeepTalkingClient {
    /// Builds a `KeepTalkingVoiceSession` bound to this client's context.
    ///
    /// The session reuses:
    ///   - the same node UUID (so SFU presence sees one identity for
    ///     chat and voice together)
    ///   - the same Ed25519 signing key (loaded via the client's
    ///     keychain store)
    ///   - the same SFU endpoint (from `config.sfuEndpoint`)
    ///
    /// **Transport split:**
    ///   - *Signaling* (voice.started / .ended / .signal envelopes)
    ///     routes through the shared `rtcClient` — needs to reach chat
    ///     envelope handlers for bystander presence.
    ///   - *Audio frames* (realtime data) go directly through the broadcast
    ///     channel's `.realtime` channel, bypassing the routing strategy
    ///     entirely. Same SFU connection, no P2P detour.
    ///
    /// Callers own the session and are responsible for calling `stop()`
    /// (or letting it deinit) when voice is no longer wanted. The client holds a
    /// weak-purpose reference (`activeVoiceSession`) for envelope routing and
    /// presence — it clears that reference automatically on the session's
    /// `onStopped`, so "are we in a call?" stays accurate without the caller having
    /// to remember to detach.
    public func makeVoiceSession(
        mode: KeepTalkingVoiceSession.TransportMode = .auto,
        maxP2PMeshSize: Int = 4
    ) async throws -> KeepTalkingVoiceSession {
        guard config.sfuEndpoint != nil else {
            throw KeepTalkingClientError.noSFUEndpointConfigured
        }
        let session = KeepTalkingVoiceSession(
            config: config,
            sendEnvelope: { [weak self] envelope in
                guard let self else { throw KeepTalkingClientError.clientDisconnected }
                try self.rtcClient.sendEnvelope(envelope)
            },
            sendBlobData: { [weak self] data, _ in
                guard let self else { throw KeepTalkingClientError.clientDisconnected }
                // Voice audio goes straight to the SFU broadcast
                // channel — same connection, `.realtime` channel tag,
                // no routing-strategy detour through P2P.
                try self.rtcClient.sendRealtimeDataViaBroadcast(data)
            },
            mode: mode,
            maxP2PMeshSize: maxP2PMeshSize
        )
        // Self-detach on stop so a torn-down session never lingers as
        // `activeVoiceSession` (which would make the client think it's still in the
        // call — re-asserting presence on peer leaves, blocking every seal).
        session.onStopped = { [weak self, weak session] in
            guard let self, let session else { return }
            self.clearVoiceSession(session)
        }
        activeVoiceSession = session
        return session
    }

    /// Drop the client's reference to `session` if it's still the active one.
    /// Identity-checked so a stale session's late `onStopped` can't clear a newer
    /// session that has since taken its place. Invoked from `onStopped`.
    func clearVoiceSession(_ session: KeepTalkingVoiceSession) {
        if activeVoiceSession === session {
            activeVoiceSession = nil
            onLog?("[voice] cleared active session reference")
        }
    }
}
