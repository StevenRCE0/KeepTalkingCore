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
