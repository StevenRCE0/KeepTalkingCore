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
    /// Surfaced when a remote peer opens an SFU-mediated relay to us.
    /// The carrier is already wired to inbound `RELAY_DATA` deliveries;
    /// the recipient marks it ready once it's accepted the relay.
    var onRelayOpen: (@Sendable (KeepTalkingSFURelayCarrier) -> Void)?

    // MARK: - Internal state

    private var sfuClient: (any KeepTalkingTransportClient)?
    private let config: KeepTalkingConfig
    private var stateMachine = BroadcastChannelStateMachine()
    private let stateQueue = DispatchQueue(label: "kt.broadcast.state")
    private var reconnectTask: Task<Void, Never>?
    private var contextSecretProviderStorage: KeepTalkingTransportContextSecretProvider?
    private var blobDataHandlerStorage: KeepTalkingTransportBlobDataHandler?
    private var realtimeDataHandlerStorage: KeepTalkingTransportRealtimeDataHandler?
    /// Active relay carriers keyed by `relayID`. Both opener- and
    /// responder-side carriers live here so inbound `RELAY_DATA` /
    /// `RELAY_CLOSE` frames can be routed back to the right carrier.
    private var relayCarriers: [Data: KeepTalkingSFURelayCarrier] = [:]

    var state: BroadcastChannelState {
        stateQueue.sync { stateMachine.state }
    }

    var isReady: Bool {
        state == .ready && sfuClient != nil
    }

    // MARK: - Init

    init(config: KeepTalkingConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() async throws {
        sfuClient = try await makeTransportClient()
        bindSFUCallbacks()
        try await sfuClient?.start()
        applyEvent(.channelsOpened)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sfuClient?.stop()
        sfuClient = nil
        applyEvent(.stopped)
    }

    // MARK: - Send

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        do {
            guard let sfuClient else { throw KeepTalkingTransportError.allChannelsUnavailable }
            try sfuClient.sendEnvelope(sequenced.envelope)
        } catch {
            handleSendFailure(error, operation: "sequenced send")
            throw error
        }
    }

    func sendBlobData(_ data: Data) throws {
        do {
            guard let sfuClient else { throw KeepTalkingTransportError.allChannelsUnavailable }
            try sfuClient.sendBlobData(data, targetPeerNodeID: nil)
        } catch {
            handleSendFailure(error, operation: "blob send")
            throw error
        }
    }

    func sendRealtimeData(_ data: Data) throws {
        do {
            guard let sfuClient else { throw KeepTalkingTransportError.allChannelsUnavailable }
            try sfuClient.sendRealtimeDataViaBroadcast(data)
        } catch {
            handleSendFailure(error, operation: "realtime send")
            throw error
        }
    }

    /// Send a raw (non-sequenced) envelope — used for presence and signaling.
    /// Failures here are not treated as transport degraded: presence is best-effort
    /// and the authoritative degraded signal comes from channel/ICE state callbacks.
    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        guard let sfuClient else { throw KeepTalkingTransportError.allChannelsUnavailable }
        try sfuClient.sendEnvelope(envelope)
    }

    // MARK: - SFU relay

    /// Opens an SFU-mediated relay to `peerPubkey` for direct-path
    /// fallback. The returned carrier is already wired to inbound
    /// `RELAY_DATA` frames; the caller wires `onMessage` / `onState`
    /// and calls `markReady()` when its side is initialized.
    func openRelay(toPeerPubkey peer: Data) -> KeepTalkingSFURelayCarrier? {
        guard let sfuJuice = sfuClient as? KeepTalkingSFUJuiceClient else {
            return nil
        }
        let relayID = sfuJuice.openRelay(to: peer)
        let carrier = makeCarrier(sfuJuice: sfuJuice, relayID: relayID, remotePeer: peer)
        carrier.markReady()
        return carrier
    }

    private func makeCarrier(
        sfuJuice: KeepTalkingSFUJuiceClient,
        relayID: Data,
        remotePeer: Data
    ) -> KeepTalkingSFURelayCarrier {
        let carrier = KeepTalkingSFURelayCarrier(
            relayID: relayID,
            remotePeerPubkey: remotePeer,
            send: { [weak sfuJuice] rid, payload in
                sfuJuice?.sendRelayData(payload, on: rid)
            },
            close: { [weak sfuJuice] rid, reason in
                sfuJuice?.closeRelay(rid, reason: reason)
            }
        )
        stateQueue.sync { relayCarriers[relayID] = carrier }
        return carrier
    }

    // MARK: - SFU callback binding

    private func makeTransportClient() async throws -> any KeepTalkingTransportClient {
        guard let endpoint = config.sfuEndpoint else {
            throw KeepTalkingTransportError.sfuEndpointMissing
        }
        let signingKey = try await KeepTalkingSFUSigningKey.loadOrCreate(
            nodeID: config.node,
            store: keychainStore()
        )
        return KeepTalkingSFUJuiceClient(
            config: config,
            sfuHost: endpoint.host,
            sfuPort: endpoint.port,
            signingKey: signingKey
        )
    }

    private func keychainStore() -> any KeepTalkingKeychainStore {
        #if canImport(Security)
        KeepTalkingSecItemKeychainStore.shared
        #else
        KeepTalkingInMemoryKeychainStore()
        #endif
    }

    private func bindSFUCallbacks() {
        guard let sfuClient else { return }
        sfuClient.onEnvelope = { [weak self] envelope in
            self?.handleSFUEnvelope(envelope)
        }
        sfuClient.onBlobData = nil
        sfuClient.onRealtimeData = nil
        sfuClient.onRawMessage = nil
        sfuClient.onPeerConnect = nil
        if let sfuJuice = sfuClient as? KeepTalkingSFUJuiceClient {
            sfuJuice.onTransportDegraded = { [weak self] reason in
                self?.debug("sfu transport degraded reason=\(reason)")
                self?.applyEvent(.transportDegraded)
            }
            sfuJuice.onRelayOpen = { [weak self] relayID, peer, _ in
                guard let self else { return }
                let carrier = self.makeCarrier(
                    sfuJuice: sfuJuice,
                    relayID: relayID,
                    remotePeer: peer
                )
                self.onRelayOpen?(carrier)
            }
            sfuJuice.onRelayData = { [weak self] relayID, payload in
                guard let self else { return }
                let carrier = self.stateQueue.sync { self.relayCarriers[relayID] }
                carrier?.deliverInbound(payload)
            }
            sfuJuice.onRelayClose = { [weak self] relayID, reason in
                guard let self else { return }
                let carrier = self.stateQueue.sync { () -> KeepTalkingSFURelayCarrier? in
                    let c = self.relayCarriers[relayID]
                    self.relayCarriers.removeValue(forKey: relayID)
                    return c
                }
                carrier?.remoteClosed(reason: reason)
            }
        }
        sfuClient.onLog = onLog
        sfuClient.contextSecretProvider = contextSecretProviderStorage
        sfuClient.onBlobData = blobDataHandlerStorage
        sfuClient.onRealtimeData = realtimeDataHandlerStorage
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

            self.sfuClient?.stop()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            do {
                self.bindSFUCallbacks()
                try await self.sfuClient?.start()
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
        get { contextSecretProviderStorage }
        set {
            contextSecretProviderStorage = newValue
            sfuClient?.contextSecretProvider = newValue
        }
    }

    var onBlobData: KeepTalkingTransportBlobDataHandler? {
        get { blobDataHandlerStorage }
        set {
            blobDataHandlerStorage = newValue
            sfuClient?.onBlobData = newValue
        }
    }

    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler? {
        get { realtimeDataHandlerStorage }
        set {
            realtimeDataHandlerStorage = newValue
            sfuClient?.onRealtimeData = newValue
        }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        sfuClient?.runtimeStats()
            ?? KeepTalkingRuntimeStats(
                sent: 0,
                received: 0,
                outboundLabel: "sfu",
                outboundState: 0,
                inboundLabel: "sfu",
                inboundState: 0,
                retainedChannels: 0,
                route: route.rawValue
            )
    }

    private func handleSendFailure(_ error: Error, operation: String) {
        debug("\(operation) failed error=\(error.localizedDescription)")
        applyEvent(.transportDegraded)
    }

    private func debug(_ message: String) {
        onLog?("[broadcast] \(message)")
    }
}
