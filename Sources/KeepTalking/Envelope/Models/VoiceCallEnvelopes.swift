import Foundation

/// Announces that `from` has joined voice in `contextID`. Broadcast —
/// peers use it to populate their own participant set without polling,
/// and as a trigger to start the SDP handshake when they too are in the
/// call.
public struct KeepTalkingVoiceCallStartedPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    /// The sender's *effective* transport at the moment they announced —
    /// `"p2p"` or `"sfu"`. Lets the receiver detect a mismatch (one side
    /// doing ICE while the other only relays) and converge before the
    /// call half-opens. Optional so a `started` from a peer that predates
    /// this field decodes cleanly; a `nil` value is treated as P2P-capable.
    public let effectiveTransport: String?
    /// The shared voice-session id. All participants converge on this as the
    /// key for the in-memory call record + the transcript lines. Optional so a
    /// `started` from a peer that predates this field decodes cleanly.
    public let sessionID: UUID?

    public init(
        from: UUID,
        contextID: UUID,
        effectiveTransport: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.from = from
        self.contextID = contextID
        self.effectiveTransport = effectiveTransport
        self.sessionID = sessionID
    }
}

extension KeepTalkingVoiceCallStartedPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallStarted }
    public var transportContextID: UUID? { contextID }
}

/// Announces that `from` has hung up. Broadcast — receivers tear down
/// any ICE agent they had built for this peer and remove them from the
/// participant set.
public struct KeepTalkingVoiceCallEndedPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    /// The shared voice-session id this hangup pertains to. Optional for
    /// back-compat decode.
    public let sessionID: UUID?

    public init(from: UUID, contextID: UUID, sessionID: UUID? = nil) {
        self.from = from
        self.contextID = contextID
        self.sessionID = sessionID
    }
}

extension KeepTalkingVoiceCallEndedPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallEnded }
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
    /// The shared voice-session id this handshake belongs to. Optional for
    /// back-compat decode.
    public let sessionID: UUID?

    public init(from: UUID, to: UUID, contextID: UUID, sdp: String, sessionID: UUID? = nil) {
        self.from = from
        self.to = to
        self.contextID = contextID
        self.sdp = sdp
        self.sessionID = sessionID
    }
}

extension KeepTalkingVoiceCallSignalPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallSignal }
    public var targetPeerNodeID: UUID? { to }
    public var transportContextID: UUID? { contextID }
}

/// Broadcast: one line of a call's federated transcript, authored by the
/// speaking node (`from` is always the speaker — a node only ever publishes its
/// own mic). Rides the reliable context transport, NOT the lossy voice-UDP path;
/// reconciled/backfilled as a tuned resource on `ContextSyncController`.
/// Receivers persist it into the flat `kt_voice_transcript_lines` table keyed by
/// `sessionID`; the call itself is in-memory only.
public struct KeepTalkingVoiceCallTranscriptLinePayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    /// The shared voice-session id == the transcript lines' `session` key.
    public let sessionID: UUID
    public let lineID: UUID
    /// Per-(session, author) monotonic cursor for incremental sync + dedup.
    public let sequence: Int
    public let text: String
    /// Who spoke: `.node(id)` for a human's mic, `.autonomous(name:node:)` for the
    /// agent — the `name` carries the wake keyword so peers can label it directly.
    public let sender: KeepTalkingContextMessage.Sender
    public let timestampMs: UInt64

    public init(
        from: UUID,
        contextID: UUID,
        sessionID: UUID,
        lineID: UUID,
        sequence: Int,
        text: String,
        sender: KeepTalkingContextMessage.Sender,
        timestampMs: UInt64
    ) {
        self.from = from
        self.contextID = contextID
        self.sessionID = sessionID
        self.lineID = lineID
        self.sequence = sequence
        self.text = text
        self.sender = sender
        self.timestampMs = timestampMs
    }
}

extension KeepTalkingVoiceCallTranscriptLinePayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallTranscriptLine }
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

    public mutating func onVoiceCallTranscriptLine(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallTranscriptLinePayload) -> Void
    ) {
        register(KeepTalkingVoiceCallTranscriptLinePayload.self, handler)
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

    public mutating func onVoiceCallTranscriptLine(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallTranscriptLinePayload) async throws -> Void
    ) {
        register(KeepTalkingVoiceCallTranscriptLinePayload.self, handler)
    }

    /// Variant whose handler reports whether the line was newly applied.
    ///
    /// `.voiceCallTranscriptLine` is the third fan-out-eligible kind, so like
    /// messages and attachments it can be delivered twice and must not
    /// re-notify on the copy that changed nothing.
    public mutating func onVoiceCallTranscriptLine(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallTranscriptLinePayload) async throws -> Bool
    ) {
        registerReportingApplied(
            KeepTalkingVoiceCallTranscriptLinePayload.self,
            handler
        )
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
            // If we're still in this call, re-assert our presence so the leaver
            // doesn't seal it out from under us. (Accurate only because the client
            // clears `activeVoiceSession` on stop — a left node won't re-assert.)
            client?.handleVoiceCallEndedProbe(ended)
        }
        onVoiceCallTranscriptLine { [weak client] line -> Bool in
            // No client left to apply it to — fall back to the unhandled-kind
            // default and publish.
            try await client?.handleIncomingVoiceTranscriptLine(line) ?? true
        }
    }
}
