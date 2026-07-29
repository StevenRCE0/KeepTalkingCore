import Crypto
import Foundation

// Transcript-line sync support: build `KeepTalkingContextSyncMetadata` over voice
// transcript lines and slice them by tail/chunk cursor — the data side of the
// `transcriptSyncing` reconcile. Mirrors ContextMessageSync.swift, reusing the
// same metadata + cursor types so message sync and transcript sync share the
// summary → tail → chunk logic. A line's `author` is its sender (`.node`), and
// its `sequence`/`id` play the roles message position/id play for messages.

extension Array where Element == KeepTalkingVoiceTranscriptLine {
    /// Per-author-stable order: by the author-local monotonic `sequence`, then id.
    /// (Sequence, not timestamp — it's clock-skew-free and is the author's own
    /// numbering, so two nodes always agree on the order within a sender.)
    func sortedForTranscriptSync() -> [KeepTalkingVoiceTranscriptLine] {
        sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }
}

private func requireTranscriptLineID(_ line: KeepTalkingVoiceTranscriptLine?) -> UUID {
    guard let line, let id = line.id else {
        preconditionFailure("Transcript sync metadata requires line identifiers.")
    }
    return id
}

private struct KeepTalkingVoiceTranscriptDigestPayload: Codable {
    let id: UUID
    let author: UUID
    let text: String
    /// Milliseconds, in lockstep with `KeepTalkingContextSyncDigestPayload` —
    /// same round-trip hazard, same fix.
    let timestamp: Int64
    let sender: KeepTalkingContextMessage.Sender
    let sequence: Int
}

private func transcriptLineDigest(for line: KeepTalkingVoiceTranscriptLine) -> Data {
    let payload = KeepTalkingVoiceTranscriptDigestPayload(
        id: requireTranscriptLineID(line),
        author: line.author,
        text: line.text,
        timestamp: Int64((line.timestamp.timeIntervalSince1970 * 1_000).rounded()),
        sender: line.sender,
        sequence: line.sequence
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(payload)
    return Data(SHA256.hash(data: data))
}

private func transcriptChunkDigest(for lines: [KeepTalkingVoiceTranscriptLine]) -> Data {
    var hasher = SHA256()
    for line in lines.sortedForTranscriptSync() {
        hasher.update(data: transcriptLineDigest(for: line))
    }
    return Data(hasher.finalize())
}

extension KeepTalkingContextSyncMetadata {
    /// Build sync metadata over a session's transcript lines, grouping by author
    /// (as a `.node` sender). Structurally identical to the message metadata, so
    /// the shared tail/chunk cursor math applies unchanged.
    static func buildFromTranscriptLines(
        _ lines: [KeepTalkingVoiceTranscriptLine],
        chunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) -> KeepTalkingContextSyncMetadata {
        precondition(chunkSize > 0)

        let bySender = Dictionary(grouping: lines) {
            KeepTalkingContextMessage.Sender.node(node: $0.author)
        }
        let senders = bySender.map { sender, senderLines in
            KeepTalkingContextSyncMetadata.SenderSummary(
                sender: sender,
                messageCount: senderLines.count
            )
        }
        let chunks = bySender.flatMap { sender, senderLines -> [KeepTalkingContextSyncMetadata.ChunkSummary] in
            let ordered = senderLines.sortedForTranscriptSync()
            return stride(from: 0, to: ordered.count, by: chunkSize)
                .enumerated()
                .map { offset, start in
                    let end = min(start + chunkSize, ordered.count)
                    let chunkLines = Array(ordered[start..<end])
                    return KeepTalkingContextSyncMetadata.ChunkSummary(
                        sender: sender,
                        index: offset,
                        firstMessage: requireTranscriptLineID(chunkLines.first),
                        lastMessage: requireTranscriptLineID(chunkLines.last),
                        messageCount: chunkLines.count,
                        digest: transcriptChunkDigest(for: chunkLines)
                    )
                }
        }
        return KeepTalkingContextSyncMetadata(
            chunkSize: chunkSize,
            messageCount: lines.count,
            senders: senders,
            chunks: chunks
        )
    }
}

/// One session's transcript lines indexed for sync, mirroring
/// `KeepTalkingContextSyncSnapshot`.
public struct KeepTalkingVoiceTranscriptSyncSnapshot: Sendable, KeepTalkingContextSyncStream {
    public let session: UUID
    public let summary: KeepTalkingContextSyncMetadata

    private let linesBySender: [KeepTalkingContextMessage.Sender: [KeepTalkingVoiceTranscriptLine]]

    public init(
        session: UUID,
        lines: [KeepTalkingVoiceTranscriptLine],
        chunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) {
        self.session = session
        let summary = KeepTalkingContextSyncMetadata.buildFromTranscriptLines(
            lines,
            chunkSize: chunkSize
        )
        self.summary = summary
        self.linesBySender = Dictionary(grouping: lines) {
            KeepTalkingContextMessage.Sender.node(node: $0.author)
        }.mapValues { $0.sortedForTranscriptSync() }
    }

    /// Lines past each author's tail cursor (append-only delta).
    public func items(
        after cursors: [KeepTalkingContextSyncTailCursor],
        before: KeepTalkingContextSyncPageKey?
    ) -> (
        items: [KeepTalkingVoiceTranscriptLine],
        nextBefore: KeepTalkingContextSyncPageKey?
    ) {
        let items = cursors.flatMap { cursor -> [KeepTalkingVoiceTranscriptLine] in
            let senderItems = linesBySender[cursor.sender, default: []]
            let start = min(cursor.startIndex, senderItems.count)
            let end = min(cursor.endIndex, senderItems.count)
            guard start < end else { return [] }
            return Array(senderItems[start..<end])
        }.sortedForTranscriptPage()
        return KeepTalkingContextSyncPage.newestFirst(
            items,
            before: before,
            key: transcriptPageKey,
            limit: summary.chunkSize
        )
    }

    /// One bounded page beginning at the first diverging chunk.
    public func items(
        in chunks: [KeepTalkingContextSyncChunkCursor],
        before: KeepTalkingContextSyncPageKey?
    ) -> (
        items: [KeepTalkingVoiceTranscriptLine],
        nextBefore: KeepTalkingContextSyncPageKey?
    ) {
        let chunkSize = summary.chunkSize
        let items = chunks.sorted(by: {
            let lhs = senderSortKey($0.sender)
            let rhs = senderSortKey($1.sender)
            return lhs == rhs ? $0.index < $1.index : lhs < rhs
        }).flatMap { cursor -> [KeepTalkingVoiceTranscriptLine] in
            let senderItems = linesBySender[cursor.sender, default: []]
            let (rawStart, overflow) = cursor.index.multipliedReportingOverflow(
                by: chunkSize
            )
            guard !overflow else { return [] }
            let start = min(rawStart, senderItems.count)
            let end = min(cursor.endIndex, senderItems.count)
            guard start < end else { return [] }
            return Array(senderItems[start..<end])
        }.sortedForTranscriptPage()
        return KeepTalkingContextSyncPage.newestFirst(
            items,
            before: before,
            key: transcriptPageKey,
            limit: chunkSize
        )
    }
}

private func transcriptPageKey(
    _ line: KeepTalkingVoiceTranscriptLine
) -> KeepTalkingContextSyncPageKey {
    KeepTalkingContextSyncPageKey(
        timestamp: line.timestamp,
        id: requireTranscriptLineID(line)
    )
}

extension Array where Element == KeepTalkingVoiceTranscriptLine {
    fileprivate func sortedForTranscriptPage() -> [KeepTalkingVoiceTranscriptLine] {
        sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }
}
