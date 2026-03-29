import Foundation

// MARK: - Broadcast Channel State Machine

/// State of the always-on broadcast (SFU) channel.
public enum BroadcastChannelState: Sendable, Equatable {
    case connecting
    case ready
    case reconnecting(attempt: Int)
    case failed
}

/// Events that drive broadcast channel state transitions.
public enum BroadcastChannelEvent: Sendable {
    case channelsOpened
    case transportDegraded
    case reconnectSucceeded
    case reconnectFailed
    case stopped
}

/// Side effects the channel implementation must execute after a state transition.
public enum BroadcastChannelEffect: Sendable, Equatable {
    case startReconnect(attempt: Int)
    case none
}

/// Pure value-type state machine for the broadcast channel.
/// Takes an event, returns a new state and an effect to execute.
/// No side effects, no async — fully testable.
public struct BroadcastChannelStateMachine: Sendable {
    public private(set) var state: BroadcastChannelState = .connecting

    public init() {}

    @discardableResult
    public mutating func handle(_ event: BroadcastChannelEvent) -> BroadcastChannelEffect {
        switch (state, event) {
            case (.connecting, .channelsOpened):
                state = .ready
                return .none

            case (.ready, .transportDegraded):
                state = .reconnecting(attempt: 1)
                return .startReconnect(attempt: 1)

            case (.reconnecting(let n), .reconnectFailed):
                let next = n + 1
                state = .reconnecting(attempt: next)
                return .startReconnect(attempt: next)

            case (.reconnecting, .reconnectSucceeded),
                (.reconnecting, .channelsOpened):
                state = .ready
                return .none

            case (_, .stopped):
                state = .failed
                return .none

            default:
                return .none
        }
    }
}

// MARK: - Direct Channel State Machine

/// State of a per-peer direct (P2P) channel.
public enum DirectChannelState: Sendable, Equatable {
    case idle
    case negotiating
    case ready
    case interrupted
    case backingOff(until: Date)
    case abandoned
}

/// Events that drive direct channel state transitions.
public enum DirectChannelEvent: Sendable {
    case upgradeRequested
    case iceConnected
    case iceDisconnected
    case iceFailed
    case handshakeTimeout
    case backoffExpired
    case retryRequested
    case teardownRequested
}

/// Side effects the channel implementation must execute after a state transition.
public enum DirectChannelEffect: Sendable, Equatable {
    case beginHandshake
    case scheduleBackoff(seconds: TimeInterval)
    case cleanup
    case none
}

/// Pure value-type state machine for a direct channel.
/// Takes an event, returns a new state and an effect to execute.
/// No side effects, no async — fully testable.
public struct DirectChannelStateMachine: Sendable {
    public private(set) var state: DirectChannelState = .idle
    public private(set) var failureCount: Int = 0

    public static let maxFailures = 3
    public static let maxBackoffSeconds: TimeInterval = 16

    public init() {}

    @discardableResult
    public mutating func handle(_ event: DirectChannelEvent) -> DirectChannelEffect {
        switch (state, event) {
            case (.idle, .upgradeRequested):
                state = .negotiating
                return .beginHandshake

            case (.negotiating, .iceConnected):
                state = .ready
                failureCount = 0
                return .none

            case (.negotiating, .handshakeTimeout),
                (.negotiating, .iceFailed):
                return applyFailure()

            case (.ready, .iceDisconnected):
                state = .interrupted
                return .none

            case (.interrupted, .iceConnected):
                state = .ready
                return .none

            case (.interrupted, .iceFailed):
                return applyFailure()

            case (.backingOff, .backoffExpired):
                state = .negotiating
                return .beginHandshake

            case (.abandoned, .retryRequested):
                failureCount = 0
                state = .idle
                return .none

            case (_, .teardownRequested):
                state = .idle
                failureCount = 0
                return .cleanup

            default:
                return .none
        }
    }

    private mutating func applyFailure() -> DirectChannelEffect {
        failureCount += 1
        if failureCount >= Self.maxFailures {
            state = .abandoned
            return .cleanup
        }
        let delay = min(2.0 * pow(2.0, Double(failureCount - 1)), Self.maxBackoffSeconds)
        state = .backingOff(until: Date().addingTimeInterval(delay))
        return .scheduleBackoff(seconds: delay)
    }
}
