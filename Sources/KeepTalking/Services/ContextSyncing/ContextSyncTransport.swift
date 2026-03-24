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
        let localBySender = Dictionary(
            uniqueKeysWithValues: local.senders.map { ($0.sender, $0) }
        )
        let senders: [KeepTalkingContextSyncTailCursor] = remote.senders.compactMap {
            remoteSender in
            let localCount = localBySender[remoteSender.sender]?.messageCount ?? 0
            guard remoteSender.messageCount > localCount else {
                return nil
            }
            return KeepTalkingContextSyncTailCursor(
                sender: remoteSender.sender,
                messageCount: localCount
            )
        }
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
        let localSenders = Dictionary(
            uniqueKeysWithValues: local.senders.map { ($0.sender, $0) }
        )
        let localChunks = Dictionary(
            grouping: local.chunks,
            by: \.sender
        )
        let remoteChunks = Dictionary(
            grouping: remote.chunks,
            by: \.sender
        )

        let chunks: [KeepTalkingContextSyncChunkCursor] = remote.senders.compactMap {
            remoteSender in
            let localCount = localSenders[remoteSender.sender]?.messageCount ?? 0
            guard remoteSender.messageCount >= localCount else {
                return nil
            }
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

public struct KeepTalkingContextSyncMessagesResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let messages: [KeepTalkingContextMessage]

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        messages: [KeepTalkingContextMessage]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.messages = messages
    }
}

public struct KeepTalkingContextSyncRecentAttachmentsRequest: Codable,
    Sendable, Equatable
{
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let recipient: UUID
    public let since: Date

    public init(
        request: UUID = UUID(),
        context: UUID,
        requester: UUID,
        recipient: UUID,
        since: Date
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.recipient = recipient
        self.since = since
    }
}

public struct KeepTalkingContextSyncAttachmentsResult: Codable, Sendable {
    public let request: UUID
    public let context: UUID
    public let requester: UUID
    public let responder: UUID
    public let attachments: [KeepTalkingContextAttachment]

    public init(
        request: UUID,
        context: UUID,
        requester: UUID,
        responder: UUID,
        attachments: [KeepTalkingContextAttachment]
    ) {
        self.request = request
        self.context = context
        self.requester = requester
        self.responder = responder
        self.attachments = attachments
    }
}

public enum KeepTalkingContextSyncEnvelope: Codable, Sendable {
    case summaryRequest(KeepTalkingContextSyncSummaryRequest)
    case summaryResult(KeepTalkingContextSyncSummaryResult)
    case tailRequest(KeepTalkingContextSyncTailRequest)
    case chunkRequest(KeepTalkingContextSyncChunkRequest)
    case messagesResult(KeepTalkingContextSyncMessagesResult)
    case recentAttachmentsRequest(KeepTalkingContextSyncRecentAttachmentsRequest)
    case attachmentsResult(KeepTalkingContextSyncAttachmentsResult)
}

public struct KeepTalkingContextSyncSnapshot: Sendable {
    public let context: UUID
    public let summary: KeepTalkingContextSyncMetadata

    private let messagesBySender: [KeepTalkingContextMessage.Sender: [KeepTalkingContextMessage]]

    public init(
        context: UUID,
        messages: [KeepTalkingContextMessage],
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
    }

    public func messages(
        after cursors: [KeepTalkingContextSyncTailCursor]
    ) -> [KeepTalkingContextMessage] {
        cursors.flatMap { cursor in
            Array(
                messagesBySender[cursor.sender, default: []]
                    .dropFirst(max(0, cursor.messageCount))
            )
        }.sortedForSync()
    }

    public func messages(
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
        return KeepTalkingContextSyncSnapshot(
            context: context,
            messages: messages,
            chunkSize: chunkSize
        )
    }
}
