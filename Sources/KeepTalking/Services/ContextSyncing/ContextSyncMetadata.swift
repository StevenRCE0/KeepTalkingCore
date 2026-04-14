import CryptoKit
import FluentKit
import Foundation

public struct KeepTalkingContextSyncMetadata: Codable, Sendable, Equatable {
    public static let defaultChunkSize = 64

    public struct SenderSummary: Codable, Sendable, Equatable {
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

    public struct ChunkSummary: Codable, Sendable, Equatable {
        public let sender: KeepTalkingContextMessage.Sender
        public let index: Int
        public let firstMessage: UUID
        public let lastMessage: UUID
        public let messageCount: Int
        public let digest: Data

        public init(
            sender: KeepTalkingContextMessage.Sender,
            index: Int,
            firstMessage: UUID,
            lastMessage: UUID,
            messageCount: Int,
            digest: Data
        ) {
            self.sender = sender
            self.index = index
            self.firstMessage = firstMessage
            self.lastMessage = lastMessage
            self.messageCount = messageCount
            self.digest = digest
        }
    }

    public let chunkSize: Int
    public let messageCount: Int
    public let senders: [SenderSummary]
    public let chunks: [ChunkSummary]

    public init(
        chunkSize: Int = Self.defaultChunkSize,
        messageCount: Int,
        senders: [SenderSummary],
        chunks: [ChunkSummary]
    ) {
        precondition(chunkSize > 0)
        self.chunkSize = chunkSize
        self.messageCount = messageCount
        self.senders = senders.sorted {
            senderSortKey($0.sender) < senderSortKey($1.sender)
        }
        self.chunks = chunks.sorted {
            let lhsKey = senderSortKey($0.sender)
            let rhsKey = senderSortKey($1.sender)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.index < $1.index
        }
    }
}

extension KeepTalkingContext {
    public static func buildSyncMetadata(
        from messages: [KeepTalkingContextMessage],
        chunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) -> KeepTalkingContextSyncMetadata {
        precondition(chunkSize > 0)

        let messagesBySender = Dictionary(grouping: messages, by: \.sender)
        let senders = messagesBySender.map { sender, senderMessages in
            KeepTalkingContextSyncMetadata.SenderSummary(
                sender: sender,
                messageCount: senderMessages.count
            )
        }

        let chunks = messagesBySender.flatMap { sender, senderMessages in
            let orderedMessages = senderMessages.sortedForSync()
            return stride(from: 0, to: orderedMessages.count, by: chunkSize)
                .enumerated()
                .map { offset, start in
                    let end = min(start + chunkSize, orderedMessages.count)
                    let chunkMessages = Array(orderedMessages[start..<end])
                    return KeepTalkingContextSyncMetadata.ChunkSummary(
                        sender: sender,
                        index: offset,
                        firstMessage: requireMessageID(chunkMessages.first),
                        lastMessage: requireMessageID(chunkMessages.last),
                        messageCount: chunkMessages.count,
                        digest: chunkDigest(for: chunkMessages)
                    )
                }
        }

        return KeepTalkingContextSyncMetadata(
            chunkSize: chunkSize,
            messageCount: messages.count,
            senders: senders,
            chunks: chunks
        )
    }

    public func refreshSyncMetadata(
        on database: any Database,
        chunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) async throws {
        let context = try requireID()
        let messages = try await KeepTalkingContextMessage.query(on: database)
            .filter(\.$context.$id, .equal, context)
            .all()
        let metadata = Self.buildSyncMetadata(
            from: messages,
            chunkSize: chunkSize
        )
        guard syncMetadata != metadata else {
            return
        }
        syncMetadata = metadata
        try await save(on: database)
    }
}

private struct KeepTalkingContextSyncDigestPayload: Codable {
    let id: UUID
    let sender: KeepTalkingContextMessage.Sender
    let content: String
    let timestamp: Int64
    let type: KeepTalkingContextMessage.MessageType
}

func senderSortKey(_ sender: KeepTalkingContextMessage.Sender) -> String {
    switch sender {
        case .node(let node):
            return "node:\(node.uuidString.lowercased())"
        case .autonomous(let name, _, _):
            return "autonomous:\(name)"
    }
}

func messageSortKey(_ message: KeepTalkingContextMessage) -> String {
    (message.id?.uuidString ?? "").lowercased()
}

func requireMessageID(_ message: KeepTalkingContextMessage?) -> UUID {
    guard let message, let id = message.id else {
        preconditionFailure("Context sync metadata requires message identifiers.")
    }
    return id
}

func messageDigest(for message: KeepTalkingContextMessage) -> Data {
    let payload = KeepTalkingContextSyncDigestPayload(
        id: requireMessageID(message),
        sender: message.sender,
        content: message.content,
        timestamp: Int64(
            (message.timestamp.timeIntervalSince1970 * 1_000).rounded()
        ),
        type: message.type
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(payload)
    return Data(SHA256.hash(data: data))
}

func chunkDigest(for messages: [KeepTalkingContextMessage]) -> Data {
    var hasher = SHA256()
    for message in messages.sortedForSync() {
        hasher.update(data: messageDigest(for: message))
    }
    return Data(hasher.finalize())
}

extension Array where Element == KeepTalkingContextMessage {
    func sortedForSync() -> [KeepTalkingContextMessage] {
        sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return messageSortKey(lhs) < messageSortKey(rhs)
        }
    }
}
