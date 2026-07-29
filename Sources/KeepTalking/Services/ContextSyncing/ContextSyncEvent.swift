import Foundation

public struct KeepTalkingContextSyncEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case started
        case messagesApplied([UUID])
        // No side-note phase: side notes report through
        // `KeepTalkingClient.onSideNotesChanged`, which fires for local writes
        // and pushes too — not only for changes observed during a reconcile.
        case completed
        case failed(String)
    }

    public let syncID: UUID
    public let contextID: UUID
    public let peerID: UUID
    public let phase: Phase

    public init(
        syncID: UUID,
        contextID: UUID,
        peerID: UUID,
        phase: Phase
    ) {
        self.syncID = syncID
        self.contextID = contextID
        self.peerID = peerID
        self.phase = phase
    }
}
