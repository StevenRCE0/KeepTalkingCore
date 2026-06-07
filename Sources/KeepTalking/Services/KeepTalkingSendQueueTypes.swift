import Foundation

public enum KeepTalkingSendQueueItemKind: String, Codable, Sendable {
    case draft
    case message
    case agentPrompt
}

public enum KeepTalkingSendQueueItemState: String, Codable, Sendable {
    case draft
    case queued
    case running
    case suspended
    /// The item's agent turn suspended on an out-of-band continuation and is now
    /// running detached in the background. Excluded from the drain's runnable
    /// set (its in-flight task finalizes it); a non-blocking driver was already
    /// acknowledged. On relaunch a stranded `.detached` row is reset to retry.
    case detached
    case failed
}

public struct KeepTalkingSendQueueSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let contextID: UUID
    public let kind: KeepTalkingSendQueueItemKind
    public let state: KeepTalkingSendQueueItemState
    public let textPreview: String
    public let createdAt: Date
    public let errorMessage: String?

    public init(
        id: UUID,
        contextID: UUID,
        kind: KeepTalkingSendQueueItemKind,
        state: KeepTalkingSendQueueItemState,
        textPreview: String,
        createdAt: Date,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.contextID = contextID
        self.kind = kind
        self.state = state
        self.textPreview = textPreview
        self.createdAt = createdAt
        self.errorMessage = errorMessage
    }
}
