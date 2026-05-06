import CryptoKit
import FluentKit
import Foundation

// MARK: - Public API surface

public struct KeepTalkingIncomingTrustRequest: Sendable {
    public let sessionID: UUID
    public let fromNodeID: UUID
    public let contextID: UUID
    public let scope: KeepTalkingNodeTrustScope

    public init(
        sessionID: UUID,
        fromNodeID: UUID,
        contextID: UUID,
        scope: KeepTalkingNodeTrustScope
    ) {
        self.sessionID = sessionID
        self.fromNodeID = fromNodeID
        self.contextID = contextID
        self.scope = scope
    }
}

public enum KeepTalkingTrustDecision: Sendable {
    case accept
    case decline
}

public enum KeepTalkingTrustOutcome: Sendable {
    /// Trust handshake completed. Peer's long-term identity public key has
    /// been persisted into the local trust graph.
    case established(peerNodeID: UUID, peerPublicKey: String)
    /// Peer declined the request.
    case declined
    /// Pending session timed out (peer didn't respond within TTL).
    case timedOut
}

public typealias KeepTalkingIncomingTrustHandler =
    @Sendable (KeepTalkingIncomingTrustRequest) async -> KeepTalkingTrustDecision

public enum KeepTalkingTrustError: LocalizedError {
    case contextSecretMissing(UUID)
    case sessionNotFound(UUID)
    case unexpectedRole
    case alreadySettled
    case identityVerificationFailed
    case noIncomingHandler

    public var errorDescription: String? {
        switch self {
            case .contextSecretMissing(let id):
                return "Trust handshake: missing group secret for context \(id.uuidString.lowercased())."
            case .sessionNotFound(let id):
                return "Trust handshake: no pending session \(id.uuidString.lowercased())."
            case .unexpectedRole:
                return "Trust handshake: envelope received in wrong role."
            case .alreadySettled:
                return "Trust handshake: session already settled."
            case .identityVerificationFailed:
                return "Trust handshake: peer identity payload failed to verify."
            case .noIncomingHandler:
                return "Trust handshake: no incoming-request handler registered."
        }
    }
}

// MARK: - Internal pending-session state

enum KeepTalkingPendingTrustRole: Sendable {
    case initiator
    case responder
}

struct KeepTalkingPendingTrustSession: Sendable {
    let sessionID: UUID
    let role: KeepTalkingPendingTrustRole
    let peerNodeID: UUID
    let contextID: UUID
    let scope: KeepTalkingNodeTrustScope
    let scopeWire: KeepTalkingTrustScopeWire
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

    private static let trustSessionTTLSeconds: UInt64 = 60

    // MARK: Public API

    public func setIncomingTrustHandler(
        _ handler: KeepTalkingIncomingTrustHandler?
    ) {
        trustQueue.sync { incomingTrustHandler = handler }
    }

    /// Initiate a bidirectional trust handshake with `peerNodeID` over the
    /// shared `contextID`'s signaling channel.
    ///
    /// On success, both sides will have persisted each other's long-term
    /// identity public key in their local trust graph (`KeepTalkingNodeRelation`
    /// + `KeepTalkingNodeIdentityKey`) under the requested `scope`.
    @discardableResult
    public func requestTrust(
        with peerNodeID: UUID,
        in contextID: UUID,
        scope: KeepTalkingNodeTrustScope
    ) async throws -> KeepTalkingTrustOutcome {
        let context = try await ensure(contextID, for: KeepTalkingContext.self)
        guard try await loadGroupChatSecret(for: contextID) != nil else {
            throw KeepTalkingTrustError.contextSecretMissing(contextID)
        }

        // Make sure we have our own outgoing relation + keypair for this peer
        // so we can publish our long-term pubkey at the .trustAccept /
        // .trustComplete step. This is a no-op if already trusted.
        _ = try await trust(node: peerNodeID, scope: scope)

        let ephemeral = TrustHandshakeCrypto.generateEphemeral()
        let sessionID = UUID()
        let scopeWire = Self.wireScope(from: scope)

        let outcome = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<KeepTalkingTrustOutcome, Error>) in
            let session = KeepTalkingPendingTrustSession(
                sessionID: sessionID,
                role: .initiator,
                peerNodeID: peerNodeID,
                contextID: contextID,
                scope: scope,
                scopeWire: scopeWire,
                localEphemeralPriv: ephemeral.privateKey,
                localEphemeralPub: ephemeral.publicKeyBytes,
                peerEphemeralPub: nil,
                createdAt: Date(),
                continuation: continuation,
                timeoutTask: makeTimeoutTask(sessionID: sessionID)
            )
            trustQueue.sync { pendingTrustSessions[sessionID] = session }

            let payload = KeepTalkingTrustRequestPayload(
                sessionID: sessionID,
                from: config.node,
                to: peerNodeID,
                contextID: contextID,
                scope: scopeWire,
                initiatorEphemeralPub: ephemeral.publicKeyBytes
            )

            do {
                try rtcClient.sendEnvelope(payload)
            } catch {
                _ = takePendingSession(sessionID: sessionID)?.timeoutTask?.cancel()
                trustQueue.sync { pendingTrustSessions[sessionID] = nil }
                continuation.resume(throwing: error)
            }
            _ = context  // silence unused
        }
        return outcome
    }

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

        let context = try await ensure(payload.contextID, for: KeepTalkingContext.self)
        guard let contextSecret = try await loadGroupChatSecret(for: payload.contextID) else {
            throw KeepTalkingTrustError.contextSecretMissing(payload.contextID)
        }

        let scope = Self.modelScope(from: payload.scope, context: context)

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
            contextID: payload.contextID,
            scope: scope
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
            case .accept:
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
        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: payload.sessionID,
            contextID: payload.contextID,
            initiatorNodeID: payload.from,
            responderNodeID: config.node,
            initiatorEphemeralPub: payload.initiatorEphemeralPub,
            responderEphemeralPub: ephemeral.publicKeyBytes,
            scopeTag: payload.scope.rawValue
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
            scopeWire: payload.scope,
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
            responderEphemeralPub: ephemeral.publicKeyBytes,
            sealedIdentity: sealedIdentity
        )
        try rtcClient.sendEnvelope(acceptEnvelope)
    }

    private func onTrustAccept(_ payload: KeepTalkingTrustAcceptPayload) async throws {
        guard payload.to == config.node else { return }

        guard let session = trustQueue.sync(execute: { pendingTrustSessions[payload.sessionID] })
        else {
            throw KeepTalkingTrustError.sessionNotFound(payload.sessionID)
        }
        guard session.role == .initiator else {
            throw KeepTalkingTrustError.unexpectedRole
        }
        guard let contextSecret = try await loadGroupChatSecret(for: payload.contextID) else {
            throw KeepTalkingTrustError.contextSecretMissing(payload.contextID)
        }

        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: session.sessionID,
            contextID: session.contextID,
            initiatorNodeID: config.node,
            responderNodeID: session.peerNodeID,
            initiatorEphemeralPub: session.localEphemeralPub,
            responderEphemeralPub: payload.responderEphemeralPub,
            scopeTag: session.scopeWire.rawValue
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

        // Persist peer's long-term pubkey into our local trust graph.
        try await lure(
            node: session.peerNodeID,
            publicKey: inner.identityPublicKey,
            overwrite: true
        )

        // Now seal our own identity for the .trustComplete step.
        let myLongTermPubKey = try await trust(
            node: session.peerNodeID,
            scope: session.scope
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

        let transcript = TrustHandshakeCrypto.transcript(
            sessionID: session.sessionID,
            contextID: session.contextID,
            initiatorNodeID: session.peerNodeID,
            responderNodeID: config.node,
            initiatorEphemeralPub: peerEphemeralPub,
            responderEphemeralPub: session.localEphemeralPub,
            scopeTag: session.scopeWire.rawValue
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

    private func takePendingSession(sessionID: UUID) -> KeepTalkingPendingTrustSession? {
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

    private func makeTimeoutTask(sessionID: UUID) -> Task<Void, Never> {
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
