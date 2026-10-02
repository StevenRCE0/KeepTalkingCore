import Foundation

/// Announces that `from` has joined voice in `contextID`. Broadcast —
/// peers use it to populate their own participant set without polling.
public struct KeepTalkingVoiceCallStartedPayload: Codable, Sendable {
    public let from: UUID
    public let contextID: UUID
    /// The shared voice-session id. All participants converge on this as the
    /// key for the in-memory call record, the transcript lines and the audio
    /// key. Optional so a bystander's presence registry decodes any
    /// `started`.
    public let sessionID: UUID?

    public init(from: UUID, contextID: UUID, sessionID: UUID? = nil) {
        self.from = from
        self.contextID = contextID
        self.sessionID = sessionID
    }
}

extension KeepTalkingVoiceCallStartedPayload: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .voiceCallStarted }
    public var transportContextID: UUID? { contextID }
}

/// Announces that `from` has hung up. Broadcast — receivers remove them
/// from the participant set.
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

/// Broadcast: one line of a call's federated transcript, authored by the
/// speaking node (`from` is always the speaker — a node only ever publishes its
/// own mic). Rides the reliable context transport, NOT the lossy datagrams;
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

// MARK: - Handler registration helpers

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

    public mutating func onVoiceCallTranscriptLine(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallTranscriptLinePayload) async throws -> Void
    ) {
        register(KeepTalkingVoiceCallTranscriptLinePayload.self, handler)
    }

    /// Variant whose handler reports whether the line was newly applied.
    ///
    /// `.voiceCallTranscriptLine` is idempotent, so like messages and
    /// attachments it can be delivered twice (a resync) and must not re-notify
    /// on the copy that changed nothing.
    public mutating func onVoiceCallTranscriptLine(
        _ handler: @escaping @Sendable (KeepTalkingVoiceCallTranscriptLinePayload) async throws -> Bool
    ) {
        registerReportingApplied(
            KeepTalkingVoiceCallTranscriptLinePayload.self,
            handler
        )
    }

    /// Wires the started/ended pair into the client's bystander presence
    /// registry. The local voice session sees every envelope on its own (see
    /// `handleIncomingEnvelope`).
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
