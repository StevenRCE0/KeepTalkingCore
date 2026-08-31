import Foundation

/// Wire-level encoding of `KeepTalkingNodeTrustScope` for transport over the
/// signaling channel. The full enum carries a `KeepTalkingContext` model
/// reference, which we don't ship across the wire — the recipient already
/// has the context locally and looks it up by `contextID`.
public enum KeepTalkingTrustScopeWire: String, Codable, Sendable {
    case allContexts
    case thisContext
}

public struct KeepTalkingTrustRequestPayload: Codable, Sendable {
    public let sessionID: UUID
    public let from: UUID
    public let to: UUID
    public let contextID: UUID
    public let initiatorEphemeralPub: Data
    /// Workspace-plan peer slot the initiator is claiming — carried from a
    /// slot invite link so the responder can bind the right role the moment
    /// trust lands. Advisory routing data, deliberately OUTSIDE the handshake
    /// transcript: it changes which slot the responder's app binds, never
    /// whether or how trust is established. Absent on links and builds that
    /// predate it (optional decode).
    public let slot: UUID?

    public init(
        sessionID: UUID,
        from: UUID,
        to: UUID,
        contextID: UUID,
        initiatorEphemeralPub: Data,
        slot: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.contextID = contextID
        self.initiatorEphemeralPub = initiatorEphemeralPub
        self.slot = slot
    }
}

extension KeepTalkingTrustRequestPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .trustRequest }

    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingTrustAcceptPayload: Codable, Sendable {
    public let sessionID: UUID
    public let from: UUID
    public let to: UUID
    public let contextID: UUID
    /// Trust scope chosen by the responder. The initiator persists its own
    /// outgoing relation against this scope after verifying the seal.
    public let scope: KeepTalkingTrustScopeWire
    public let responderEphemeralPub: Data
    /// AES-GCM-sealed inner payload containing the responder's long-term
    /// identity public key (Base64) and a signature/HMAC over the transcript.
    public let sealedIdentity: Data

    public init(
        sessionID: UUID,
        from: UUID,
        to: UUID,
        contextID: UUID,
        scope: KeepTalkingTrustScopeWire,
        responderEphemeralPub: Data,
        sealedIdentity: Data
    ) {
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.contextID = contextID
        self.scope = scope
        self.responderEphemeralPub = responderEphemeralPub
        self.sealedIdentity = sealedIdentity
    }
}

extension KeepTalkingTrustAcceptPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .trustAccept }

    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingTrustCompletePayload: Codable, Sendable {
    public let sessionID: UUID
    public let from: UUID
    public let to: UUID
    public let contextID: UUID
    public let sealedIdentity: Data

    public init(
        sessionID: UUID,
        from: UUID,
        to: UUID,
        contextID: UUID,
        sealedIdentity: Data
    ) {
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.contextID = contextID
        self.sealedIdentity = sealedIdentity
    }
}

extension KeepTalkingTrustCompletePayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .trustComplete }

    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

public struct KeepTalkingTrustRejectPayload: Codable, Sendable {
    public let sessionID: UUID
    public let from: UUID
    public let to: UUID
    public let contextID: UUID

    public init(sessionID: UUID, from: UUID, to: UUID, contextID: UUID) {
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.contextID = contextID
    }
}

extension KeepTalkingTrustRejectPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .trustReject }

    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

/// Inner plaintext sealed under the handshake session key. Carrying the
/// claimed sender's long-term identity public key — the recipient verifies
/// the seal opens (which proves DH knowledge + context-secret possession),
/// then stores `identityPublicKey` against the peer's relation.
public struct KeepTalkingTrustIdentityInner: Codable, Sendable {
    public let nodeID: UUID
    public let identityPublicKey: String

    public init(nodeID: UUID, identityPublicKey: String) {
        self.nodeID = nodeID
        self.identityPublicKey = identityPublicKey
    }
}

// MARK: - Handler registration helpers (mirror P2PSignal pattern)

extension KeepTalkingEnvelopeHandlers {
    public mutating func onTrustRequest(
        _ handler: @escaping @Sendable (KeepTalkingTrustRequestPayload) -> Void
    ) {
        register(KeepTalkingTrustRequestPayload.self, handler)
    }

    public mutating func onTrustAccept(
        _ handler: @escaping @Sendable (KeepTalkingTrustAcceptPayload) -> Void
    ) {
        register(KeepTalkingTrustAcceptPayload.self, handler)
    }

    public mutating func onTrustComplete(
        _ handler: @escaping @Sendable (KeepTalkingTrustCompletePayload) -> Void
    ) {
        register(KeepTalkingTrustCompletePayload.self, handler)
    }

    public mutating func onTrustReject(
        _ handler: @escaping @Sendable (KeepTalkingTrustRejectPayload) -> Void
    ) {
        register(KeepTalkingTrustRejectPayload.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onTrustRequest(
        _ handler: @escaping @Sendable (KeepTalkingTrustRequestPayload) async throws -> Void
    ) {
        register(KeepTalkingTrustRequestPayload.self, handler)
    }

    public mutating func onTrustAccept(
        _ handler: @escaping @Sendable (KeepTalkingTrustAcceptPayload) async throws -> Void
    ) {
        register(KeepTalkingTrustAcceptPayload.self, handler)
    }

    public mutating func onTrustComplete(
        _ handler: @escaping @Sendable (KeepTalkingTrustCompletePayload) async throws -> Void
    ) {
        register(KeepTalkingTrustCompletePayload.self, handler)
    }

    public mutating func onTrustReject(
        _ handler: @escaping @Sendable (KeepTalkingTrustRejectPayload) async throws -> Void
    ) {
        register(KeepTalkingTrustRejectPayload.self, handler)
    }
}
