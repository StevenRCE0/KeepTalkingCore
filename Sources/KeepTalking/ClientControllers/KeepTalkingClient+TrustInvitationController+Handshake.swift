import Crypto
import Foundation

// MARK: - Internal pending-session state

enum KeepTalkingPendingTrustRole: Sendable {
    case initiator
    case responder
}

// @unchecked: swift-crypto's Curve25519.KeyAgreement.PrivateKey isn't marked
// Sendable on Linux. This is a value type holding an immutable key, so it's
// safe to share; assert it manually.
struct KeepTalkingPendingTrustSession: @unchecked Sendable {
    let sessionID: UUID
    let role: KeepTalkingPendingTrustRole
    let peerNodeID: UUID
    let contextID: UUID
    /// Filled on the responder side when the local user picks at accept
    /// time, and on the initiator side when the responder's `.trustAccept`
    /// envelope arrives. Nil until then.
    var scope: KeepTalkingNodeTrustScope?
    var scopeWire: KeepTalkingTrustScopeWire?
    let localEphemeralPriv: Curve25519.KeyAgreement.PrivateKey
    let localEphemeralPub: Data
    /// Set once we know the other side's ephemeral public key.
    let peerEphemeralPub: Data?
    let createdAt: Date
    /// Resumed exactly once with the outcome of the handshake.
    let continuation: CheckedContinuation<KeepTalkingTrustOutcome, Error>?
    let timeoutTask: Task<Void, Never>?
}

extension KeepTalkingClient {
    // MARK: Receive entry point (called from ContextTransport via Client.swift)

    func handleIncomingTrustEnvelope(_ envelope: any KeepTalkingEnvelope) async {
        do {
            switch envelope.kind {
                case .trustRequest:
                    if let payload = envelope as? KeepTalkingTrustRequestPayload {
                        try await onTrustRequest(payload)
                    }
                case .trustAccept:
                    if let payload = envelope as? KeepTalkingTrustAcceptPayload {
                        try await onTrustAccept(payload)
                    }
                case .trustComplete:
                    if let payload = envelope as? KeepTalkingTrustCompletePayload {
                        try await onTrustComplete(payload)
                    }
                case .trustReject:
                    if let payload = envelope as? KeepTalkingTrustRejectPayload {
                        onTrustReject(payload)
                    }
                default:
                    break
            }
        } catch {
            onLog?(
                "[trust] failed handling \(envelope.kind.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: Per-kind handlers

    private func onTrustRequest(_ payload: KeepTalkingTrustRequestPayload) async throws {
        guard payload.to == config.node else { return }
        guard payload.from != config.node else { return }

        _ = try await ensureContext(payload.contextID)
        guard let contextSecret = try await loadGroupChatSecret(for: payload.contextID) else {
            throw KeepTalkingTrustError.contextSecretMissing(payload.contextID)
        }

        guard let handler = trustQueue.sync(execute: { incomingTrustHandler }) else {
            // No app handler installed: explicitly reject so the peer doesn't
            // hang waiting for a TTL.
            try? rtcClient.sendEnvelope(
                KeepTalkingTrustRejectPayload(
                    sessionID: payload.sessionID,
                    from: config.node,
                    to: payload.from,
                    contextID: payload.contextID
                )
            )
            throw KeepTalkingTrustError.noIncomingHandler
        }

        let request = KeepTalkingIncomingTrustRequest(
            sessionID: payload.sessionID,
            fromNodeID: payload.from,
            contextID: payload.contextID
        )

        let decision = await handler(request)

        switch decision {
            case .decline:
                try rtcClient.sendEnvelope(
                    KeepTalkingTrustRejectPayload(
                        sessionID: payload.sessionID,
                        from: config.node,
                        to: payload.from,
                        contextID: payload.contextID
                    )
                )
            case .accept(let scope):
                try await acceptTrustRequest(
                    payload: payload,
                    contextSecret: contextSecret,
                    scope: scope
                )
        }
    }

    private func acceptTrustRequest(
        payload: KeepTalkingTrustRequestPayload,
        contextSecret: Data,
        scope: KeepTalkingNodeTrustScope
    ) async throws {
        // Ensure responder has its own outgoing relation + keypair so we can
        // hand the initiator our long-term pubkey.
        let myLongTermPubKey = try await trust(node: payload.from, scope: scope)

        let ephemeral = TrustHandshakeCrypto.generateEphemeral()
        let scopeWire = Self.wireScope(from: scope)
        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            initiatorNodeID: payload.from,
            responderNodeID: config.node,
            initiatorEphemeralPub: payload.initiatorEphemeralPub,
            responderEphemeralPub: ephemeral.publicKeyBytes,
            scopeTag: scopeWire.rawValue
        )

        let sessionKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: ephemeral.privateKey,
            remotePublicBytes: payload.initiatorEphemeralPub,
            contextSecret: contextSecret,
            transcript: transcript
        )

        let inner = KeepTalkingTrustIdentityInner(
            nodeID: config.node,
            identityPublicKey: myLongTermPubKey
        )
        let sealedIdentity = try TrustHandshakeCrypto.seal(
            try JSONEncoder().encode(inner),
            with: sessionKey
        )

        let session = KeepTalkingPendingTrustSession(
            sessionID: payload.sessionID,
            role: .responder,
            peerNodeID: payload.from,
            contextID: payload.contextID,
            scope: scope,
            scopeWire: scopeWire,
            localEphemeralPriv: ephemeral.privateKey,
            localEphemeralPub: ephemeral.publicKeyBytes,
            peerEphemeralPub: payload.initiatorEphemeralPub,
            createdAt: Date(),
            continuation: nil,
            timeoutTask: makeTimeoutTask(sessionID: payload.sessionID)
        )
        trustQueue.sync { pendingTrustSessions[payload.sessionID] = session }

        let acceptEnvelope = KeepTalkingTrustAcceptPayload(
            sessionID: payload.sessionID,
            from: config.node,
            to: payload.from,
            contextID: payload.contextID,
            scope: scopeWire,
            responderEphemeralPub: ephemeral.publicKeyBytes,
            sealedIdentity: sealedIdentity
        )
        try rtcClient.sendEnvelope(acceptEnvelope)
    }

    private func onTrustAccept(_ payload: KeepTalkingTrustAcceptPayload) async throws {
        guard payload.to == config.node else { return }

        guard var session = trustQueue.sync(execute: { pendingTrustSessions[payload.sessionID] })
        else {
            throw KeepTalkingTrustError.sessionNotFound(payload.sessionID)
        }
        guard session.role == .initiator else {
            throw KeepTalkingTrustError.unexpectedRole
        }
        guard let contextSecret = try await loadGroupChatSecret(for: payload.contextID) else {
            throw KeepTalkingTrustError.contextSecretMissing(payload.contextID)
        }

        // The responder's chosen scope arrives here. Resolve into the
        // model + cache on the pending session so the rest of the flow
        // (transcript binding, persistence) sees the same value.
        let context = try await ensureContext(payload.contextID)
        let scope = Self.modelScope(from: payload.scope, context: context)
        session.scope = scope
        session.scopeWire = payload.scope
        trustQueue.sync { pendingTrustSessions[payload.sessionID] = session }

        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: session.sessionID,
            contextID: session.contextID,
            initiatorNodeID: config.node,
            responderNodeID: session.peerNodeID,
            initiatorEphemeralPub: session.localEphemeralPub,
            responderEphemeralPub: payload.responderEphemeralPub,
            scopeTag: payload.scope.rawValue
        )

        let sessionKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: session.localEphemeralPriv,
            remotePublicBytes: payload.responderEphemeralPub,
            contextSecret: contextSecret,
            transcript: transcript
        )

        let openedBytes = try TrustHandshakeCrypto.open(
            payload.sealedIdentity,
            with: sessionKey
        )
        let inner = try JSONDecoder().decode(
            KeepTalkingTrustIdentityInner.self,
            from: openedBytes
        )
        guard inner.nodeID == session.peerNodeID else {
            throw KeepTalkingTrustError.identityVerificationFailed
        }

        // Persist peer's long-term pubkey into our local trust graph,
        // creating our outgoing relation under the responder's chosen scope.
        let myLongTermPubKey = try await trust(
            node: session.peerNodeID,
            scope: scope
        )
        try await lure(
            node: session.peerNodeID,
            publicKey: inner.identityPublicKey,
            overwrite: true
        )
        let myInner = KeepTalkingTrustIdentityInner(
            nodeID: config.node,
            identityPublicKey: myLongTermPubKey
        )
        let mySealed = try TrustHandshakeCrypto.seal(
            try JSONEncoder().encode(myInner),
            with: sessionKey
        )

        let complete = KeepTalkingTrustCompletePayload(
            sessionID: session.sessionID,
            from: config.node,
            to: session.peerNodeID,
            contextID: session.contextID,
            sealedIdentity: mySealed
        )
        try rtcClient.sendEnvelope(complete)

        settleSession(
            sessionID: session.sessionID,
            outcome: .established(
                peerNodeID: session.peerNodeID,
                peerPublicKey: inner.identityPublicKey
            )
        )
    }

    private func onTrustComplete(_ payload: KeepTalkingTrustCompletePayload) async throws {
        guard payload.to == config.node else { return }

        guard let session = trustQueue.sync(execute: { pendingTrustSessions[payload.sessionID] })
        else {
            throw KeepTalkingTrustError.sessionNotFound(payload.sessionID)
        }
        guard session.role == .responder else {
            throw KeepTalkingTrustError.unexpectedRole
        }
        guard let peerEphemeralPub = session.peerEphemeralPub else {
            throw KeepTalkingTrustError.alreadySettled
        }
        guard let contextSecret = try await loadGroupChatSecret(for: payload.contextID) else {
            throw KeepTalkingTrustError.contextSecretMissing(payload.contextID)
        }

        guard let scopeWire = session.scopeWire else {
            throw KeepTalkingTrustError.alreadySettled
        }
        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: session.sessionID,
            contextID: session.contextID,
            initiatorNodeID: session.peerNodeID,
            responderNodeID: config.node,
            initiatorEphemeralPub: peerEphemeralPub,
            responderEphemeralPub: session.localEphemeralPub,
            scopeTag: scopeWire.rawValue
        )

        let sessionKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: session.localEphemeralPriv,
            remotePublicBytes: peerEphemeralPub,
            contextSecret: contextSecret,
            transcript: transcript
        )

        let openedBytes = try TrustHandshakeCrypto.open(
            payload.sealedIdentity,
            with: sessionKey
        )
        let inner = try JSONDecoder().decode(
            KeepTalkingTrustIdentityInner.self,
            from: openedBytes
        )
        guard inner.nodeID == session.peerNodeID else {
            throw KeepTalkingTrustError.identityVerificationFailed
        }

        try await lure(
            node: session.peerNodeID,
            publicKey: inner.identityPublicKey,
            overwrite: true
        )

        settleSession(
            sessionID: session.sessionID,
            outcome: .established(
                peerNodeID: session.peerNodeID,
                peerPublicKey: inner.identityPublicKey
            )
        )
    }

    private func onTrustReject(_ payload: KeepTalkingTrustRejectPayload) {
        guard payload.to == config.node else { return }
        settleSession(sessionID: payload.sessionID, outcome: .declined)
    }

    // MARK: Helpers

    func takePendingSession(sessionID: UUID) -> KeepTalkingPendingTrustSession? {
        trustQueue.sync {
            let session = pendingTrustSessions[sessionID]
            pendingTrustSessions[sessionID] = nil
            return session
        }
    }

    private func settleSession(sessionID: UUID, outcome: KeepTalkingTrustOutcome) {
        guard let session = takePendingSession(sessionID: sessionID) else { return }
        session.timeoutTask?.cancel()
        session.continuation?.resume(returning: outcome)
    }

    func makeTimeoutTask(sessionID: UUID) -> Task<Void, Never> {
        let ttl = Self.trustSessionTTLSeconds
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: ttl * 1_000_000_000)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            settleSessionIfPresent(sessionID: sessionID, outcome: .timedOut)
        }
    }

    private func settleSessionIfPresent(
        sessionID: UUID,
        outcome: KeepTalkingTrustOutcome
    ) {
        guard let session = takePendingSession(sessionID: sessionID) else { return }
        session.continuation?.resume(returning: outcome)
    }

    static func wireScope(from scope: KeepTalkingNodeTrustScope) -> KeepTalkingTrustScopeWire {
        switch scope {
            case .allContexts: return .allContexts
            case .context: return .thisContext
        }
    }

    static func modelScope(
        from wire: KeepTalkingTrustScopeWire,
        context: KeepTalkingContext
    ) -> KeepTalkingNodeTrustScope {
        switch wire {
            case .allContexts: return .allContexts
            case .thisContext: return .context(context)
        }
    }
}
