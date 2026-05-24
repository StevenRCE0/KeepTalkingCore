import Foundation

public enum KeepTalkingTransportRoute: String, Codable, Sendable {
    /// Broadcast/unicast through the KeepTalkingSFU over HTTP/2 (with
    /// Ed25519 auth and opaque envelope routing). Also carries
    /// SFU-mediated relay payloads when direct P2P falls back.
    case sfu
    /// Direct P2P over libjuice-negotiated ICE with QUIC on top.
    case p2p
}
