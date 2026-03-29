import Foundation

/// Always-on broadcast channel backed by an SFU transport.
/// Wraps the underlying SFU client with explicit state machine management.
///
/// State transitions:
///   connecting → ready            (channels opened)
///   ready → reconnecting(1)       (transport degraded)
///   reconnecting(n) → ready       (reconnect succeeded)
///   reconnecting(n) → reconnecting(n+1)  (retry — never gives up)
///   any → failed                  (explicitly stopped)
final class KeepTalkingBroadcastChannel: KeepTalkingBroadcastTransportChannel, @unchecked Sendable {

    let route: KeepTalkingTransportRoute = .sfu

    // MARK: - Protocol callbacks

    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)?
    var onStateChange: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    // MARK: - Internal state

    private let sfuClient: KeepTalkingRTCClient
    private let config: KeepTalkingConfig
    private var stateMachine = BroadcastChannelStateMachine()
    private let stateQueue = DispatchQueue(label: "kt.broadcast.state")
    private var reconnectTask: Task<Void, Never>?

    var state: BroadcastChannelState {
        stateQueue.sync { stateMachine.state }
    }

    var isReady: Bool {
        state == .ready
    }

    // MARK: - Init

    init(config: KeepTalkingConfig) {
        self.config = config
        self.sfuClient = KeepTalkingRTCClient(config: config)
    }

    // MARK: - Lifecycle

    func start() async throws {
        bindSFUCallbacks()
        try await sfuClient.start()
        applyEvent(.channelsOpened)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sfuClient.stop()
        applyEvent(.stopped)
    }

    // MARK: - Send

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        try sfuClient.sendEnvelope(sequenced.envelope)
    }

    func sendBlobData(_ data: Data) throws {
        try sfuClient.sendBlobData(data, targetPeerNodeID: nil)
    }

    /// Send a raw (non-sequenced) envelope — used for presence and signaling.
    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        try sfuClient.sendEnvelope(envelope)
    }

    // MARK: - SFU callback binding

    private func bindSFUCallbacks() {
        sfuClient.onEnvelope = { [weak self] envelope in
            self?.handleSFUEnvelope(envelope)
        }
        sfuClient.onBlobData = nil
        sfuClient.onRawMessage = nil
        sfuClient.onPeerConnect = nil
        sfuClient.onTransportDegraded = { [weak self] reason in
            self?.debug("sfu transport degraded reason=\(reason)")
            self?.applyEvent(.transportDegraded)
        }
        sfuClient.onLog = onLog
    }

    private func handleSFUEnvelope(_ envelope: any KeepTalkingEnvelope) {
        // TODO: Decode sequenced wrapper once wire format includes sequence numbers.
        // For now, wrap with a synthetic sequence so the receive path works.
        let sequenced = KeepTalkingSequencedEnvelope(
            senderNode: UUID(),
            sequence: 0,
            envelope: envelope
        )
        onReceive?(sequenced)
    }

    // MARK: - State machine

    private func applyEvent(_ event: BroadcastChannelEvent) {
        let effect = stateQueue.sync { stateMachine.handle(event) }
        onStateChange?()
        switch effect {
            case .startReconnect(let attempt):
                scheduleReconnect(attempt: attempt)
            case .none:
                break
        }
    }

    private func scheduleReconnect(attempt: Int) {
        reconnectTask?.cancel()
        let delay = min(pow(2.0, Double(attempt - 1)), 8.0)
        debug("scheduling sfu reconnect attempt=\(attempt) delay=\(delay)s")

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            self.sfuClient.stop()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            do {
                self.bindSFUCallbacks()
                try await self.sfuClient.start()
                self.debug("sfu reconnected successfully attempt=\(attempt)")
                self.applyEvent(.reconnectSucceeded)
            } catch {
                self.debug("sfu reconnect failed attempt=\(attempt) error=\(error.localizedDescription)")
                self.applyEvent(.reconnectFailed)
            }
        }
    }

    // MARK: - Passthrough accessors

    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? {
        get { sfuClient.contextSecretProvider }
        set { sfuClient.contextSecretProvider = newValue }
    }

    var onBlobData: KeepTalkingTransportBlobDataHandler? {
        get { sfuClient.onBlobData }
        set { sfuClient.onBlobData = newValue }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        sfuClient.runtimeStats()
    }

    private func debug(_ message: String) {
        onLog?("[broadcast] \(message)")
    }
}
