import Crypto
import Foundation
import KeepTalkingSFUClient
import KeepTalkingSFUProtocol

/// `KeepTalkingTransportClient` over the new Swift `KeepTalkingSFU` server.
/// Carries opaque, encrypted KT envelopes through `SFUClient` rather than
/// over LiveKitWebRTC data channels.
///
/// Phase-1 semantics:
///   * Single context membership = `config.contextID`.
///   * All outbound envelopes are broadcast to that context. Unicast can
///     be added once we wire the trust graph's node UUID → Ed25519 pubkey
///     lookup (right now the SFU peer-ID and KT node ID don't share a
///     namespace, so the cheapest correct path is "broadcast and let the
///     envelope's targetPeerNodeID filter at the destination").
///   * Inbound envelopes go through the same `KeepTalkingPacketTransport
///     Crypto.inboundEnvelope` path the existing routes use.
///   * Blob data is JSON-wrapped into the same opaque envelope stream;
///     a future iteration can use a separate context tag.
final class KeepTalkingSFUJuiceClient: KeepTalkingTransportClient, @unchecked Sendable {
    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onBroadcastReady: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onTransportDegraded: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let sfuHost: String
    private let sfuPort: UInt16
    private let signingKey: Curve25519.Signing.PrivateKey
    private let client: SFUClient

    /// 32-byte Ed25519 public key registered with the SFU; surfaced so
    /// the public `KeepTalkingSFUJuiceSession` wrapper can expose it.
    var signingPublicKey: Data {
        signingKey.publicKey.rawRepresentation
    }

    /// Presence event forwarded by the SFU. Internal because the wire-
    /// type `SFUClient.PresenceEvent` is from a different module — the
    /// public `KeepTalkingSFUJuiceSession.PresenceEvent` mirrors it.
    enum PresenceEvent {
        case snapshot(context: UUID, peers: [Data])
        case joined(context: UUID, pubkey: Data)
        case left(context: UUID, pubkey: Data)
    }

    /// Set by the public session wrapper to receive presence events. The
    /// trampoline avoids leaking `SFUClient.PresenceEvent` through the
    /// SDK's public surface.
    var presenceForwarder: ((PresenceEvent) -> Void)?

    /// Channel-aware inbound forwarder. The protocol-level `onEnvelope`
    /// flattens to "decoded envelope or opaque bytes" and drops the
    /// sender/channel metadata; this forwarder surfaces those so the
    /// session can dispatch (e.g. route p2pSignal channel frames into
    /// the libjuice agent).
    var rawInboundForwarder: ((SFUClient.InboundEnvelope) -> Void)?

    /// Direct unicast: routes opaque bytes to a specific peer pubkey on
    /// a specific channel. Used by the session's
    /// `route(rawBytes:to:channel:)` so the lab can do ICE-over-SFU
    /// without going through the envelope-crypto path.
    func routeRawBytes(_ data: Data, to peer: Data, channel: SFUChannel) {
        client.route(envelope: data, to: peer, channel: channel)
    }

    /// Broadcast opaque bytes on a specific channel. Companion to
    /// `routeRawBytes`.
    func broadcastRawBytes(_ data: Data, channel: SFUChannel) {
        client.broadcast(envelope: data, context: config.contextID, channel: channel)
    }

    /// Asks the SFU for the current peer roster on the configured
    /// context. Response arrives asynchronously via `presenceForwarder`.
    func requestPeerRoster() {
        client.listPeers(context: config.contextID)
    }

    // MARK: - SFU relay

    /// Fires when a remote peer opens an SFU-mediated relay to us. The
    /// session-layer wrapper uses this to plumb a relay into a pending
    /// `KeepTalkingDirectChannel` for the originating peer.
    var onRelayOpen: ((_ relayID: Data, _ peer: Data, _ context: UUID) -> Void)?
    var onRelayData: ((_ relayID: Data, _ payload: Data) -> Void)?
    var onRelayClose: ((_ relayID: Data, _ reason: UInt8) -> Void)?

    @discardableResult
    func openRelay(to peer: Data) -> Data {
        client.openRelay(to: peer, context: config.contextID)
    }

    func sendRelayData(_ payload: Data, on relayID: Data) {
        client.sendRelayData(payload, on: relayID)
    }

    func closeRelay(_ relayID: Data, reason: UInt8 = SFURelayCloseReason.normal) {
        client.closeRelay(relayID, reason: reason)
    }

    private let stateQueue = DispatchQueue(label: "kt.transport.sfu-juice.state")
    private var sentCount = 0
    private var recvCount = 0
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didReportBroadcastReady = false

    init(
        config: KeepTalkingConfig,
        sfuHost: String,
        sfuPort: UInt16,
        signingKey: Curve25519.Signing.PrivateKey = .init()
    ) {
        self.config = config
        self.sfuHost = sfuHost
        self.sfuPort = sfuPort
        self.signingKey = signingKey
        self.client = SFUClient(
            configuration: .init(host: sfuHost, port: Int(sfuPort)),
            signingKey: signingKey
        )
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [sfu-juice] \(message)")
    }

    // MARK: - Lifecycle

    func start() async throws {
        debug("starting host=\(sfuHost):\(sfuPort) context=\(config.contextID.uuidString.lowercased())")

        client.onLog = { [weak self] msg in self?.debug(msg) }
        client.onState = { [weak self] state in
            self?.handleClientState(state)
        }
        client.onEnvelope = { [weak self] inbound in
            // Pre-handler hook: lets the session-layer wrapper see the
            // full channel/sender info before we collapse to the
            // transport-protocol surface.
            self?.rawInboundForwarder?(inbound)
            self?.handleInboundEnvelope(inbound)
        }
        client.onRelayOpen = { [weak self] relayID, peer, ctx in
            self?.onRelayOpen?(relayID, peer, ctx)
        }
        client.onRelayData = { [weak self] relayID, payload in
            self?.onRelayData?(relayID, payload)
        }
        client.onRelayClose = { [weak self] relayID, reason in
            self?.onRelayClose?(relayID, reason)
        }
        client.onPresence = { [weak self] presence in
            guard let self else { return }
            let mapped: PresenceEvent
            switch presence {
                case .snapshot(let cid, let peers):
                    mapped = .snapshot(context: cid, peers: peers)
                case .joined(let cid, let pubkey):
                    mapped = .joined(context: cid, pubkey: pubkey)
                case .left(let cid, let pubkey):
                    mapped = .left(context: cid, pubkey: pubkey)
            }
            self.presenceForwarder?(mapped)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateQueue.sync {
                readyContinuation = cont
            }
            client.connect()
            client.join(context: config.contextID)
        }
    }

    func stop() {
        debug("stopping sent=\(sentCount) recv=\(recvCount)")
        client.close()
    }

    // MARK: - Transport protocol

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        let payload =
            try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: config.node,
                contextSecretProvider: contextSecretProvider
            )
        client.broadcast(envelope: payload, context: config.contextID)
        stateQueue.sync { sentCount += 1 }
    }

    func sendBlobData(_ data: Data, targetPeerNodeID: UUID?) throws {
        // Blob data is opaque to the SFU. For phase-1 we just stuff it
        // through the broadcast channel; the receiver routes via
        // onBlobData based on the framing the application already uses
        // on top.
        client.broadcast(envelope: data, context: config.contextID)
        stateQueue.sync { sentCount += 1 }
    }

    func currentRoute() -> KeepTalkingTransportRoute { .sfu }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        KeepTalkingRuntimeStats(
            sent: sentCount,
            received: recvCount,
            outboundLabel: "sfu-juice/broadcast",
            outboundState: clientStateForStats(),
            inboundLabel: "sfu-juice/broadcast",
            inboundState: clientStateForStats(),
            retainedChannels: 1,
            route: "sfu-juice"
        )
    }

    func requestP2PTrial() {
        // No-op: this route never upgrades; if KT wants P2P, the SDK
        // should swap in the libjuice-based P2P client instead.
    }

    func preferReliableRoute(reason: String) {
        // No-op: SFU is the reliable route.
    }

    // MARK: - Internal

    private func clientStateForStats() -> Int {
        switch client.state {
            case .ready: return 1
            case .connecting, .authenticating, .idle: return 0
            case .closed, .failed: return -1
        }
    }

    private func handleClientState(_ state: SFUClient.State) {
        debug("client state=\(state)")
        switch state {
            case .ready:
                // Flush the ready continuation exactly once.
                var continuation: CheckedContinuation<Void, Error>?
                stateQueue.sync {
                    continuation = readyContinuation
                    readyContinuation = nil
                }
                continuation?.resume()
                if !didReportBroadcastReady {
                    didReportBroadcastReady = true
                    onBroadcastReady?()
                }
            case .failed(let reason):
                var continuation: CheckedContinuation<Void, Error>?
                stateQueue.sync {
                    continuation = readyContinuation
                    readyContinuation = nil
                }
                continuation?.resume(throwing: SFUJuiceError.connectFailed(reason))
                onTransportDegraded?(reason)
            case .closed:
                onTransportDegraded?("sfu client closed")
            case .idle, .connecting, .authenticating:
                break
        }
    }

    private func handleInboundEnvelope(_ inbound: SFUClient.InboundEnvelope) {
        stateQueue.sync { recvCount += 1 }
        do {
            if let envelope =
                try KeepTalkingPacketTransportCrypto
                .inboundEnvelope(
                    from: inbound.bytes,
                    contextSecretProvider: contextSecretProvider
                )
            {
                onEnvelope?(envelope)
                return
            }
        } catch {
            debug("envelope decode failed: \(error.localizedDescription)")
        }
        // Fall back to passing the bytes through the blob handler so
        // the caller can decide what to do.
        onBlobData?(inbound.bytes)
    }
}

enum SFUJuiceError: LocalizedError {
    case connectFailed(String)

    var errorDescription: String? {
        switch self {
            case .connectFailed(let reason):
                return "KeepTalkingSFU connect failed: \(reason)"
        }
    }
}
