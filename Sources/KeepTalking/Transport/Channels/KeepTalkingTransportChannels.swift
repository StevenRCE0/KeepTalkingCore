import Foundation

// MARK: - Transport Channel Protocol

/// Shared interface for any transport channel (broadcast or direct).
/// ContextTransport depends ONLY on this protocol — never on concrete transport types.
protocol KeepTalkingTransportChannelProtocol: AnyObject, Sendable {
    /// Whether the channel is currently able to send messages.
    var isReady: Bool { get }

    /// The transport route this channel represents.
    var route: KeepTalkingTransportRoute { get }

    /// Send a sequenced envelope through this channel.
    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws

    /// Send raw blob bytes through this channel.
    func sendBlobData(_ data: Data) throws

    /// Called when the channel receives an inbound sequenced envelope.
    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)? { get set }

    /// Called when the channel receives inbound blob bytes.
    var onBlobData: KeepTalkingTransportBlobDataHandler? { get set }

    /// Called when the channel's readiness state changes.
    var onStateChange: (@Sendable () -> Void)? { get set }

    /// Optional debug log sink shared by transport channels.
    var onLog: (@Sendable (String) -> Void)? { get set }
}

// MARK: - Broadcast Transport Channel Protocol

/// Extended protocol for the always-on broadcast backbone.
protocol KeepTalkingBroadcastTransportChannel: KeepTalkingTransportChannelProtocol {
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? { get set }
    var state: BroadcastChannelState { get }

    func start() async throws
    func stop()
    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws
    func runtimeStats() -> KeepTalkingRuntimeStats
}

// MARK: - Peer Transport Channel Protocol

/// Extended protocol for channels that target a specific peer (direct channels).
protocol KeepTalkingPeerTransportChannel: KeepTalkingTransportChannelProtocol {
    /// The remote peer this channel connects to.
    var peerNodeID: UUID { get }

    /// Per-context transport secret provider used for encrypted packet payloads.
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? { get set }

    /// Called when the peer is confirmed alive (e.g., ICE connected).
    var onPeerAlive: (@Sendable (UUID) -> Void)? { get set }

    /// Called when the channel needs to send signaling data via the broadcast backbone.
    var onSignalOutput: (@Sendable (KeepTalkingP2PSignalPayload) -> Void)? { get set }

    /// Forward an incoming P2P signal to this channel's underlying transport.
    func receiveSignal(_ signal: KeepTalkingP2PSignalPayload)

    /// Begin the P2P upgrade handshake.
    func attemptUpgrade()

    /// Tear down the channel and release resources.
    func teardown()

    /// Reset from abandoned state and allow future upgrade attempts.
    func requestRetrial()
}

// MARK: - Transport Error

enum KeepTalkingTransportError: LocalizedError {
    case allChannelsUnavailable

    var errorDescription: String? {
        switch self {
            case .allChannelsUnavailable:
                return "All transport channels are unavailable."
        }
    }
}
