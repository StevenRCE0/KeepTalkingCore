import FluentKit
import Foundation

/// One context's messages indexed for sync — the message-stream counterpart to
/// `KeepTalkingVoiceTranscriptSyncSnapshot`. Builds per-sender metadata and serves
/// the tail/chunk slices the reconcile asks for, plus the attachments that ride
/// along with returned messages.
public struct KeepTalkingContextSyncSnapshot: Sendable, KeepTalkingContextSyncStream {
    public let context: UUID
    public let summary: KeepTalkingContextSyncMetadata

    private let messagesBySender: [KeepTalkingContextMessage.Sender: [KeepTalkingContextMessage]]
    private let attachmentsByMessageID: [UUID: [KeepTalkingContextAttachmentDTO]]

    public init(
        context: UUID,
        messages: [KeepTalkingContextMessage],
        attachments: [KeepTalkingContextAttachment],
        chunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) {
        self.context = context
        self.summary = KeepTalkingContext.buildSyncMetadata(
            from: messages,
            chunkSize: chunkSize
        )
        self.messagesBySender = Dictionary(
            grouping: messages,
            by: \.sender
        ).mapValues { $0.sortedForSync() }
        let messageAttachments = attachments.compactMap {
            attachment
                -> (UUID, KeepTalkingContextAttachmentDTO)? in
            guard
                let dto = KeepTalkingContextAttachmentDTO(attachment),
                let parentMessageID = dto.parentMessageID
            else { return nil }
            return (parentMessageID, dto)
        }
        self.attachmentsByMessageID = Dictionary(
            grouping: messageAttachments,
            by: \.0
        ).mapValues {
            $0.sorted { lhs, rhs in
                if lhs.1.sortIndex != rhs.1.sortIndex {
                    return lhs.1.sortIndex < rhs.1.sortIndex
                }
                return lhs.1.id.uuidString < rhs.1.id.uuidString
            }.map(\.1)
        }
    }

    public func items(
        after cursors: [KeepTalkingContextSyncTailCursor]
    ) -> [KeepTalkingContextMessage] {
        cursors.flatMap { cursor in
            Array(
                messagesBySender[cursor.sender, default: []]
                    .dropFirst(max(0, cursor.messageCount))
            )
        }.sortedForSync()
    }

    public func items(
        in chunks: [KeepTalkingContextSyncChunkCursor]
    ) -> [KeepTalkingContextMessage] {
        let chunkSize = summary.chunkSize
        return chunks.flatMap { cursor in
            Array(
                messagesBySender[cursor.sender, default: []]
                    .dropFirst(cursor.index * chunkSize)
            )
        }.sortedForSync()
    }

    public func attachments(
        for messages: [KeepTalkingContextMessage]
    ) -> [KeepTalkingContextAttachmentDTO] {
        var attachments: [KeepTalkingContextAttachmentDTO] = []
        for message in messages {
            guard let messageID = message.id else {
                continue
            }
            attachments.append(
                contentsOf: attachmentsByMessageID[messageID, default: []]
            )
        }
        return attachments
    }
}

extension KeepTalkingClient {
    func contextSyncSnapshot(
        for context: UUID
    ) async throws -> KeepTalkingContextSyncSnapshot {
        let resolvedContext = try await ensure(context, for: KeepTalkingContext.self)
        let chunkSize =
            resolvedContext.syncMetadata?.chunkSize
            ?? KeepTalkingContextSyncMetadata.defaultChunkSize
        try await resolvedContext.refreshSyncMetadata(
            on: localStore.database,
            chunkSize: chunkSize
        )
        let messages = try await KeepTalkingContextMessage.query(on: localStore.database)
            .filter(\.$context.$id, .equal, context)
            .all()
        let attachments = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, context)
        .all()

        return KeepTalkingContextSyncSnapshot(
            context: context,
            messages: messages,
            attachments: attachments,
            chunkSize: chunkSize
        )
    }
}
