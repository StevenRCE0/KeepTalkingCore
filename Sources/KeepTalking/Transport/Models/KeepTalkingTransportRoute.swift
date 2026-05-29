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

/// Sealed routing policy. Declares *intent* — the transport resolves
/// it against current channel availability at send time.
///
/// Each case is a self-contained decision rule. The transport never
/// inspects a raw route list — it pattern-matches on the strategy and
/// applies the corresponding logic (retry, fallback, mesh-cap check).
///
/// Envelope kinds map to exactly one strategy via
/// `KeepTalkingEnvelopeKind.routingStrategy`. Call sites that build
/// their own sends (e.g. `sendBlobData`) pick a strategy directly.
public enum KeepTalkingRoutingStrategy: String, Sendable {
    /// Try P2P first; fall back to SFU on failure or if no direct
    /// channel is ready. Optimistic — lowest latency when the path
    /// exists. Used by chat messages, context sync, action calls.
    case preferDirect

    /// SFU only — never attempt P2P even if a direct channel is
    /// ready. Used by signaling, presence, trust handshakes, voice
    /// call envelopes — things that must fan-out to all context
    /// peers or that the SFU needs to observe for presence.
    case sfuOnly

    /// Prefer SFU for reliability; only try P2P if the SFU is
    /// degraded/reconnecting. The inverse of `.preferDirect` — pays
    /// the relay hop for guaranteed delivery. Used by blob data and
    /// any path where dropped frames are worse than latency.
    case conservative

    /// Ordered route list for the legacy `send(preferredRoutes:)`
    /// path. Remove once `ContextTransport.send` dispatches on
    /// strategy directly.
    var orderedRoutes: [KeepTalkingTransportRoute] {
        switch self {
            case .preferDirect: return [.p2p, .sfu]
            case .sfuOnly: return [.sfu]
            case .conservative: return [.sfu, .p2p]
        }
    }
}
