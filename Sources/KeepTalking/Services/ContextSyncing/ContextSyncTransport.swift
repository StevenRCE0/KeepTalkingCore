import FluentKit
import Foundation

public struct KeepTalkingContextSyncTailCursor: Codable, Sendable, Equatable {
    public let sender: KeepTalkingContextMessage.Sender
    public let messageCount: Int

    public init(
        sender: KeepTalkingContextMessage.Sender,
        messageCount: Int
    ) {
        self.sender = sender
        self.messageCount = messageCount
    }
}

public struct KeepTalkingContextSyncChunkCursor: Codable, Sendable, Equatable {
    public let sender: KeepTalkingContextMessage.Sender
    public let index: Int

    public init(
        sender: KeepTalkingContextMessage.Sender,
        index: Int
    ) {
        self.sender = sender
        self.index = index
    }
}

public struct KeepTalkingContextSyncSummaryRequest: Codable, Sendable,
    Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
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

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        summary: KeepTalkingContextSyncMetadata
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.summary = summary
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

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        senders: [KeepTalkingContextSyncTailCursor]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
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
        remote: KeepTalkingContextSyncMetadata
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
            senders: senders
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

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        chunks: [KeepTalkingContextSyncChunkCursor]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
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
        remote: KeepTalkingContextSyncMetadata
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
            chunks: chunks
        )
    }
}

// MARK: - Shared reconcile math (message sync + transcript sync)

/// Tail cursors for an append-only pull: for each remote sender whose count
/// exceeds ours, request starting from our current count. Shared by both the
/// message sync and the transcript-line sync — same reconcile, different table.
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
            messageCount: localCount
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
            index: mismatch.index
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

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        messages: [KeepTalkingContextMessage],
        attachments: [KeepTalkingContextAttachmentDTO] = []
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.messages = messages
        self.attachments = attachments
    }
}

/// Pull request for the responder's side-note set. Side notes use full-sync
/// semantics — the responder always returns every side note it knows about
/// for the context, and the requester merges by `(key, updatedAt)`.
public struct KeepTalkingContextSyncSideNotesRequest: Codable, Sendable, Equatable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
    }
}

public struct KeepTalkingContextSyncSideNotesResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let sideNotes: [KeepTalkingSideNoteDTO]

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        sideNotes: [KeepTalkingSideNoteDTO]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.sideNotes = sideNotes
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
        summary: KeepTalkingContextSyncMetadata
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

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        senders: [KeepTalkingContextSyncTailCursor]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.session = session
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
        remote: KeepTalkingContextSyncMetadata
    ) {
        let senders = contextSyncTailCursors(local: local, remote: remote)
        guard !senders.isEmpty else { return nil }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            senders: senders
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

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        session: UUID,
        chunks: [KeepTalkingContextSyncChunkCursor]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.session = session
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
        remote: KeepTalkingContextSyncMetadata
    ) {
        let chunks = contextSyncChunkCursors(local: local, remote: remote)
        guard !chunks.isEmpty else { return nil }
        self.init(
            request: request,
            context: context,
            requester: requester,
            recipient: recipient,
            session: session,
            chunks: chunks
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

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        session: UUID,
        lines: [KeepTalkingVoiceTranscriptLineDTO]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.session = session
        self.lines = lines
    }
}

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

    // Side notes: full-set pull, merged by `(key, updatedAt)`.
    /// Pull the peer's entire side-note set for the context.
    case sideNotesRequest(KeepTalkingContextSyncSideNotesRequest)
    /// Side notes answering `sideNotesRequest`.
    case sideNotesResult(KeepTalkingContextSyncSideNotesResult)

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
}

// `KeepTalkingContextSyncSnapshot` + `contextSyncSnapshot(for:)` moved to
// MessageSyncStream.swift (next to its stream, mirroring VoiceTranscriptSync.swift).
// This file holds the on-the-wire request/result types + the shared cursor math.
