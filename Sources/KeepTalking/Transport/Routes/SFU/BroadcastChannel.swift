import Foundation

/// Always-on broadcast channel backed by an SFU transport.
/// Wraps the underlying SFU client with explicit state machine management.
///
/// State transitions:
///   connecting → ready            (roster confirms context membership)
///   ready → reconnecting(1)       (transport degraded)
///   reconnecting(n) → ready       (reconnect succeeded)
///   reconnecting(n) → reconnecting(n+1)  (retry — never gives up)
///   any → failed                  (explicitly stopped)
final class KeepTalkingBroadcastChannel: KeepTalkingBroadcastTransportChannel, @unchecked Sendable {

    let route: KeepTalkingTransportRoute = .sfu

    // MARK: - Protocol callbacks

    var onReceive: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerJoined: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    /// Surfaced when a remote peer opens an SFU-mediated relay to us.
    /// The carrier is already wired to inbound `RELAY_DATA` deliveries;
    /// the recipient marks it ready once it's accepted the relay.
    var onRelayOpen: (@Sendable (KeepTalkingSFURelayCarrier) -> Void)?

    // MARK: - Internal state

    private var sfuClient: (any KeepTalkingTransportClient)?
    private let config: KeepTalkingConfig
    private var stateMachine = BroadcastChannelStateMachine()
    private var lifecycleGeneration: UInt64 = 0
    private var activeStartGeneration: UInt64?
    private let lifecycleOperationLock = NSLock()
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
        let snapshot = stateQueue.sync { (stateMachine.state, sfuClient) }
        guard snapshot.0 == .ready else { return snapshot.0 }
        guard let client = snapshot.1 else { return .failed }
        return client.broadcastState() == .ready ? .ready : .reconnecting(attempt: 1)
    }

    var isReady: Bool {
        state == .ready
    }

    // MARK: - Init

    init(config: KeepTalkingConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() throws -> Task<Void, Error> {
        guard
            let generation = stateQueue.sync(execute: { () -> UInt64? in
                guard sfuClient == nil, activeStartGeneration == nil else { return nil }
                lifecycleGeneration &+= 1
                activeStartGeneration = lifecycleGeneration
                return lifecycleGeneration
            })
        else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }

        return Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.start(generation: generation)
        }
    }

    private func start(generation: UInt64) async throws {
        var startedClient: (any KeepTalkingTransportClient)?
        do {
            let client = try await makeTransportClient()
            startedClient = client
            let installed = stateQueue.sync {
                guard lifecycleGeneration == generation,
                    activeStartGeneration == generation,
                    sfuClient == nil
                else { return false }
                activeStartGeneration = nil
                sfuClient = client
                return true
            }
            guard installed else {
                client.stop()
                throw CancellationError()
            }

            bindSFUCallbacks(to: client, generation: generation)
            let startTask = try prepareStart(for: client, generation: generation)
            try await startTask.waitPropagatingCancellation()
            try Task.checkCancellation()
            guard isCurrent(client, generation: generation) else {
                throw CancellationError()
            }
            guard client.broadcastState() == .ready else {
                throw KeepTalkingTransportError.allChannelsUnavailable
            }
            guard applyEvent(.channelsOpened, for: client, generation: generation) else {
                throw CancellationError()
            }
            guard isCurrent(client, generation: generation) else {
                throw CancellationError()
            }
            guard client.broadcastState() == .ready else {
                throw KeepTalkingTransportError.allChannelsUnavailable
            }
        } catch {
            if let client = startedClient {
                if isCurrent(client, generation: generation) {
                    _ = applyEvent(.transportDegraded, for: client, generation: generation)
                    removeCurrentClient(client, generation: generation)
                    _ = applyEvent(.stopped, generation: generation)
                }
                client.stop()
            } else {
                clearStartReservation(generation: generation)
                _ = applyEvent(.transportDegraded, generation: generation)
            }
            throw error
        }
    }

    func stop() {
        lifecycleOperationLock.lock()
        let stopped = stateQueue.sync {
            lifecycleGeneration &+= 1
            let result = (sfuClient, reconnectTask)
            activeStartGeneration = nil
            sfuClient = nil
            reconnectTask = nil
            _ = stateMachine.handle(.stopped)
            return result
        }
        lifecycleOperationLock.unlock()
        stopped.1?.cancel()
        stopped.0?.stop()
        onStateChange?()
    }

    // MARK: - Send

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        guard let client = readyTransportClient() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        do {
            try client.sendEnvelope(envelope)
        } catch {
            handleSendFailure(error, operation: "envelope send", client: client)
            throw error
        }
    }

    func sendBlobData(_ data: Data) throws {
        guard let client = readyTransportClient() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        do {
            try client.sendBlobData(data, targetPeerNodeID: nil)
        } catch {
            handleSendFailure(error, operation: "blob send", client: client)
            throw error
        }
    }

    func sendRealtimeData(_ data: Data) throws {
        guard let client = readyTransportClient() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        do {
            try client.sendRealtimeDataViaBroadcast(data)
        } catch {
            handleSendFailure(error, operation: "realtime send", client: client)
            throw error
        }
    }

    /// Send a raw (non-sequenced) envelope — used for presence and signaling.
    /// Failures here are not treated as transport degraded: presence is best-effort
    /// and the authoritative degraded signal comes from channel/ICE state callbacks.
    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        guard let client = readyTransportClient() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try client.sendEnvelope(envelope)
    }

    func sendLivenessProbe() {
        currentTransportClient()?.sendLivenessProbe()
    }

    // MARK: - SFU relay

    /// Opens an SFU-mediated relay to `peerPubkey` for direct-path
    /// fallback. The returned carrier is already wired to inbound
    /// `RELAY_DATA` frames; the caller wires `onMessage` / `onState`
    /// and calls `markReady()` when its side is initialized.
    func openRelay(toPeerPubkey peer: Data) -> KeepTalkingSFURelayCarrier? {
        guard let sfuJuice = readyTransportClient() as? KeepTalkingSFUJuiceClient else {
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

    private func makeTransportClient() async throws -> KeepTalkingSFUJuiceClient {
        guard let endpoint = config.sfuEndpoint else {
            throw KeepTalkingTransportError.sfuEndpointMissing
        }
        let signingKey = KeepTalkingSFUSigningKey.ephemeral()
        return KeepTalkingSFUJuiceClient(
            config: config,
            sfuHost: endpoint.host,
            sfuPort: endpoint.port,
            signingKey: signingKey,
            stopBeforeStartIsTerminal: true
        )
    }

    private func bindSFUCallbacks(
        to sfuClient: any KeepTalkingTransportClient,
        generation: UInt64
    ) {
        let clientID = ObjectIdentifier(sfuClient)
        sfuClient.onEnvelope = { [weak self] envelope in
            guard self?.isCurrent(clientID, generation: generation) == true else { return }
            self?.onReceive?(envelope)
        }
        sfuClient.onBlobData = { [weak self] data in
            guard let self, self.isCurrent(clientID, generation: generation) else { return }
            let handler = self.stateQueue.sync { self.blobDataHandlerStorage }
            handler?(data)
        }
        sfuClient.onRealtimeData = { [weak self] data in
            guard let self, self.isCurrent(clientID, generation: generation) else { return }
            let handler = self.stateQueue.sync { self.realtimeDataHandlerStorage }
            handler?(data)
        }
        sfuClient.onRawMessage = nil
        sfuClient.onPeerConnect = nil
        if let sfuJuice = sfuClient as? KeepTalkingSFUJuiceClient {
            sfuJuice.presenceForwarder = { [weak self] event in
                guard let self,
                    self.isCurrent(clientID, generation: generation),
                    case .joined(let context, _) = event,
                    context == self.config.contextID
                else { return }
                self.onPeerJoined?()
            }
            sfuJuice.onTransportDegraded = { [weak self, weak sfuJuice] reason in
                guard let sfuJuice else { return }
                self?.debug("sfu transport degraded reason=\(reason)")
                self?.applyEvent(
                    .transportDegraded,
                    for: sfuJuice,
                    generation: generation
                )
            }
            sfuJuice.onRelayOpen = { [weak self] relayID, peer, _ in
                guard let self, self.isCurrent(clientID, generation: generation) else { return }
                let carrier = self.makeCarrier(
                    sfuJuice: sfuJuice,
                    relayID: relayID,
                    remotePeer: peer
                )
                self.onRelayOpen?(carrier)
            }
            sfuJuice.onRelayData = { [weak self] relayID, payload in
                guard let self, self.isCurrent(clientID, generation: generation) else { return }
                let carrier = self.stateQueue.sync { self.relayCarriers[relayID] }
                carrier?.deliverInbound(payload)
            }
            sfuJuice.onRelayClose = { [weak self] relayID, reason in
                guard let self, self.isCurrent(clientID, generation: generation) else { return }
                let carrier = self.stateQueue.sync { () -> KeepTalkingSFURelayCarrier? in
                    let c = self.relayCarriers[relayID]
                    self.relayCarriers.removeValue(forKey: relayID)
                    return c
                }
                carrier?.remoteClosed(reason: reason)
            }
        }
        sfuClient.onLog = onLog
        sfuClient.contextSecretProvider = stateQueue.sync { contextSecretProviderStorage }
    }

    // MARK: - State machine

    @discardableResult
    private func applyEvent(
        _ event: BroadcastChannelEvent,
        for expectedClient: (any KeepTalkingTransportClient)? = nil,
        generation expectedGeneration: UInt64? = nil
    ) -> Bool {
        let transition = stateQueue.sync {
            () -> (BroadcastChannelEffect, (any KeepTalkingTransportClient)?, UInt64)? in
            if let expectedGeneration, lifecycleGeneration != expectedGeneration { return nil }
            if let expectedClient {
                guard let current = sfuClient, current === expectedClient else { return nil }
            }
            let effect = stateMachine.handle(event)
            return (effect, sfuClient, lifecycleGeneration)
        }
        guard let transition else { return false }
        onStateChange?()
        switch transition.0 {
            case .startReconnect(let attempt):
                if let client = transition.1 {
                    scheduleReconnect(
                        attempt: attempt,
                        client: client,
                        generation: transition.2
                    )
                }
            case .none:
                break
        }
        return true
    }

    private func scheduleReconnect(
        attempt: Int,
        client: any KeepTalkingTransportClient,
        generation: UInt64
    ) {
        let delay = min(pow(2.0, Double(attempt - 1)), 8.0)
        debug("scheduling sfu reconnect attempt=\(attempt) delay=\(delay)s")

        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.isCurrent(client, generation: generation) else {
                return
            }

            client.stop()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.isCurrent(client, generation: generation) else {
                return
            }

            do {
                self.bindSFUCallbacks(to: client, generation: generation)
                let startTask = try self.prepareStart(
                    for: client,
                    generation: generation
                )
                try await startTask.waitPropagatingCancellation()
                guard !Task.isCancelled,
                    self.isCurrent(client, generation: generation)
                else {
                    client.stop()
                    return
                }
                guard client.broadcastState() == .ready else {
                    client.stop()
                    self.applyEvent(.reconnectFailed, for: client, generation: generation)
                    return
                }
                self.debug("sfu reconnected successfully attempt=\(attempt)")
                guard
                    self.applyEvent(
                        .reconnectSucceeded,
                        for: client,
                        generation: generation
                    )
                else {
                    client.stop()
                    return
                }
                guard self.isCurrent(client, generation: generation) else {
                    client.stop()
                    return
                }
                guard client.broadcastState() == .ready else {
                    client.stop()
                    _ = self.applyEvent(
                        .transportDegraded,
                        for: client,
                        generation: generation
                    )
                    return
                }
            } catch {
                guard !Task.isCancelled, self.isCurrent(client, generation: generation) else {
                    client.stop()
                    return
                }
                self.debug("sfu reconnect failed attempt=\(attempt) error=\(error.localizedDescription)")
                self.applyEvent(.reconnectFailed, for: client, generation: generation)
            }
        }
        let previous = stateQueue.sync {
            () -> (retained: Bool, previous: Task<Void, Never>?) in
            guard lifecycleGeneration == generation,
                let current = sfuClient,
                current === client,
                stateMachine.state == .reconnecting(attempt: attempt)
            else { return (false, nil) }
            let previous = reconnectTask
            reconnectTask = task
            return (true, previous)
        }
        previous.previous?.cancel()
        if !previous.retained { task.cancel() }
    }

    private func prepareStart(
        for client: any KeepTalkingTransportClient,
        generation: UInt64
    ) throws -> Task<Void, Error> {
        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }
        guard !Task.isCancelled,
            isCurrent(client, generation: generation)
        else { throw CancellationError() }
        return try client.start()
    }

    private func clearStartReservation(generation: UInt64) {
        stateQueue.sync {
            guard lifecycleGeneration == generation,
                activeStartGeneration == generation
            else { return }
            activeStartGeneration = nil
        }
    }

    private func isCurrent(
        _ client: any KeepTalkingTransportClient,
        generation: UInt64? = nil
    ) -> Bool {
        stateQueue.sync {
            if let generation, lifecycleGeneration != generation { return false }
            guard let current = sfuClient else { return false }
            return current === client
        }
    }

    private func isCurrent(_ clientID: ObjectIdentifier, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard lifecycleGeneration == generation, let current = sfuClient else { return false }
            return ObjectIdentifier(current) == clientID
        }
    }

    private func removeCurrentClient(
        _ client: any KeepTalkingTransportClient,
        generation: UInt64
    ) {
        let reconnect = stateQueue.sync {
            guard lifecycleGeneration == generation,
                let current = sfuClient,
                current === client
            else { return nil as Task<Void, Never>? }
            let reconnect = reconnectTask
            reconnectTask = nil
            sfuClient = nil
            return reconnect
        }
        reconnect?.cancel()
    }

    private func currentTransportClient() -> (any KeepTalkingTransportClient)? {
        stateQueue.sync { sfuClient }
    }

    private func readyTransportClient() -> (any KeepTalkingTransportClient)? {
        let client = stateQueue.sync {
            stateMachine.state == .ready ? sfuClient : nil
        }
        guard let client, client.broadcastState() == .ready else { return nil }
        return client
    }

    // MARK: - Passthrough accessors

    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? {
        get { stateQueue.sync { contextSecretProviderStorage } }
        set {
            stateQueue.sync { contextSecretProviderStorage = newValue }
            currentTransportClient()?.contextSecretProvider = newValue
        }
    }

    var onBlobData: KeepTalkingTransportBlobDataHandler? {
        get { stateQueue.sync { blobDataHandlerStorage } }
        set { stateQueue.sync { blobDataHandlerStorage = newValue } }
    }

    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler? {
        get { stateQueue.sync { realtimeDataHandlerStorage } }
        set { stateQueue.sync { realtimeDataHandlerStorage = newValue } }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        currentTransportClient()?.runtimeStats()
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

    private func handleSendFailure(
        _ error: Error,
        operation: String,
        client: any KeepTalkingTransportClient
    ) {
        debug("\(operation) failed error=\(error.localizedDescription)")
        applyEvent(.transportDegraded, for: client)
    }

    private func debug(_ message: String) {
        onLog?("[broadcast] \(message)")
    }
}
