import Foundation

/// Physical channel identifier — which wire carried the bytes.
/// Stays as the low-level "what happened" label for stats, logging,
/// and `currentRoute()`. Not a routing decision.
public enum KeepTalkingTransportRoute: String, Codable, Sendable {
    /// Broadcast/unicast through the KeepTalkingSFU over HTTP/2 (with
    /// Ed25519 auth and opaque envelope routing). Also carries
    /// SFU-mediated relay payloads when direct P2P falls back.
    case sfu
    /// Direct P2P over libjuice-negotiated ICE with QUIC on top.
    case p2p
}

/// Snapshot of channel readiness at send time. The transport builds
/// this once and hands it to `strategy.resolve(_:)`.
public struct KeepTalkingRouteAvailability: Sendable {
    /// Whether a direct P2P channel to the target peer is connected
    /// and ready to send.
    public let p2pReady: Bool
    /// Whether the SFU broadcast channel is connected.
    public let sfuReady: Bool
    /// Target peer UUID, if this is a directed send.
    public let targetPeer: UUID?

    public init(p2pReady: Bool, sfuReady: Bool, targetPeer: UUID? = nil) {
        self.p2pReady = p2pReady
        self.sfuReady = sfuReady
        self.targetPeer = targetPeer
    }
}

// MARK: - Routing policy tag

/// Lightweight tag that envelope kinds declare. The transport maps
/// this to a live `KeepTalkingRoutingStrategy` instance at send time.
public enum KeepTalkingRoutingPolicy: String, Sendable {
    case preferDirect
    case sfuOnly
    case conservative

    /// Legacy shim.
    var orderedRoutes: [KeepTalkingTransportRoute] {
        switch self {
            case .preferDirect: return [.p2p, .sfu]
            case .sfuOnly: return [.sfu]
            case .conservative: return [.sfu, .p2p]
        }
    }
}

// MARK: - Routing strategy protocol

/// Stateful or stateless routing strategy. The transport holds
/// concrete instances and calls `resolve` at send time — never
/// switches on an enum case.
///
/// Stateless strategies (`.preferDirect`, `.sfuOnly`) ignore
/// `recordFault` / `tick`. Stateful ones (`.conservative`) carry
/// their own per-peer promotion/demotion state internally.
public protocol KeepTalkingRoutingStrategy: AnyObject, Sendable {
    /// Given current channel availability, return the route to
    /// send on — or `nil` if no route is available.
    func resolve(_ availability: KeepTalkingRouteAvailability) -> KeepTalkingTransportRoute?
    /// A P2P send failed for `peer`. Stateful strategies may
    /// demote or lock the peer.
    func recordFault(for peer: UUID)
    /// Heartbeat tick. `p2pReady` is the direct channel's current
    /// readiness for `peer`. Stateful strategies track consecutive
    /// stable waves for promotion.
    func tick(peer: UUID, p2pReady: Bool)
    /// Reset all per-peer state (e.g. on transport stop).
    func reset()
}

// Default no-ops for stateless strategies.
extension KeepTalkingRoutingStrategy {
    public func recordFault(for peer: UUID) {}
    public func tick(peer: UUID, p2pReady: Bool) {}
    public func reset() {}
}

// MARK: - Concrete strategies

public final class KeepTalkingPreferDirectStrategy: KeepTalkingRoutingStrategy, @unchecked Sendable {
    public init() {}

    public func resolve(_ availability: KeepTalkingRouteAvailability) -> KeepTalkingTransportRoute? {
        if availability.p2pReady { return .p2p }
        if availability.sfuReady { return .sfu }
        return nil
    }
}

public final class KeepTalkingSFUOnlyStrategy: KeepTalkingRoutingStrategy, @unchecked Sendable {
    public init() {}

    public func resolve(_ availability: KeepTalkingRouteAvailability) -> KeepTalkingTransportRoute? {
        availability.sfuReady ? .sfu : nil
    }
}

/// Starts on SFU. Promotes P2P for a peer only after `promotionWaves`
/// consecutive heartbeat ticks where the direct channel was ready.
/// Demotes on channel loss; records faults on send failure and locks
/// to SFU permanently after `maxFaults` lifetime faults per peer.
public final class KeepTalkingConservativeStrategy: KeepTalkingRoutingStrategy, @unchecked Sendable {
    public let promotionWaves: Int
    public let maxFaults: Int

    private let lock = NSLock()
    private var peers: [UUID: PeerState] = [:]

    public init(promotionWaves: Int = 3, maxFaults: Int = 3) {
        self.promotionWaves = promotionWaves
        self.maxFaults = maxFaults
    }

    struct PeerState {
        var promoted: Bool = false
        var consecutiveStableWaves: Int = 0
        var lifetimeFaults: Int = 0
        var locked: Bool = false
    }

    public func resolve(_ availability: KeepTalkingRouteAvailability) -> KeepTalkingTransportRoute? {
        if let peer = availability.targetPeer {
            let state = lock.withLock { peers[peer] }
            if let state, state.promoted, !state.locked, availability.p2pReady {
                return .p2p
            }
        }
        if availability.sfuReady { return .sfu }
        return nil
    }

    public func recordFault(for peer: UUID) {
        lock.withLock {
            var state = peers[peer, default: PeerState()]
            state.lifetimeFaults += 1
            state.consecutiveStableWaves = 0
            state.promoted = false
            if state.lifetimeFaults >= maxFaults {
                state.locked = true
            }
            peers[peer] = state
        }
    }

    public func tick(peer: UUID, p2pReady: Bool) {
        lock.withLock {
            var state = peers[peer, default: PeerState()]
            guard !state.locked else { return }
            if p2pReady {
                state.consecutiveStableWaves += 1
                if !state.promoted, state.consecutiveStableWaves >= promotionWaves {
                    state.promoted = true
                }
            } else {
                state.consecutiveStableWaves = 0
                state.promoted = false
            }
            peers[peer] = state
        }
    }

    public func reset() {
        lock.withLock { peers.removeAll() }
    }

    // MARK: - Test inspection

    public func peerState(for peer: UUID) -> (promoted: Bool, faults: Int, locked: Bool)? {
        lock.withLock {
            guard let s = peers[peer] else { return nil }
            return (s.promoted, s.lifetimeFaults, s.locked)
        }
    }
}
