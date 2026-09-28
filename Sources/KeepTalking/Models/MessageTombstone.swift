import Crypto
import Foundation

/// A deleted message, as every node in the context remembers it.
///
/// Deletion is a fact the context carries, not a local edit: sync is a union,
/// so a row removed on one node is simply re-fetched from any peer that still
/// holds it. The tombstone is what makes the removal stick — it keeps the id
/// out of every intake path, on every node, for good.
///
/// `timestamp` is the deleted message's own timestamp. A peer that never held
/// the message still has to place a turning point that named it, and the only
/// way to do that without the row is to know where the row stood.
public struct KeepTalkingMessageTombstone: Codable, Sendable, Hashable {
    public let messageID: UUID
    public let timestamp: Date

    public init(messageID: UUID, timestamp: Date) {
        self.messageID = messageID
        self.timestamp = timestamp
    }

    /// Where the deleted message stood in the context's canonical order.
    public var pageKey: KeepTalkingContextSyncPageKey {
        KeepTalkingContextSyncPageKey(timestamp: timestamp, id: messageID)
    }
}

/// Detection half of message-deletion sync.
///
/// Over ids only. The timestamp is a property of the message the id names, so
/// two nodes holding the same id hold the same tombstone.
public enum KeepTalkingMessageDeletionDigest {
    public static func digest(of tombstones: [KeepTalkingMessageTombstone]) -> Data {
        var hasher = SHA256()
        for id in Set(tombstones.map { $0.messageID.uuidString.lowercased() }).sorted() {
            hasher.update(data: Data(id.utf8))
        }
        return Data(hasher.finalize())
    }
}

/// How far a deletion reaches.
public enum KeepTalkingMessageDeletionScope: Sendable, Equatable {
    /// Exactly the messages named.
    case messages
    /// Every message sharing an `agentTurnID` with one named: the whole turn.
    case agentTurns
}

/// Messages this node just removed because a tombstone reached it — locally
/// or by merge.
public struct KeepTalkingMessageDeletion: Sendable, Equatable {
    public let contextID: UUID
    /// Every id the merge newly tombstoned, held locally or not.
    public let messageIDs: [UUID]
    /// Blob ids whose last referencing attachment went with those messages.
    public let prunedBlobIDs: [String]
}
