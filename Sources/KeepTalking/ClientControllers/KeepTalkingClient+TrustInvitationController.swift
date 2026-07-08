import Crypto
import FluentKit
import Foundation

// MARK: - Public API surface

public struct KeepTalkingIncomingTrustRequest: Sendable {
    public let sessionID: UUID
    public let fromNodeID: UUID
    public let contextID: UUID

    public init(
        sessionID: UUID,
        fromNodeID: UUID,
        contextID: UUID
    ) {
        self.sessionID = sessionID
        self.fromNodeID = fromNodeID
        self.contextID = contextID
    }
}

/// The responder's verdict on an incoming trust request. Scope is chosen
/// by the responder at accept time — the request itself is scope-free, so
/// the responder controls how widely they trust the peer.
public enum KeepTalkingTrustDecision: Sendable {
    case accept(scope: KeepTalkingNodeTrustScope)
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

extension KeepTalkingClient {
    static let trustSessionTTLSeconds: UInt64 = 60

    // MARK: Public handshake API

    public func setIncomingTrustHandler(
        _ handler: KeepTalkingIncomingTrustHandler?
    ) {
        trustQueue.sync { incomingTrustHandler = handler }
    }

    /// Initiate a bidirectional trust handshake with `peerNodeID` over the
    /// shared `contextID`'s signaling channel.
    ///
    /// The request itself carries no scope — the responder picks how widely
    /// to trust the initiator at accept time, and the chosen scope flows
    /// back in `.trustAccept`. On success, both sides persist each other's
    /// long-term identity public key under the responder-chosen scope.
    @discardableResult
    public func requestTrust(
        with peerNodeID: UUID,
        in contextID: UUID
    ) async throws -> KeepTalkingTrustOutcome {
        _ = try await ensureContext(contextID)
        guard try await loadGroupChatSecret(for: contextID) != nil else {
            throw KeepTalkingTrustError.contextSecretMissing(contextID)
        }

        let ephemeral = TrustHandshakeCrypto.generateEphemeral()
        let sessionID = UUID()

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<KeepTalkingTrustOutcome, Error>) in
            let session = KeepTalkingPendingTrustSession(
                sessionID: sessionID,
                role: .initiator,
                peerNodeID: peerNodeID,
                contextID: contextID,
                scope: nil,
                scopeWire: nil,
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
                initiatorEphemeralPub: ephemeral.publicKeyBytes
            )

            do {
                try rtcClient.sendEnvelope(payload)
            } catch {
                _ = takePendingSession(sessionID: sessionID)?.timeoutTask?.cancel()
                trustQueue.sync { pendingTrustSessions[sessionID] = nil }
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: Trust invitation queue

    @discardableResult
    public func upsertTrustInvitation(
        contextID: UUID,
        inviterNodeID: UUID,
        recipientNodeID: UUID,
        direction: KeepTalkingTrustInvitationDirection,
        status: KeepTalkingTrustInvitationStatus = .pending,
        lastError: String? = nil
    ) async throws -> KeepTalkingTrustInvitation {
        try await Self.upsertTrustInvitation(
            contextID: contextID,
            inviterNodeID: inviterNodeID,
            recipientNodeID: recipientNodeID,
            direction: direction,
            status: status,
            lastError: lastError,
            on: localStore.database
        )
    }

    @discardableResult
    public static func upsertTrustInvitation(
        contextID: UUID,
        inviterNodeID: UUID,
        recipientNodeID: UUID,
        direction: KeepTalkingTrustInvitationDirection,
        status: KeepTalkingTrustInvitationStatus = .pending,
        lastError: String? = nil,
        on database: any Database
    ) async throws -> KeepTalkingTrustInvitation {
        let context = try await ensureContext(contextID, on: database)
        let now = Date()

        if let existing = try await KeepTalkingTrustInvitation.query(on: database)
            .filter(\.$context.$id, .equal, contextID)
            .filter(\.$inviterNodeID, .equal, inviterNodeID)
            .filter(\.$recipientNodeID, .equal, recipientNodeID)
            .filter(\.$direction, .equal, direction)
            .first()
        {
            existing.status = status
            existing.updatedAt = now
            existing.lastError = lastError
            existing.resolvedAt = status.isTerminal ? now : nil
            try await existing.save(on: database)
            return existing
        }

        let invitation = try KeepTalkingTrustInvitation(
            context: context,
            inviterNodeID: inviterNodeID,
            recipientNodeID: recipientNodeID,
            direction: direction,
            status: status,
            createdAt: now,
            updatedAt: now,
            resolvedAt: status.isTerminal ? now : nil,
            lastError: lastError
        )
        try await invitation.save(on: database)
        return invitation
    }

    @discardableResult
    public static func markTrustInvitation(
        _ invitationID: UUID,
        status: KeepTalkingTrustInvitationStatus,
        lastError: String? = nil,
        on database: any Database
    ) async throws -> KeepTalkingTrustInvitation? {
        guard
            let invitation = try await KeepTalkingTrustInvitation.find(
                invitationID,
                on: database
            )
        else {
            return nil
        }
        invitation.status = status
        invitation.updatedAt = Date()
        invitation.resolvedAt = status.isTerminal ? invitation.updatedAt : nil
        invitation.lastError = lastError
        try await invitation.save(on: database)
        return invitation
    }

    public static func pendingOutgoingTrustInvitation(
        from inviterNodeID: UUID,
        to recipientNodeID: UUID,
        in contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingTrustInvitation? {
        try await KeepTalkingTrustInvitation.query(on: database)
            .filter(\.$context.$id, .equal, contextID)
            .filter(\.$inviterNodeID, .equal, inviterNodeID)
            .filter(\.$recipientNodeID, .equal, recipientNodeID)
            .filter(\.$direction, .equal, .outgoing)
            .filter(\.$status, .equal, .pending)
            .first()
    }

    public static func trustAlreadyCovers(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        contextID: UUID,
        on database: any Database
    ) async throws -> Bool {
        let context = try await ensureContext(contextID, on: database)
        return try await preferredTrustedRelation(
            from: fromNodeID,
            to: toNodeID,
            allowing: context,
            on: database
        ) != nil
    }

    func ensureContext(_ contextID: UUID) async throws -> KeepTalkingContext {
        try await Self.ensureContext(contextID, on: localStore.database)
    }

    static func ensureContext(
        _ contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingContext {
        if let context = try await KeepTalkingContext.find(contextID, on: database) {
            return context
        }
        let context = KeepTalkingContext(id: contextID)
        try await context.save(on: database)
        return context
    }
}

extension KeepTalkingTrustInvitationStatus {
    fileprivate var isTerminal: Bool {
        switch self {
            case .pending, .accepted:
                return false
            case .skipped, .declined, .established, .failed:
                return true
        }
    }
}
