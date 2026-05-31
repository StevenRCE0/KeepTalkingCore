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
    /// (or letting it deinit) when voice is no longer wanted. The client
    /// does not retain it — voice is a separate lifecycle from chat sync.
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
        activeVoiceSession = session
        return session
    }

    func clearVoiceSession(_ session: KeepTalkingVoiceSession) {
        if activeVoiceSession === session {
            activeVoiceSession = nil
        }
    }
}
