import Foundation

/// Progress of ``KeepTalkingClient/registerLocalActionsInExecutors()``.
public enum KeepTalkingExecutorRegistration: Sendable, Equatable {
    case idle
    /// Registering the `completed`-th of `total` granted local actions;
    /// `source` is the executor kind (`mcp`, `skill`, `primitive`, …).
    case registering(source: String, name: String, completed: Int, total: Int)
    /// Every executor registered; the tool catalog is being rebuilt.
    case finalizing
}

/// Payload of ``KeepTalkingClientSignals/blobAvailabilityChanges``.
public struct KeepTalkingBlobAvailabilityChange: Sendable, Equatable {
    public let contextID: UUID
    public let blobID: String

    public init(contextID: UUID, blobID: String) {
        self.contextID = contextID
        self.blobID = blobID
    }
}

/// Payload of ``KeepTalkingClientSignals/trustEstablishments``.
public struct KeepTalkingTrustEstablishment: Sendable, Equatable {
    public let peerNodeID: UUID
    public let contextID: UUID

    public init(peerNodeID: UUID, contextID: UUID) {
        self.peerNodeID = peerNodeID
        self.contextID = contextID
    }
}

/// Payload of ``KeepTalkingClientSignals/agentRunCompletions``. Carries the error's
/// description rather than the error: `any Error` is not `Sendable`.
public struct KeepTalkingAgentRunCompletion: Sendable, Equatable {
    public let contextID: UUID
    /// Nil on success or cancellation.
    public let errorDescription: String?

    public init(contextID: UUID, errorDescription: String?) {
        self.contextID = contextID
        self.errorDescription = errorDescription
    }
}
