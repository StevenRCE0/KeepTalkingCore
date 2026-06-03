import FluentKit
import Foundation

/// How a transcript line was produced.
public enum KeepTalkingVoiceTranscriptSource: String, Codable, Sendable, CaseIterable {
    /// On-device speech recognition (SFSpeechRecognizer).
    case local
    /// Server-side transcription from a realtime/audio API (e.g. the agent's
    /// own spoken reply).
    case realtime
}

/// One line of a voice call's federated transcript — **the durable unit**.
///
/// Authored by exactly one node: `author` is always the speaker, and a node only
/// ever publishes lines for its *own* mic. That's the integrity property of the
/// shared transcript — nobody can put words in another's mouth.
///
/// **A flat, standalone table.** `session` and `context` are plain id fields, NOT
/// Fluent `@Parent` relations: voice calls live only in memory (there is no
/// `kt_voice_calls` table), so a line's persistence never depends on a parent
/// row existing. Kept out of `KeepTalkingContextMessage` so the heavy per-message
/// pipeline (outbox, indexing, snapshot, agent-context inclusion) never touches
/// this high-volume stream; it syncs as a tuned resource on `ContextSyncController`.
public final class KeepTalkingVoiceTranscriptLine: Model, @unchecked Sendable {
    public static let schema = "kt_voice_transcript_lines"

    @ID(key: .id)
    public var id: UUID?

    /// The shared voice-session id this line belongs to. Plain field (no FK) so
    /// the line stands alone — the in-memory call record is keyed by this id.
    @Field(key: "session")
    public var sessionID: UUID

    /// Denormalised context id (plain field, no FK) so lines can be scoped/queried
    /// by context without a join and without depending on the context row.
    @Field(key: "context")
    public var contextID: UUID

    /// The node that spoke and transcribed this line (the sole author).
    @Field(key: "author")
    public var author: UUID

    @Field(key: "text")
    public var text: String

    /// Who produced this line, reusing `KeepTalkingContextMessage.Sender`:
    /// `.node(id)` for a human's mic, `.autonomous(name:node:)` for the agent's
    /// spoken reply — the `name` carries the agent's wake keyword so peers render
    /// it without any extra lookup. Replaces the old `.local`/`.realtime` source.
    @Field(key: "sender")
    public var sender: KeepTalkingContextMessage.Sender

    @Field(key: "timestamp")
    public var timestamp: Date

    /// Per-(session, author) monotonic cursor. Lets a peer request "author X's
    /// lines since N" for incremental gap-fetch, and (author, sequence) dedups.
    @Field(key: "sequence")
    public var sequence: Int

    public init() {}

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        contextID: UUID,
        author: UUID,
        text: String,
        sender: KeepTalkingContextMessage.Sender,
        timestamp: Date = Date(),
        sequence: Int
    ) {
        self.id = id
        self.sessionID = sessionID
        self.contextID = contextID
        self.author = author
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// Wire form of a transcript line, used by the `transcriptSyncing` use of
/// `ContextSyncController` (the incremental backfill that repairs lines a peer
/// missed live). Distinct from `KeepTalkingVoiceCallTranscriptLinePayload`, which
/// is the *live* broadcast of a single freshly-spoken line.
public struct KeepTalkingVoiceTranscriptLineDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let contextID: UUID
    public let author: UUID
    public let text: String
    public let sender: KeepTalkingContextMessage.Sender
    public let timestamp: Date
    public let sequence: Int

    public init(
        id: UUID,
        sessionID: UUID,
        contextID: UUID,
        author: UUID,
        text: String,
        sender: KeepTalkingContextMessage.Sender,
        timestamp: Date,
        sequence: Int
    ) {
        self.id = id
        self.sessionID = sessionID
        self.contextID = contextID
        self.author = author
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.sequence = sequence
    }

    public init?(_ model: KeepTalkingVoiceTranscriptLine) {
        guard let id = model.id else { return nil }
        self.init(
            id: id,
            sessionID: model.sessionID,
            contextID: model.contextID,
            author: model.author,
            text: model.text,
            sender: model.sender,
            timestamp: model.timestamp,
            sequence: model.sequence
        )
    }

    public func makeModel() -> KeepTalkingVoiceTranscriptLine {
        KeepTalkingVoiceTranscriptLine(
            id: id,
            sessionID: sessionID,
            contextID: contextID,
            author: author,
            text: text,
            sender: sender,
            timestamp: timestamp,
            sequence: sequence
        )
    }
}

/// A distinct voice-call session that has transcript lines in a context, with
/// enough metadata to surface it to the agent as a *virtual* attachment (its
/// `attachment_id` is the session id) that the existing context-attachment tools
/// list and read. Backed entirely by `kt_voice_transcript_lines` — surfacing one
/// creates no attachment row and no blob; the transcript stays in the database.
public struct KeepTalkingVoiceTranscriptSessionSummary: Sendable, Equatable {
    public let sessionID: UUID
    public let contextID: UUID
    public let lineCount: Int
    public let firstAt: Date
    public let lastAt: Date
    /// Distinct speakers in first-spoken order (node ids; map via alias lookup).
    public let authors: [UUID]
    /// Sum of the lines' text bytes — an approximate size for the listing.
    public let textByteCount: Int

    public init(
        sessionID: UUID,
        contextID: UUID,
        lineCount: Int,
        firstAt: Date,
        lastAt: Date,
        authors: [UUID],
        textByteCount: Int
    ) {
        self.sessionID = sessionID
        self.contextID = contextID
        self.lineCount = lineCount
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.authors = authors
        self.textByteCount = textByteCount
    }
}
