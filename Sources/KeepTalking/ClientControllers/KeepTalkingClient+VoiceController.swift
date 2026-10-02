import Foundation

extension KeepTalkingClient {
    /// Builds a `KeepTalkingVoiceSession` bound to this client's context.
    ///
    /// The session rides the context's room on the process-wide transport:
    /// - **Call presence** (`voice.started` / `voice.ended`) goes out as
    ///   ordinary envelopes, so bystanders' chat sees who's in the call.
    /// - **Audio** goes out as datagrams sealed with the call's key (the
    ///   context secret and the session id). The transport fans them out
    ///   through the SFU or sends them to each member a network link reaches.
    ///
    /// Callers own the session and are responsible for calling `stop()`
    /// (or letting it deinit) when voice is no longer wanted. The client holds a
    /// weak-purpose reference (`activeVoiceSession`) for envelope routing and
    /// presence — it clears that reference automatically on the session's
    /// `onStopped`, so "are we in a call?" stays accurate without the caller having
    /// to remember to detach.
    public func makeVoiceSession() async throws -> KeepTalkingVoiceSession {
        let contextSecret = try await ensureGroupChatSecret(for: config.contextID)
        let session = KeepTalkingVoiceSession(
            config: config,
            sendEnvelope: { [weak self] envelope in
                guard let self else { throw KeepTalkingClientError.clientDisconnected }
                try self.sendEnvelope(envelope)
            },
            sendDatagram: { [weak self] datagram in
                guard let self else { throw KeepTalkingClientError.clientDisconnected }
                try self.connection.sendDatagram(datagram)
            },
            frameSecret: contextSecret
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
