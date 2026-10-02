import Foundation

/// One value of ``KeepTalkingClientSignals/lifecycle``: where the connection is,
/// which generation it belongs to, and how its room on the process-wide
/// transport is doing.
public struct KeepTalkingClientLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Not attached and nothing in flight.
        case idle
        /// `connect()` is attaching the context.
        case connecting
        /// Attached; `transport` is live.
        case connected
        /// Detaching; `idle` follows at once.
        case disconnecting
    }

    /// What produced this value.
    public enum Cause: Sendable, Equatable {
        case initial
        case connectRequested
        case connected
        /// Terminal `idle` (or the `disconnecting` before it) after a failed
        /// `connect()`, with the error's description.
        case connectFailed(String)
        case disconnectRequested
        /// Detached.
        case tornDown
        /// Still `connected`; the room's status moved.
        case transportChanged
    }

    public let phase: Phase
    public let generation: UInt64
    /// `.offline` unless the phase is `connecting` or `connected`. While
    /// connecting it reads `.connecting`; only a `connected` value tracks
    /// later changes.
    public let transport: KeepTalkingTransportStatus
    public let cause: Cause

    public var isConnected: Bool {
        phase == .connected
    }

    public init(
        phase: Phase,
        generation: UInt64,
        transport: KeepTalkingTransportStatus,
        cause: Cause
    ) {
        self.phase = phase
        self.generation = generation
        self.transport = transport
        self.cause = cause
    }
}

/// One value of ``KeepTalkingClientSignals/presence``: the remote peers currently
/// reachable and the change that produced this value.
public struct KeepTalkingClientPresence: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case online(UUID)
        case offline(UUID)
        /// The set was cleared (the client disconnected).
        case reset
    }

    /// Remote peers only — never the local node.
    public let onlineNodeIDs: Set<UUID>
    public let change: Change

    public init(onlineNodeIDs: Set<UUID>, change: Change) {
        self.onlineNodeIDs = onlineNodeIDs
        self.change = change
    }
}
