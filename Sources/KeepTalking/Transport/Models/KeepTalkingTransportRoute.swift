import Foundation

/// Physical channel identifier — which wire carried the bytes.
/// Stays as the low-level "what happened" label for stats, logging,
/// and `currentRoute()`. Not a routing decision.
public enum KeepTalkingTransportRoute: String, Codable, Sendable {
    /// Broadcast/unicast through the KeepTalkingSFU over HTTP/2 (with
    /// Ed25519 auth and opaque envelope routing). Also carries
    /// SFU-mediated relay payloads when direct P2P falls back.
    case sfu
    /// Direct P2P to a single peer. libjuice-negotiated ICE only proves the
    /// path; the payload then rides one long-lived bidirectional HTTP/2 stream
    /// over TLS, and the ICE session is closed once that carrier connects.
    case p2p
}
