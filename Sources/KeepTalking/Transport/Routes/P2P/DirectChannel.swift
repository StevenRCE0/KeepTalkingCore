import Foundation

/// Per-peer direct channel backed by a P2P WebRTC transport.
/// Uses ICE connection state as native keepalive — no custom ping/pong needed.
///
/// State transitions:
///   idle → negotiating                 (upgrade requested)
///   negotiating → ready                (ICE connected)
///   negotiating → backingOff           (timeout or ICE failed)
///   ready → interrupted                (ICE disconnected — may recover)
///   interrupted → ready                (ICE reconnected)
///   interrupted → backingOff           (ICE failed)
///   backingOff → negotiating           (backoff expired)
///   backingOff → abandoned             (too many failures)
///   abandoned → idle                   (explicit retry requested)
final class KeepTalkingDirectChannel: KeepTalkingPeerTransportChannel, @unchecked Sendable {

    let route: KeepTalkingTransportRoute = .p2p
    let peerNodeID: UUID

    // MARK: - Protocol callbacks

    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerAlive: (@Sendable (UUID) -> Void)?
    var onSignalOutput: (@Sendable (KeepTalkingP2PSignalPayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    // MARK: - Internal state

    private let config: KeepTalkingConfig
    private let localNodeID: UUID
    private let peersSnapshot: @Sendable () -> [UUID]
    private var p2pClient: KeepTalkingP2PRTCClient?
    private var stateMachine = DirectChannelStateMachine()
    private let stateQueue = DispatchQueue(label: "kt.direct.state")
    private var backoffTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?

    var state: DirectChannelState {
        stateQueue.sync { stateMachine.state }
    }

    var isReady: Bool {
        guard state == .ready else {
            return false
        }
        return p2pClient?.isReady() == true
    }

    // MARK: - Init

    init(
        peerNodeID: UUID,
        config: KeepTalkingConfig,
        localNodeID: UUID,
        peersSnapshot: @escaping @Sendable () -> [UUID]
    ) {
        self.peerNodeID = peerNodeID
        self.config = config
        self.localNodeID = localNodeID
        self.peersSnapshot = peersSnapshot
    }

    // MARK: - Protocol methods

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        guard let client = p2pClient, client.isReady() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try client.sendEnvelope(sequenced.envelope)
    }

    func sendBlobData(_ data: Data) throws {
        guard let client = p2pClient, client.isReady() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try client.sendBlobData(data, targetPeerNodeID: peerNodeID)
    }

    func receiveSignal(_ signal: KeepTalkingP2PSignalPayload) {
        p2pClient?.receiveSignal(signal)
    }

    func attemptUpgrade() {
        applyEvent(.upgradeRequested)
    }

    func teardown() {
        applyEvent(.teardownRequested)
    }

    func requestRetrial() {
        applyEvent(.retryRequested)
    }

    // MARK: - State machine

    private func applyEvent(_ event: DirectChannelEvent) {
        let effect = stateQueue.sync { stateMachine.handle(event) }
        onStateChange?()

        switch effect {
            case .beginHandshake:
                startP2PHandshake()
            case .scheduleBackoff(let seconds):
                scheduleBackoff(seconds: seconds)
            case .cleanup:
                cleanupP2PClient()
            case .none:
                break
        }
    }

    // MARK: - P2P handshake

    private func startP2PHandshake() {
        cleanupP2PClient()

        let p2pConfig = config.withP2PPreferredRemoteID(
            peerNodeID.uuidString.lowercased()
        )

        let client = KeepTalkingP2PRTCClient(
            config: p2pConfig,
            localNodeID: localNodeID,
            sendSignal: { [weak self] to, data in
                guard let self else { return }
                let payload = KeepTalkingP2PSignalPayload(from: self.localNodeID, to: to, data: data)
                self.onSignalOutput?(payload)
            },
            announcePresence: {},
            peersSnapshot: peersSnapshot
        )

        bindP2PCallbacks(client)
        p2pClient = client

        handshakeTimeoutTask = Task { [weak self, config] in
            try? await Task.sleep(for: .seconds(config.p2pAttemptTimeoutSeconds))
            guard let self, !Task.isCancelled else { return }
            let currentState = self.stateQueue.sync { self.stateMachine.state }
            if currentState == .negotiating {
                self.debug("handshake timeout after \(config.p2pAttemptTimeoutSeconds)s")
                self.applyEvent(.handshakeTimeout)
            }
        }

        Task {
            do {
                try await client.start()
            } catch {
                debug("p2p start failed error=\(error.localizedDescription)")
                applyEvent(.iceFailed)
            }
        }
    }

    private func bindP2PCallbacks(_ client: KeepTalkingP2PRTCClient) {
        client.onIceConnected = { [weak self] in
            guard let self else { return }
            self.handshakeTimeoutTask?.cancel()
            self.applyEvent(.iceConnected)
            self.onPeerAlive?(self.peerNodeID)
        }

        client.onIceDisconnected = { [weak self] in
            self?.applyEvent(.iceDisconnected)
        }

        client.onTransportDegraded = { [weak self] reason in
            self?.debug("p2p transport degraded reason=\(reason)")
            self?.applyEvent(.iceFailed)
        }

        client.onEnvelope = { [weak self] envelope in
            guard let self else { return }
            // TODO: Decode sequenced wrapper once wire format includes sequence numbers.
            let sequenced = KeepTalkingSequencedEnvelope(
                senderNode: self.peerNodeID,
                sequence: 0,
                envelope: envelope
            )
            self.onReceive?(sequenced)
        }

        client.onBlobData = { [weak self] data in
            self?.onBlobData?(data)
        }
        client.onRawMessage = nil
        client.onPeerConnect = nil
        client.onLog = onLog
        client.contextSecretProvider = contextSecretProvider
    }

    // MARK: - Backoff

    private func scheduleBackoff(seconds: TimeInterval) {
        backoffTask?.cancel()
        debug("backing off for \(seconds)s")

        backoffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.applyEvent(.backoffExpired)
        }
    }

    // MARK: - Cleanup

    private func cleanupP2PClient() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        backoffTask?.cancel()
        backoffTask = nil

        guard let client = p2pClient else { return }
        p2pClient = nil
        client.onEnvelope = nil
        client.onBlobData = nil
        client.onRawMessage = nil
        client.onPeerConnect = nil
        client.onTransportDegraded = nil
        client.onIceConnected = nil
        client.onIceDisconnected = nil
        client.onLog = nil
        client.contextSecretProvider = nil
        client.stop()
    }

    private func debug(_ message: String) {
        onLog?("[direct:\(peerNodeID.uuidString.prefix(8))] \(message)")
    }
}
