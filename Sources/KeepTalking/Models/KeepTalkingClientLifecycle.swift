import Foundation

extension KeepTalkingClient {
    /// Coarse health of the always-on broadcast (SFU) backbone, derived
    /// purely from the transport's own pushed state — never a probe.
    ///
    /// The carriers already self-report liveness: libjuice consent-freshness
    /// for ICE, and `HTTP2KeepAliveHandler` (PING / read-deadline) for both
    /// the SFU and P2P HTTP/2 channels. Loss flips `BroadcastChannelState`
    /// without any polling here. This enum is just a consumer-facing read of
    /// that state so callers (e.g. the app's foreground-resume path) can
    /// decide whether a re-establish is even warranted.
    ///
    /// P2P readiness is intentionally *not* reflected: a dead direct channel's
    /// recovery is SFU fallback, handled inside the transport — it never
    /// justifies tearing down the client.
    public enum TransportHealth: Sendable, Equatable {
        /// Broadcast backbone is ready. The path may still be stale-open
        /// (rare); callers that care can confirm with `probeTransport()`.
        case healthy
        /// Backbone is being brought up or is mid-reconnect. The state
        /// machine retries with backoff and never gives up — leave it alone;
        /// do not re-establish.
        case recovering
        /// Backbone is down (only reachable via an explicit stop). A
        /// re-establish is warranted.
        case down

        init(_ state: BroadcastChannelState) {
            switch state {
                case .ready:
                    self = .healthy
                case .connecting, .reconnecting:
                    self = .recovering
                case .failed:
                    self = .down
            }
        }
    }
}

/// One value of ``KeepTalkingClientSignals/lifecycle``: where the connection is,
/// which generation it belongs to, and what the transport last reported.
public struct KeepTalkingClientLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// No transport and nothing in flight.
        case idle
        /// `connect()` is bringing the transport up.
        case connecting
        /// The transport is up; `transport` and `route` are live.
        case connected
        /// A teardown is in flight; `idle` follows once the transport stopped
        /// — unless a new `connect()` supersedes it first.
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
        /// The transport fully stopped.
        case tornDown
        /// Still `connected`; transport health or route moved.
        case transportChanged
    }

    public let phase: Phase
    public let generation: UInt64
    /// `.down` unless the phase is `connecting` or `connected`. While
    /// connecting it reads `.recovering` — the backbone is being brought up —
    /// and only a `connected` value tracks later changes.
    public let transport: KeepTalkingClient.TransportHealth
    /// `.sfu` unless the phase is `connecting` or `connected`.
    public let route: KeepTalkingTransportRoute
    public let cause: Cause

    public var isConnected: Bool {
        phase == .connected
    }

    public init(
        phase: Phase,
        generation: UInt64,
        transport: KeepTalkingClient.TransportHealth,
        route: KeepTalkingTransportRoute,
        cause: Cause
    ) {
        self.phase = phase
        self.generation = generation
        self.transport = transport
        self.route = route
        self.cause = cause
    }
}

/// One value of ``KeepTalkingClientSignals/presence``: the remote peers currently
/// reachable and the change that produced this value.
public struct KeepTalkingClientPresence: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case online(UUID)
        case offline(UUID)
        /// The set was cleared (transport torn down).
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
