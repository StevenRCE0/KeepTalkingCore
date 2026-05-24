import Crypto
import Foundation
import KeepTalkingSFUClient
import KeepTalkingSFUProtocol

/// Public CLI-driveable wrapper around the internal `KeepTalkingSFUJuice
/// Client`. Lets external callers (the KT CLI, eventually app smoke tests)
/// exercise the KeepTalkingSFU round-trip without going through the full
/// `KeepTalkingContextTransport` orchestration.
///
/// Phase-1 surface area is deliberately narrow: connect, send envelopes
/// over the configured context, observe inbound envelopes/blobs. Full
/// ContextTransport integration (route arbitration, peer trust graph,
/// liveness state) is a follow-up.
public final class KeepTalkingSFUJuiceSession: @unchecked Sendable {
    /// SDK-facing mirror of `SFUChannel` — kept here so callers don't
    /// need to `import KeepTalkingSFUProtocol`. Wire values must stay
    /// aligned with the protocol enum.
    public enum Channel: Sendable, Hashable {
        case chat
        case blob
        case actionCall
        case signaling
        case p2pSignal

        var wireValue: SFUChannel {
            switch self {
                case .chat: return .chat
                case .blob: return .blob
                case .actionCall: return .actionCall
                case .signaling: return .signaling
                case .p2pSignal: return .p2pSignal
            }
        }

        init(_ wire: SFUChannel) {
            switch wire {
                case .chat: self = .chat
                case .blob: self = .blob
                case .actionCall: self = .actionCall
                case .signaling: self = .signaling
                case .p2pSignal: self = .p2pSignal
            }
        }
    }

    /// Inbound payload — either a decoded KT envelope or, if decode
    /// failed (no shared context secret), opaque bytes. Both cases
    /// carry the channel byte the sender stamped and the sender's
    /// 32-byte pubkey (signature already verified by the SDK).
    public enum InboundPayload: Sendable {
        case envelope(any KeepTalkingEnvelope, channel: Channel, sender: Data)
        case opaqueBytes(Data, channel: Channel, sender: Data)
    }

    public var onInbound: (@Sendable (InboundPayload) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    public var onPresence: (@Sendable (PresenceEvent) -> Void)?

    /// Presence events surfaced by the SFU. The 32-byte `pubkey` is the
    /// Ed25519 public key the remote peer used to authenticate; callers
    /// can compare it against trusted-peer records to know which KT node
    /// it represents.
    public enum PresenceEvent: Sendable {
        case snapshot(context: UUID, peers: [Data])
        case joined(context: UUID, pubkey: Data)
        case left(context: UUID, pubkey: Data)
    }

    private let inner: KeepTalkingSFUJuiceClient
    private let config: KeepTalkingConfig

    public init(
        config: KeepTalkingConfig,
        sfuHost: String,
        sfuPort: UInt16,
        signingKey: Curve25519.Signing.PrivateKey
    ) {
        self.config = config
        self.inner = KeepTalkingSFUJuiceClient(
            config: config,
            sfuHost: sfuHost,
            sfuPort: sfuPort,
            signingKey: signingKey
        )
        inner.onLog = { [weak self] msg in self?.onLog?(msg) }
        // The legacy onEnvelope / onBlobData closures still exist on the
        // KeepTalkingTransportClient protocol but the session no longer
        // uses them — the channel-aware rawInboundForwarder gives us the
        // sender + channel metadata that the protocol surface erases.
        inner.rawInboundForwarder = { [weak self] inbound in
            self?.dispatchInbound(inbound)
        }
        inner.presenceForwarder = { [weak self] event in
            switch event {
                case .snapshot(let cid, let peers):
                    self?.onPresence?(.snapshot(context: cid, peers: peers))
                case .joined(let cid, let pubkey):
                    self?.onPresence?(.joined(context: cid, pubkey: pubkey))
                case .left(let cid, let pubkey):
                    self?.onPresence?(.left(context: cid, pubkey: pubkey))
            }
        }
    }

    /// Asks the SFU for a snapshot of the current peer roster on the
    /// configured context. The result arrives via `onPresence(.snapshot)`.
    public func requestPeerRoster() {
        inner.requestPeerRoster()
    }

    public func start() async throws {
        try await inner.start()
    }

    public func stop() {
        inner.stop()
    }

    public func send(envelope: any KeepTalkingEnvelope) throws {
        try inner.sendEnvelope(envelope)
    }

    /// Broadcast raw bytes to every peer in the configured context.
    /// Defaults to the `.blob` channel; the lab can override (e.g.
    /// `.p2pSignal` for SDP exchange).
    public func broadcastRawBytes(_ data: Data, channel: Channel = .blob) {
        inner.broadcastRawBytes(data, channel: channel.wireValue)
    }

    /// Unicast raw bytes to a specific peer pubkey on a specific
    /// channel. The SFU validates `sender == this client` server-side
    /// and forwards to `peer`; the receiver's signature check confirms
    /// authenticity end-to-end.
    public func routeRawBytes(_ data: Data, to peer: Data, channel: Channel) {
        precondition(peer.count == 32, "peer pubkey must be 32 bytes")
        inner.routeRawBytes(data, to: peer, channel: channel.wireValue)
    }

    public var publicKey: Data {
        // The 32-byte Ed25519 pub bytes registered with the server, which
        // other peers use to address us via `route(envelope:to:)`.
        inner.signingPublicKey
    }

    // MARK: - Internal

    private func dispatchInbound(_ inbound: KeepTalkingSFUInboundEnvelope) {
        let channel = Channel(inbound.channel)
        // First try the existing envelope crypto path (context-secret
        // AEAD / per-relation keypair). If it returns a decoded envelope,
        // surface that — otherwise fall back to opaque bytes carrying
        // the channel + sender for the caller to dispatch on.
        if let envelope =
            try? KeepTalkingPacketTransportCrypto
            .inboundEnvelope(
                from: inbound.bytes,
                contextSecretProvider: nil
            )
        {
            onInbound?(.envelope(envelope, channel: channel, sender: inbound.sender))
        } else {
            onInbound?(.opaqueBytes(inbound.bytes, channel: channel, sender: inbound.sender))
        }
    }
}

/// Sibling type alias so the dispatcher signature reads cleanly without
/// pulling the underlying client's `SFUClient.InboundEnvelope` into the
/// public surface area.
typealias KeepTalkingSFUInboundEnvelope = SFUClient.InboundEnvelope
