import FluentKit
import Foundation

public struct KeepTalkingContextSyncTailCursor: Codable, Sendable, Equatable {
    public let sender: KeepTalkingContextMessage.Sender
    /// Inclusive index in the responder's per-sender canonical stream.
    public let startIndex: Int
    /// Exclusive index captured from the responder's summary.
    ///
    /// Nothing proves the responder's stream has not shifted underneath this
    /// index — the snapshot-strictness check that would have was deliberately
    /// dropped. A stale index therefore serves the wrong slice rather than
    /// failing; the digest comparison on the next summary is what catches it.
    public let endIndex: Int

    public init(
        sender: KeepTalkingContextMessage.Sender,
        startIndex: Int,
        endIndex: Int
    ) {
        self.sender = sender
        self.startIndex = max(0, startIndex)
        self.endIndex = max(self.startIndex, endIndex)
    }
}

public struct KeepTalkingContextSyncChunkCursor: Codable, Sendable, Equatable {
    public let sender: KeepTalkingContextMessage.Sender
    public let index: Int
    /// Exclusive responder index captured with the summary used to plan repair.
    public let endIndex: Int

    public init(
        sender: KeepTalkingContextMessage.Sender,
        index: Int,
        endIndex: Int
    ) {
        self.sender = sender
        self.index = max(0, index)
        self.endIndex = max(0, endIndex)
    }
}

public struct KeepTalkingContextSyncPageKey: Codable, Sendable, Equatable,
    Comparable
{
    public let timestamp: Date
    public let id: UUID

    public init(timestamp: Date, id: UUID) {
        self.timestamp = timestamp
        self.id = id
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString.lowercased()
            < rhs.id.uuidString.lowercased()
    }
}

public struct KeepTalkingContextSyncSummaryRequest: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    /// Our side-note digest. The responder compares it against its own and
    /// attaches its whole set only when they differ — so the steady state costs
    /// 32 bytes up and nothing back, instead of re-pulling every note.
    public let sideNoteDigest: Data?

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        sideNoteDigest: Data? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.sideNoteDigest = sideNoteDigest
    }
}

public struct KeepTalkingContextSyncSummaryResult: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let summary: KeepTalkingContextSyncMetadata
    /// Present only when the requester's side-note digest disagreed with ours.
    public let sideNotes: [KeepTalkingSideNoteDTO]?
    /// The responder's AI-marked threading, derived from its turning points.
    ///
    /// Threads are local rows and never sync as such; this projection of the
    /// AI's marking rides the summary exchange so a peer can reproduce the same
    /// threading. Applied only once the requester's message sync completes,
    /// since the ranges name messages it may not hold yet.
    public let threadDTOs: [KeepTalkingThreadDTO]?

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        summary: KeepTalkingContextSyncMetadata,
        sideNotes: [KeepTalkingSideNoteDTO]? = nil,
        threadDTOs: [KeepTalkingThreadDTO]? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.summary = summary
        self.sideNotes = sideNotes
        self.threadDTOs = threadDTOs
    }
}

/// A fire-and-forget push of side notes that just changed locally.
///
/// Broadcast, not directed: every peer in the context wants it, and the digest
/// compare on the next summary exchange is the catch-up for anyone who missed
/// it. `origin` lets a node ignore the echo of its own push.
public struct KeepTalkingContextSyncSideNotesPush: Codable, Sendable, Equatable {
    public let context: UUID
    public let origin: UUID
    public let sideNotes: [KeepTalkingSideNoteDTO]

    public init(
        context: UUID,
        origin: UUID,
        sideNotes: [KeepTalkingSideNoteDTO]
    ) {
        self.context = context
        self.origin = origin
        self.sideNotes = sideNotes
    }
}

public struct KeepTalkingContextSyncTailRequest: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let senders: [KeepTalkingContextSyncTailCursor]
    public let before: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        senders: [KeepTalkingContextSyncTailCursor],
        before: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.before = before
        self.senders = senders.sorted {
            senderSortKey($0.sender) < senderSortKey($1.sender)
        }
    }

    public init?(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        local: KeepTalkingContextSyncMetadata,
        remote: KeepTalkingContextSyncMetadata,
    ) {
        let senders = contextSyncTailCursors(local: local, remote: remote)
        guard !senders.isEmpty else {
            return nil
        }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            senders: senders,
        )
    }

    func continuing(before: KeepTalkingContextSyncPageKey) -> Self {
        Self(
            context: context,
            requester: requester,
            recipient: recipient,
            senders: senders,
            before: before
        )
    }
}

public struct KeepTalkingContextSyncChunkRequest: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let chunks: [KeepTalkingContextSyncChunkCursor]
    public let before: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        chunks: [KeepTalkingContextSyncChunkCursor],
        before: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.before = before
        self.chunks = chunks.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.index < $1.index
        }
    }

    public init?(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        local: KeepTalkingContextSyncMetadata,
        remote: KeepTalkingContextSyncMetadata,
    ) {
        let chunks = contextSyncChunkCursors(local: local, remote: remote)
        guard !chunks.isEmpty else {
            return nil
        }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            chunks: chunks,
        )
    }

    func continuing(before: KeepTalkingContextSyncPageKey) -> Self {
        Self(
            context: context,
            requester: requester,
            recipient: recipient,
            chunks: chunks,
            before: before
        )
    }
}

// MARK: - Shared reconcile math (message sync + transcript sync)

/// Snapshot-bound append-only ranges: for each remote sender whose count exceeds
/// ours, capture `[localCount, remoteCount)`. The responder rejects the request
/// if those indices no longer address the summary snapshot.
func contextSyncTailCursors(
    local: KeepTalkingContextSyncMetadata,
    remote: KeepTalkingContextSyncMetadata
) -> [KeepTalkingContextSyncTailCursor] {
    let localBySender = Dictionary(
        uniqueKeysWithValues: local.senders.map { ($0.sender, $0) }
    )
    return remote.senders.compactMap { remoteSender in
        let localCount = localBySender[remoteSender.sender]?.messageCount ?? 0
        guard remoteSender.messageCount > localCount else { return nil }
        return KeepTalkingContextSyncTailCursor(
            sender: remoteSender.sender,
            startIndex: localCount,
            endIndex: remoteSender.messageCount
        )
    }
}

/// Chunk cursors for mid-stream divergence repair: for each sender, find the
/// first chunk whose digest/bounds disagree with ours and request it. Catches
/// gaps that aren't at the tail — the reason sync can't assume linear arrival.
/// Shared by message sync and transcript-line sync.
func contextSyncChunkCursors(
    local: KeepTalkingContextSyncMetadata,
    remote: KeepTalkingContextSyncMetadata
) -> [KeepTalkingContextSyncChunkCursor] {
    let localSenders = Dictionary(
        uniqueKeysWithValues: local.senders.map { ($0.sender, $0) }
    )
    let localChunks = Dictionary(grouping: local.chunks, by: \.sender)
    let remoteChunks = Dictionary(grouping: remote.chunks, by: \.sender)

    return remote.senders.compactMap { remoteSender in
        let localCount = localSenders[remoteSender.sender]?.messageCount ?? 0
        guard remoteSender.messageCount >= localCount else { return nil }
        let localChunksForSender = Dictionary(
            uniqueKeysWithValues: (localChunks[remoteSender.sender] ?? []).map {
                ($0.index, $0)
            }
        )
        let remoteChunksForSender = (remoteChunks[remoteSender.sender] ?? [])
            .sorted { $0.index < $1.index }

        guard
            let mismatch = remoteChunksForSender.first(where: { remoteChunk in
                guard let localChunk = localChunksForSender[remoteChunk.index] else {
                    return true
                }
                return
                    localChunk.firstMessage != remoteChunk.firstMessage
                    || localChunk.lastMessage != remoteChunk.lastMessage
                    || localChunk.messageCount != remoteChunk.messageCount
                    || localChunk.digest != remoteChunk.digest
            })
        else {
            return nil
        }

        return KeepTalkingContextSyncChunkCursor(
            sender: remoteSender.sender,
            index: mismatch.index,
            endIndex: remoteSender.messageCount
        )
    }
}

public struct KeepTalkingContextSyncMessagesResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let messages: [KeepTalkingContextMessage]
    public let attachments: [KeepTalkingContextAttachmentDTO]
    public let nextBefore: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        messages: [KeepTalkingContextMessage],
        attachments: [KeepTalkingContextAttachmentDTO] = [],
        nextBefore: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.messages = messages
        self.attachments = attachments
        self.nextBefore = nextBefore
    }

}

public struct KeepTalkingContextSyncAttachmentRequest: Codable, Sendable,
    Equatable
{
    public let context: UUID
    public let requester: UUID
    public let hashes: [String]
    public let masks: [String: Data]?

    public init(
        context: UUID,
        requester: UUID,
        hashes: [String],
        masks: [String: Data]? = nil
    ) {
        self.context = context
        self.requester = requester
        self.hashes = Self.normalized(hashes)
        self.masks = masks
    }

    private static func normalized(_ hashes: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for hash in hashes {
            let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            guard seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }

        return normalized
    }
}

/// Pull request for attachment *records* (not blob bytes) belonging to a set
/// of message IDs the requester already has. Repairs the case where a message
/// synced but its attachment record never landed (e.g. the live attachment
/// envelope raced ahead of its message and was dropped) — incremental message
/// sync can't recover this, because attachments only ride along with messages
/// in the active delta, and the parent message is already behind the cursor.
///
/// Distinct from `KeepTalkingContextSyncAttachmentRequest`, which fetches blob
/// *bytes* (by hash) for records the requester already holds.
public struct KeepTalkingContextSyncAttachmentRecordsRequest: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let messageIDs: [UUID]

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        messageIDs: [UUID]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.messageIDs = messageIDs
    }
}

public struct KeepTalkingContextSyncAttachmentRecordsResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let attachments: [KeepTalkingContextAttachmentDTO]

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        attachments: [KeepTalkingContextAttachmentDTO]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.attachments = attachments
    }
}

// MARK: - Transcript-line sync (the `transcriptSyncing` use)
//
// Mirrors the message sync's summary → tail → chunk reconcile, but over the flat
// `kt_voice_transcript_lines` table and scoped to a single voice session. Reuses
// `KeepTalkingContextSyncMetadata` + the tail/chunk cursors: a transcript line's
// author maps to a `.node` sender, its `sequence`/id play the message role. The
// three-phase reconcile (not a naive per-author cursor) is what makes it correct
// when lines arrive out of order or with mid-stream gaps. Dispatched only while a
// voice session is ongoing — no passive heartbeat.

/// Phase 1 — ask a peer for its transcript metadata (per-author counts + chunk
/// digests) for one session.
public struct KeepTalkingContextSyncTranscriptSummaryRequest: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let session: UUID

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.session = session
    }
}

public struct KeepTalkingContextSyncTranscriptSummaryResult: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let session: UUID
    public let summary: KeepTalkingContextSyncMetadata

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        session: UUID,
        summary: KeepTalkingContextSyncMetadata,
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.session = session
        self.summary = summary
    }
}

/// Phase 2 — append-only pull: request each author's lines past the tail cursor.
public struct KeepTalkingContextSyncTranscriptTailRequest: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let session: UUID
    public let senders: [KeepTalkingContextSyncTailCursor]
    public let before: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        senders: [KeepTalkingContextSyncTailCursor],
        before: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.session = session
        self.before = before
        self.senders = senders.sorted {
            senderSortKey($0.sender) < senderSortKey($1.sender)
        }
    }

    /// Nil when local already covers every remote sender's tail (nothing to pull).
    public init?(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        local: KeepTalkingContextSyncMetadata,
        remote: KeepTalkingContextSyncMetadata,
    ) {
        let senders = contextSyncTailCursors(local: local, remote: remote)
        guard !senders.isEmpty else { return nil }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            senders: senders,
        )
    }

    func continuing(before: KeepTalkingContextSyncPageKey) -> Self {
        Self(
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            senders: senders,
            before: before
        )
    }
}

/// Phase 3 — mid-stream repair: request the first chunk whose digest disagrees.
public struct KeepTalkingContextSyncTranscriptChunkRequest: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let session: UUID
    public let chunks: [KeepTalkingContextSyncChunkCursor]
    public let before: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        chunks: [KeepTalkingContextSyncChunkCursor],
        before: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.session = session
        self.before = before
        self.chunks = chunks.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return $0.index < $1.index
        }
    }

    /// Nil when no chunk diverges (the tail pull alone sufficed).
    public init?(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        local: KeepTalkingContextSyncMetadata,
        remote: KeepTalkingContextSyncMetadata,
    ) {
        let chunks = contextSyncChunkCursors(local: local, remote: remote)
        guard !chunks.isEmpty else { return nil }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            chunks: chunks,
        )
    }

    func continuing(before: KeepTalkingContextSyncPageKey) -> Self {
        Self(
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            chunks: chunks,
            before: before
        )
    }
}

/// Response to a transcript tail OR chunk request — the requested lines as DTOs
/// (mirrors how `messagesResult` serves both message tail and chunk requests).
public struct KeepTalkingContextSyncTranscriptLinesResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let session: UUID
    public let lines: [KeepTalkingVoiceTranscriptLineDTO]
    public let nextBefore: KeepTalkingContextSyncPageKey?

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        session: UUID,
        lines: [KeepTalkingVoiceTranscriptLineDTO],
        nextBefore: KeepTalkingContextSyncPageKey? = nil
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.session = session
        self.lines = lines
        self.nextBefore = nextBefore
    }

}

/// A directed terminal response when a peer cannot execute a context-sync
/// request. The requester uses `request` to fail whichever resource registry
/// owns that round-trip, so every request phase terminates immediately.
public struct KeepTalkingContextSyncFailureResult: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let message: String

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        message: String
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.message = message
    }

}

protocol KeepTalkingContextSyncDirectedRequest {
    var request: UUID { get }
    var context: UUID { get }
    var requester: UUID { get }
    var recipient: UUID { get }
}

extension KeepTalkingContextSyncSummaryRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncTailRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncChunkRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncAttachmentRecordsRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncTranscriptSummaryRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncTranscriptTailRequest:
    KeepTalkingContextSyncDirectedRequest
{}
extension KeepTalkingContextSyncTranscriptChunkRequest:
    KeepTalkingContextSyncDirectedRequest
{}

public enum KeepTalkingContextSyncEnvelope: Codable, Sendable {
    // Message sync (contextSyncing): summary → tail → chunk, both phases answered
    // by `messagesResult`.
    /// Ask a peer for its message metadata (per-sender counts + chunk digests).
    case summaryRequest(KeepTalkingContextSyncSummaryRequest)
    /// A peer's message metadata, answering `summaryRequest`.
    case summaryResult(KeepTalkingContextSyncSummaryResult)
    /// Pull each sender's messages past the tail cursor (append-only delta).
    case tailRequest(KeepTalkingContextSyncTailRequest)
    /// Pull a specific diverging message chunk (mid-stream gap repair).
    case chunkRequest(KeepTalkingContextSyncChunkRequest)
    /// Messages answering a `tailRequest` or `chunkRequest`.
    case messagesResult(KeepTalkingContextSyncMessagesResult)

    // Attachments: blob bytes by hash, plus record-repair by message id.
    /// Pull attachment blob *bytes* (by content hash) for records we already hold.
    case attachmentRequest(KeepTalkingContextSyncAttachmentRequest)
    /// Pull attachment *records* for message ids whose attachment row never landed.
    case attachmentRecordsRequest(KeepTalkingContextSyncAttachmentRecordsRequest)
    /// Attachment records answering `attachmentRecordsRequest`.
    case attachmentRecordsResult(KeepTalkingContextSyncAttachmentRecordsResult)

    // Transcript-line sync (transcriptSyncing): per-session mirror of the message
    // summary → tail → chunk reconcile, both phases answered by
    // `transcriptLinesResult`. Only exchanged while a voice session is ongoing.
    /// Ask a peer for its transcript metadata for one session.
    case transcriptSummaryRequest(KeepTalkingContextSyncTranscriptSummaryRequest)
    /// A peer's transcript metadata, answering `transcriptSummaryRequest`.
    case transcriptSummaryResult(KeepTalkingContextSyncTranscriptSummaryResult)
    /// Pull each author's transcript lines past the tail cursor.
    case transcriptTailRequest(KeepTalkingContextSyncTranscriptTailRequest)
    /// Pull a specific diverging transcript chunk (out-of-order / gap repair).
    case transcriptChunkRequest(KeepTalkingContextSyncTranscriptChunkRequest)
    /// Transcript lines answering a `transcriptTailRequest` or `transcriptChunkRequest`.
    case transcriptLinesResult(KeepTalkingContextSyncTranscriptLinesResult)

    /// Side notes that just changed on the sender. Broadcast; the digest on the
    /// summary exchange is the catch-up path.
    case sideNotesPush(KeepTalkingContextSyncSideNotesPush)

    /// Terminal failure answering any directed context-sync request.
    case failureResult(KeepTalkingContextSyncFailureResult)
}

// `KeepTalkingContextSyncSnapshot` + `contextSyncSnapshot(for:)` moved to
// MessageSyncStream.swift (next to its stream, mirroring VoiceTranscriptSync.swift).
// This file holds the on-the-wire request/result types + the shared cursor math.
