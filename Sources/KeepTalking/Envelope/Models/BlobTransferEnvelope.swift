import Foundation

/// Blob negotiation. Bytes never ride an envelope: they travel on a blob
/// stream of their own, point to point, opened by the holder only when the
/// node that needs them pulls.
///
/// Attachments:
/// 1. `wanted` — a node missing attachment blobs broadcasts their ids.
/// 2. `offer` — each member holding some of them tells the asker.
/// 3. `pull` — the asker picks one holder per blob and asks it to stream
///    from an offset (whatever it already has).
/// 4. The holder opens a blob stream to the puller, or answers
///    `unavailable` if it can't after all.
///
/// One-time blobs skip 1–2: the request or result carrying the reference
/// came from the holder, so the recipient pulls from it as soon as the
/// reference arrives, before anything asks for the file.
public struct KeepTalkingBlobTransferEnvelope: Codable, Sendable, Equatable {
    public enum Item: Codable, Hashable, Sendable {
        /// A context attachment's blob, by content hash.
        case attachment(blobID: String)
        /// A one-time blob, by transfer id. Only its recipient may pull it.
        case oneTimeBlob(transferID: UUID)
    }

    public struct Offered: Codable, Hashable, Sendable {
        public let item: Item
        public let byteCount: Int

        public init(item: Item, byteCount: Int) {
            self.item = item
            self.byteCount = byteCount
        }
    }

    /// Where the negotiation is. (Not `message`: every envelope already has
    /// a `message` accessor for chat messages.)
    public enum Step: Codable, Sendable, Equatable {
        case wanted([Item])
        case offer([Offered])
        case pull(Item, offset: Int)
        case unavailable(Item)
    }

    public let context: UUID
    public let sender: UUID
    /// Nil for `wanted`, which goes to the whole room.
    public let recipient: UUID?
    public let step: Step

    public init(context: UUID, sender: UUID, recipient: UUID?, step: Step) {
        self.context = context
        self.sender = sender
        self.recipient = recipient
        self.step = step
    }
}

extension KeepTalkingBlobTransferEnvelope: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .blobTransfer }
    public var targetPeerNodeID: UUID? { recipient }
    public var transportContextID: UUID? { context }
}

/// The first frame of a blob stream: what follows, from where.
struct KeepTalkingBlobStreamHeader: Codable, Sendable, Equatable {
    let item: KeepTalkingBlobTransferEnvelope.Item
    /// Attachments: the byte offset the stream starts at. One-time blobs:
    /// the index of the first sealed chunk.
    let offset: Int
    /// The whole blob's size in bytes.
    let byteCount: Int
    let mimeType: String?
    let pathExtension: String?
}

extension KeepTalkingEnvelopeAsyncHandlers {
    /// Blob negotiation never surfaces as an applied envelope.
    mutating func registerBlobTransferHandlers(for client: KeepTalkingClient) {
        registerReportingApplied(KeepTalkingBlobTransferEnvelope.self) { [weak client] envelope -> Bool in
            await client?.handleBlobTransferEnvelope(envelope)
            return false
        }
    }
}
