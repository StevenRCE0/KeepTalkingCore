import Foundation

/// Announces that `from` has joined voice in `contextID`. Broadcast —
/// peers use it to populate their own participant set without polling,
/// and as a trigger to start the SDP handshake when they too are in the
/// call.
public struct KeepTalkingVoiceCallStartedPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID

    public init(from: UUID, contextID: UUID) {
        self.from = from
        self.contextID = contextID
    }
}

extension KeepTalkingVoiceCallStartedPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallStarted }
    public var participantNodeIDs: [UUID] { [from] }
    public var transportContextID: UUID? { contextID }
}

/// Announces that `from` has hung up. Broadcast — receivers tear down
/// any ICE agent they had built for this peer and remove them from the
/// participant set.
public struct KeepTalkingVoiceCallEndedPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID

    public init(from: UUID, contextID: UUID) {
        self.from = from
        self.contextID = contextID
    }
}

extension KeepTalkingVoiceCallEndedPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallEnded }
    public var participantNodeIDs: [UUID] { [from] }
    public var transportContextID: UUID? { contextID }
}

/// Directed: SDP between two specific call participants. Replaces the
/// raw `.p2pSignal` SFU channel that the lab previously used for SDP
/// — keeps signaling on the same encrypted, addressable envelope
/// stream as the rest of the call presence.
///
/// The receiver decides offerer vs. answerer by comparing node IDs, so
/// signaling does not depend on a second SFU identity.
public struct KeepTalkingVoiceCallSignalPayload: Codable, Sendable {
    public let from: UUID
    public let to: UUID
    public let contextID: UUID
    public let sdp: String

    public init(from: UUID, to: UUID, contextID: UUID, sdp: String) {
        self.from = from
        self.to = to
        self.contextID = contextID
        self.sdp = sdp
    }
}

extension KeepTalkingVoiceCallSignalPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallSignal }
    public var participantNodeIDs: [UUID] { [from] }
    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

// MARK: - Handler registration helpers (mirror trust/p2pSignal pattern)

extension KeepTalkingEnvelopeHandlers {
    public mutating func onVoiceCallStarted(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallStartedPayload) -> Void
    ) {
        register(KeepTalkingVoiceCallStartedPayload.self, handler)
    }

    public mutating func onVoiceCallEnded(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallEndedPayload) -> Void
    ) {
        register(KeepTalkingVoiceCallEndedPayload.self, handler)
    }

    public mutating func onVoiceCallSignal(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallSignalPayload) -> Void
    ) {
        register(KeepTalkingVoiceCallSignalPayload.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onVoiceCallStarted(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallStartedPayload) async throws -> Void
    ) {
        register(KeepTalkingVoiceCallStartedPayload.self, handler)
    }

    public mutating func onVoiceCallEnded(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallEndedPayload) async throws -> Void
    ) {
        register(KeepTalkingVoiceCallEndedPayload.self, handler)
    }

    public mutating func onVoiceCallSignal(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallSignalPayload) async throws -> Void
    ) {
        register(KeepTalkingVoiceCallSignalPayload.self, handler)
    }

    /// Wires the started/ended pair into the client's bystander presence
    /// registry. Signals are intentionally NOT routed here — those are
    /// addressed to the local voice session, not to chat-level
    /// observers, and the voice session owns its own dispatch path
    /// via its dedicated SFU connection.
    mutating func registerVoiceCallHandlers(for client: KeepTalkingClient) {
        onVoiceCallStarted { [weak client] started in
            client?.voiceCallPresence.recordStarted(
                contextID: started.contextID,
                nodeID: started.from
            )
        }
        onVoiceCallEnded { [weak client] ended in
            client?.voiceCallPresence.recordEnded(
                contextID: ended.contextID,
                nodeID: ended.from
            )
        }
    }
}
