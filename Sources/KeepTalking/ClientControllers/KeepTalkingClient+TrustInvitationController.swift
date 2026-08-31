import Crypto
import FluentKit
import Foundation

// MARK: - Public API surface

public struct KeepTalkingIncomingTrustRequest: Sendable {
    public let sessionID: UUID
    public let fromNodeID: UUID
    public let contextID: UUID
    /// Workspace-plan peer slot the initiator claims (from a slot invite
    /// link), when they sent one — lets the host resolve which role to bind
    /// before deciding, instead of correlating after the handshake.
    public let slotID: UUID?

    public init(
        sessionID: UUID,
        fromNodeID: UUID,
        contextID: UUID,
        slotID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.fromNodeID = fromNodeID
        self.contextID = contextID
        self.slotID = slotID
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
    /// `claimingSlot` names the workspace-plan peer slot this request redeems
    /// (from a slot invite link); it rides the request payload so the
    /// responder binds the right role on completion.
    @discardableResult
    public func requestTrust(
        with peerNodeID: UUID,
        in contextID: UUID,
        claimingSlot slotID: UUID? = nil
    ) async throws -> KeepTalkingTrustOutcome {
        try await ensureContext(contextID)
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
                initiatorEphemeralPub: ephemeral.publicKeyBytes,
                slot: slotID
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
        let now = Date.now

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
            try await applyTrustInvitationRelationSideEffects(
                context: context,
                inviterNodeID: inviterNodeID,
                recipientNodeID: recipientNodeID,
                direction: direction,
                status: status,
                on: database
            )
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
        try await applyTrustInvitationRelationSideEffects(
            context: context,
            inviterNodeID: inviterNodeID,
            recipientNodeID: recipientNodeID,
            direction: direction,
            status: status,
            on: database
        )
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
        invitation.updatedAt = Date.now
        invitation.resolvedAt = status.isTerminal ? invitation.updatedAt : nil
        invitation.lastError = lastError
        try await invitation.save(on: database)
        let context = try await ensureContext(invitation.$context.id, on: database)
        try await applyTrustInvitationRelationSideEffects(
            context: context,
            inviterNodeID: invitation.inviterNodeID,
            recipientNodeID: invitation.recipientNodeID,
            direction: invitation.direction,
            status: status,
            on: database
        )
        return invitation
    }

    /// Re-establishes the invariant that a *pending outgoing* invitation exists
    /// only while the invitee still holds at least one grant in that context.
    ///
    /// An outgoing invitation is never a standalone intent — it is created as a
    /// precondition of a grant to a peer who isn't trusted yet
    /// (`stageActionPermissionWithTrustInvitation` and its alias twin). Once the
    /// last grant is revoked the invitation has nothing left to authorise, so
    /// it is deleted along with the pre-trusted context it introduced.
    ///
    /// This matters beyond tidiness: a pending outgoing invitation is a standing
    /// auto-accept for that peer's inbound trust handshake, so a stale row would
    /// silently establish trust after the user revoked everything.
    ///
    /// Pass `context: nil` to sweep every context in which the pair currently
    /// has a pending invitation — used by all-context revokes.
    ///
    /// Terminal rows (declined/failed/established/skipped) are history and are
    /// left untouched, as are incoming invitations, which record a handshake
    /// rather than authorise one.
    @discardableResult
    public static func reconcilePendingTrustInvitations(
        from inviterNodeID: UUID,
        to recipientNodeID: UUID,
        in context: KeepTalkingContext?,
        on database: any Database
    ) async throws -> Int {
        guard inviterNodeID != recipientNodeID else { return 0 }

        var query = KeepTalkingTrustInvitation.query(on: database)
            .filter(\.$inviterNodeID, .equal, inviterNodeID)
            .filter(\.$recipientNodeID, .equal, recipientNodeID)
            .filter(\.$direction, .equal, .outgoing)
            .filter(\.$status, .equal, .pending)
        if let contextID = context?.id {
            query = query.filter(\.$context.$id, .equal, contextID)
        }

        var removed = 0
        for invitation in try await query.all() {
            let invitationContext = KeepTalkingContext(id: invitation.$context.id)
            if try await holdsAnyGrant(
                from: inviterNodeID,
                to: recipientNodeID,
                in: invitationContext,
                on: database
            ) {
                continue
            }

            try await invitation.delete(on: database)
            try await removePreTrustedContext(
                from: inviterNodeID,
                to: recipientNodeID,
                context: invitationContext,
                on: database
            )
            removed += 1
        }
        return removed
    }

    /// Drops every invitation anchored to `nodeID` in either role.
    ///
    /// Issued explicitly rather than relying on the schema's `onDelete` rules so
    /// the result holds whether or not the SQLite connection has foreign-key
    /// enforcement on — matching `deleteNodeLocally`, whose teardown this
    /// completes.
    public static func deleteTrustInvitations(
        involving nodeID: UUID,
        on database: any Database
    ) async throws {
        try await KeepTalkingTrustInvitation.query(on: database)
            .group(.or) { group in
                group.filter(\.$inviterNodeID, .equal, nodeID)
                group.filter(\.$recipientNodeID, .equal, nodeID)
            }
            .delete()
    }

    /// Withdraws the pending outgoing invitation for a pair, leaving any grants
    /// they hold alone.
    ///
    /// This is the one direction in which the grant/invitation invariant may be
    /// broken deliberately, and it is the safe one: the peer keeps what they
    /// were given but loses the standing auto-accept, so their next inbound
    /// trust handshake prompts rather than resolving silently. The reverse —
    /// an invitation outliving its grants — stays impossible, since that would
    /// leave an auto-accept behind with nothing to authorise.
    ///
    /// Pass `context: nil` to withdraw across every context, which is what
    /// tearing down the relation itself calls for.
    public static func deletePendingOutgoingTrustInvitations(
        from inviterNodeID: UUID,
        to recipientNodeID: UUID,
        in context: KeepTalkingContext? = nil,
        on database: any Database
    ) async throws {
        var query = KeepTalkingTrustInvitation.query(on: database)
            .filter(\.$inviterNodeID, .equal, inviterNodeID)
            .filter(\.$recipientNodeID, .equal, recipientNodeID)
            .filter(\.$direction, .equal, .outgoing)
            .filter(\.$status, .equal, .pending)
        if let contextID = context?.id {
            query = query.filter(\.$context.$id, .equal, contextID)
        }
        try await query.delete()
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

    @discardableResult
    func ensureContext(_ contextID: UUID) async throws -> KeepTalkingContext {
        try await Self.ensureContext(contextID, on: localStore.database)
    }

    private static func applyTrustInvitationRelationSideEffects(
        context: KeepTalkingContext,
        inviterNodeID: UUID,
        recipientNodeID: UUID,
        direction: KeepTalkingTrustInvitationDirection,
        status: KeepTalkingTrustInvitationStatus,
        on database: any Database
    ) async throws {
        guard direction == .outgoing, inviterNodeID != recipientNodeID else {
            return
        }

        switch status {
            case .pending:
                try await ensurePreTrustedRelation(
                    from: inviterNodeID,
                    to: recipientNodeID,
                    in: context,
                    on: database
                )
            case .declined, .failed:
                try await removePreTrustedContext(
                    from: inviterNodeID,
                    to: recipientNodeID,
                    context: context,
                    on: database
                )
            case .accepted, .skipped, .established:
                break
        }
    }

    private static func ensurePreTrustedRelation(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        in context: KeepTalkingContext,
        on database: any Database
    ) async throws {
        let relations = try await relations(
            from: fromNodeID,
            to: toNodeID,
            on: database
        )

        if relations.contains(where: { $0.relationship.isTrustedOrOwner }) {
            return
        }

        if let relation = relations.first(where: {
            if case .preTrusted = $0.relationship {
                return true
            }
            return false
        }) {
            guard case .preTrusted(let contexts) = relation.relationship else {
                return
            }
            relation.relationship = .preTrusted(
                contexts.merging(context).sortedByID()
            )
            try await relation.save(on: database)
            return
        }

        if let relation = relations.first(where: { $0.relationship == .pending }) {
            relation.relationship = .preTrusted([context])
            try await relation.save(on: database)
            return
        }

        let fromNode = try await ensureNode(fromNodeID, on: database)
        let toNode = try await ensureNode(toNodeID, on: database)
        let relation = try KeepTalkingNodeRelation(
            from: fromNode,
            to: toNode,
            relationship: .preTrusted([context])
        )
        try await relation.save(on: database)
    }

    private static func removePreTrustedContext(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        context: KeepTalkingContext,
        on database: any Database
    ) async throws {
        let relations = try await relations(
            from: fromNodeID,
            to: toNodeID,
            on: database
        )

        for relation in relations {
            guard case .preTrusted(let contexts) = relation.relationship else {
                continue
            }

            let remaining = contexts.filter { $0 != context }.sortedByID()
            if remaining.isEmpty {
                try await retireEmptyPreTrustedRelation(relation, on: database)
            } else {
                relation.relationship = .preTrusted(remaining)
                try await relation.save(on: database)
            }
        }
    }

    private static func retireEmptyPreTrustedRelation(
        _ relation: KeepTalkingNodeRelation,
        on database: any Database
    ) async throws {
        let hasActionRelations =
            try await relation.$actionRelations.query(
                on: database
            ).first() != nil
        let hasAliasRelations =
            try await relation.$aliases.$pivots.query(
                on: database
            ).first() != nil
        let hasIdentityKeys =
            try await relation.$identityKeys.query(
                on: database
            ).first() != nil

        if hasActionRelations || hasAliasRelations || hasIdentityKeys {
            relation.relationship = .pending
            try await relation.save(on: database)
        } else {
            try await relation.delete(on: database)
        }
    }

    private static func relations(
        from fromNodeID: UUID,
        to toNodeID: UUID,
        on database: any Database
    ) async throws -> [KeepTalkingNodeRelation] {
        try await KeepTalkingNodeRelation.query(on: database)
            .filter(\.$from.$id, .equal, fromNodeID)
            .filter(\.$to.$id, .equal, toNodeID)
            .all()
            .sorted {
                let lhs = relationPriority($0.relationship)
                let rhs = relationPriority($1.relationship)
                return lhs == rhs
                    ? ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                    : lhs > rhs
            }
    }

    private static func ensureNode(
        _ nodeID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingNode {
        if let node = try await KeepTalkingNode.find(nodeID, on: database) {
            return node
        }

        let node = KeepTalkingNode(id: nodeID)
        try await node.save(on: database)
        return node
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

extension Array where Element == KeepTalkingContext {
    fileprivate func merging(_ context: KeepTalkingContext) -> [KeepTalkingContext] {
        contains(context) ? self : self + [context]
    }

    fileprivate func sortedByID() -> [KeepTalkingContext] {
        sorted { lhs, rhs in
            (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
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
