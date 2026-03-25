import FluentKit
import Foundation

// MARK: - Route State Machine

/// Clean state machine for the hybrid transport's route selection.
///
/// States:
///   .sfu            — SFU is the active transport (default).
///   .p2pTrial       — A P2P handshake is in progress; SFU is still active.
///   .p2p(client)    — P2P is the active transport; SFU is warm standby.
///
/// Transitions:
///   .sfu            → .p2pTrial        (beginTrial)
///   .p2pTrial       → .p2p(client)     (trialSucceeded)
///   .p2pTrial       → .sfu             (trialFailed / trialCancelled)
///   .p2p(client)    → .sfu             (p2pDegraded / peerOffline)
///   .p2p(client)    → .p2pTrial        (requestRetrial — forced)
///
private enum HybridRouteState {
    case sfu
    case p2pTrial
    case p2p(KeepTalkingP2PRTCClient)

    var route: KeepTalkingTransportRoute {
        switch self {
            case .sfu, .p2pTrial: return .sfu
            case .p2p: return .p2p
        }
    }

    var isP2P: Bool {
        if case .p2p = self { return true }
        return false
    }

    var isTrialRunning: Bool {
        if case .p2pTrial = self { return true }
        return false
    }

    var p2pClient: KeepTalkingP2PRTCClient? {
        if case .p2p(let client) = self { return client }
        return nil
    }
}

// MARK: - Hybrid RTC Client

final class KeepTalkingHybridRTCClient: KeepTalkingTransportClient,
    @unchecked Sendable
{
    private static let heartbeatIntervalSeconds: TimeInterval = 13
    private static let presenceEchoCooldownSeconds: TimeInterval = 1
    private static let retiredP2PRetentionSeconds: TimeInterval = 5
    /// How many missed heartbeat waves before we consider the P2P peer offline.
    private static let peerOfflineWavesThreshold = 2

    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let localStore: KeepTalkingLocalStore
    private let livenessState: KeepTalkingContextLivenessState
    private let sfuClient: KeepTalkingRTCClient

    private let stateQueue = DispatchQueue(label: "KeepTalking.hybrid.state")
    private var routeState: HybridRouteState = .sfu
    private var currentP2PClient: KeepTalkingP2PRTCClient?
    private var p2pUpgradeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var discoveredPeers = Set<UUID>()
    private var retiredP2PClients: [ObjectIdentifier: KeepTalkingP2PRTCClient] = [:]
    /// Tracks consecutive heartbeat waves where the P2P peer was not confirmed.
    private var peerMissedWaves = 0
    private var sfuReconnectTask: Task<Void, Never>?

    init(
        config: KeepTalkingConfig,
        localStore: any KeepTalkingLocalStore,
        livenessState: KeepTalkingContextLivenessState
    ) {
        self.config = config
        self.localStore = localStore
        self.livenessState = livenessState
        sfuClient = KeepTalkingRTCClient(config: config)
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [hybrid] \(message)")
    }

    // MARK: - Lifecycle

    func start() async throws {
        stateQueue.sync {
            discoveredPeers.removeAll()
            peerMissedWaves = 0
        }
        livenessState.reset()
        bindSFUCallbacks()
        try await sfuClient.start()
        transition(to: .sfu)
        rememberPeer(config.node)
        sendPresence(advancingHeartbeat: true)
        startHeartbeatLoop()
        debug("sfu route selected")
        beginP2PTrial(trigger: "startup")
    }

    func stop() {
        p2pUpgradeTask?.cancel()
        p2pUpgradeTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        sfuReconnectTask?.cancel()
        sfuReconnectTask = nil
        livenessState.reset()
        stateQueue.sync {
            retiredP2PClients.removeAll()
            peerMissedWaves = 0
        }
        teardownP2PClient()
        transition(to: .sfu)
        sfuClient.stop()
    }

    // MARK: - Transport protocol

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        let state = stateQueue.sync { routeState }
        if let p2p = state.p2pClient {
            guard p2p.isReady() else {
                debug(
                    "envelope skipping p2p: channels not all open, falling back to sfu"
                )
                try sfuClient.sendEnvelope(envelope)
                return
            }
            do {
                try p2p.sendEnvelope(envelope)
                return
            } catch {
                debug(
                    "p2p send failed; falling back to sfu error=\(error.localizedDescription)"
                )
                transition(to: .sfu)
            }
        }
        try sfuClient.sendEnvelope(envelope)
    }

    func sendBlobData(
        _ data: Data,
        via route: KeepTalkingTransportRoute?
    ) throws {
        let state = stateQueue.sync { routeState }
        let selectedRoute = route ?? state.route

        if selectedRoute == .p2p, let p2p = state.p2pClient {
            guard p2p.isReady() else {
                debug(
                    "blob skipping p2p: channels not all open, falling back to sfu bytes=\(data.count)"
                )
                try sfuClient.sendBlobData(data, via: .sfu)
                return
            }
            do {
                try p2p.sendBlobData(data, via: .p2p)
                return
            } catch {
                debug(
                    "p2p blob send failed; falling back to sfu error=\(error.localizedDescription) bytes=\(data.count)"
                )
                transition(to: .sfu)
            }
        }

        if state.isTrialRunning {
            debug(
                "blob routed via sfu during p2p trial bytes=\(data.count)"
            )
        }
        try sfuClient.sendBlobData(data, via: .sfu)
    }

    func currentRoute() -> KeepTalkingTransportRoute {
        stateQueue.sync { routeState.route }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let state = stateQueue.sync { routeState }
        let transport: KeepTalkingTransportClient =
            state.p2pClient ?? sfuClient
        let stats = transport.runtimeStats()
        return KeepTalkingRuntimeStats(
            sent: stats.sent,
            received: stats.received,
            outboundLabel: stats.outboundLabel,
            outboundState: stats.outboundState,
            inboundLabel: stats.inboundLabel,
            inboundState: stats.inboundState,
            retainedChannels: stats.retainedChannels,
            route: state.route.rawValue
        )
    }

    func requestP2PTrial() {
        beginP2PTrial(trigger: "manual", force: true)
    }

    func preferReliableRoute(reason: String) {
        transition(to: .sfu, reason: reason)
    }

    // MARK: - State machine

    private func transition(
        to target: HybridRouteState,
        reason: String? = nil
    ) {
        let previous = stateQueue.sync { routeState }
        let changed: Bool
        switch (previous, target) {
            case (.sfu, .sfu):
                changed = false
            case (.p2p, .sfu), (.p2pTrial, .sfu):
                stateQueue.sync { routeState = .sfu }
                changed = true
            case (_, .p2pTrial):
                stateQueue.sync { routeState = .p2pTrial }
                changed = true
            case (_, .p2p(let client)):
                stateQueue.sync {
                    routeState = .p2p(client)
                    peerMissedWaves = 0
                }
                changed = true
        }
        if changed {
            let label = reason.map { " reason=\($0)" } ?? ""
            debug("route → \(target.route.rawValue)\(label)")
        }
    }

    // MARK: - P2P trial

    private func beginP2PTrial(trigger: String, force: Bool = false) {
        guard config.p2pAttemptTimeoutSeconds > 0 else {
            debug(
                "p2p trial skipped trigger=\(trigger) timeout=\(config.p2pAttemptTimeoutSeconds)"
            )
            return
        }

        let state = stateQueue.sync { routeState }
        guard force || (!state.isP2P && !state.isTrialRunning) else {
            debug(
                "p2p trial skipped trigger=\(trigger) reason=\(state.isP2P ? "already-on-p2p" : "trial-in-progress")"
            )
            return
        }

        if state.isP2P {
            transition(to: .sfu, reason: "forcing p2p retrial trigger=\(trigger)")
        }

        p2pUpgradeTask?.cancel()
        p2pUpgradeTask = nil
        teardownP2PClient()

        let p2pClient = makeP2PClient()
        self.currentP2PClient = p2pClient
        bindP2PCallbacks(p2pClient)
        transition(to: .p2pTrial)
        debug(
            "starting p2p trial trigger=\(trigger) timeout=\(config.p2pAttemptTimeoutSeconds)"
        )

        p2pUpgradeTask = Task { [weak self, p2pClient] in
            guard let self else { return }
            defer {
                if self.stateQueue.sync(execute: { self.routeState }).isTrialRunning {
                    self.transition(to: .sfu, reason: "trial cleanup")
                }
                self.p2pUpgradeTask = nil
            }

            do {
                try await p2pClient.start()
                guard self.isCurrentP2PClient(p2pClient) else {
                    p2pClient.stop()
                    return
                }

                let deadline = Date().addingTimeInterval(
                    TimeInterval(self.config.p2pAttemptTimeoutSeconds)
                )
                while Date() < deadline {
                    guard self.isCurrentP2PClient(p2pClient) else {
                        throw CancellationError()
                    }
                    if p2pClient.isReady() { break }
                    try await Task.sleep(for: .milliseconds(150))
                }

                guard p2pClient.isReady() else {
                    throw P2PError.handshakeTimeout
                }
                self.transition(to: .p2p(p2pClient))
                self.debug("p2p route selected; keeping sfu as warm fallback")
            } catch {
                if self.isCurrentP2PClient(p2pClient) {
                    self.teardownP2PClient()
                } else {
                    p2pClient.stop()
                }
                self.debug(
                    "p2p trial failed trigger=\(trigger) error=\(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - P2P client management

    private func makeP2PClient() -> KeepTalkingP2PRTCClient {
        KeepTalkingP2PRTCClient(
            config: config,
            localNodeID: config.node,
            sendSignal: { [weak self] to, data in
                self?.sendSignal(to: to, data: data)
            },
            announcePresence: { [weak self] in
                self?.sendPresence()
            },
            peersSnapshot: { [weak self] in
                self?.peersSnapshot() ?? []
            }
        )
    }

    private func isCurrentP2PClient(_ candidate: KeepTalkingP2PRTCClient)
        -> Bool
    {
        stateQueue.sync { currentP2PClient === candidate }
    }

    private func teardownP2PClient() {
        let client = stateQueue.sync { () -> KeepTalkingP2PRTCClient? in
            let current = currentP2PClient
            currentP2PClient = nil
            return current
        }
        guard let client else { return }
        client.onEnvelope = nil
        client.onBlobData = nil
        client.onRawMessage = nil
        client.onPeerConnect = nil
        client.onTransportDegraded = nil
        client.onLog = nil
        client.contextSecretProvider = nil
        client.stop()
        retainRetiredP2PClient(client)
    }

    /// Keeps a strong reference to a retired P2P client for a short window
    /// to prevent WebRTC bad-access crashes during teardown.
    private func retainRetiredP2PClient(_ client: KeepTalkingP2PRTCClient) {
        let key = ObjectIdentifier(client)
        stateQueue.sync {
            retiredP2PClients[key] = client
        }
        Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.retiredP2PRetentionSeconds)
            )
            guard let self else { return }
            _ = self.stateQueue.sync {
                self.retiredP2PClients.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Callback binding

    private func bindSFUCallbacks() {
        sfuClient.onEnvelope = { [weak self] envelope in
            Task {
                guard let self else { return }
                do {
                    try await self.handleSFUEnvelope(envelope)
                } catch {
                    self.debug(
                        "failed handling sfu envelope error=\(error.localizedDescription)"
                    )
                }
            }
        }
        sfuClient.onBlobData = { [weak self] data in
            self?.onBlobData?(data)
        }
        sfuClient.onRawMessage = { [weak self] raw in
            self?.onRawMessage?(raw)
        }
        sfuClient.onPeerConnect = nil
        sfuClient.onTransportDegraded = { [weak self] reason in
            self?.handleSFUDegraded(reason: reason)
        }
        sfuClient.onLog = onLog
        sfuClient.contextSecretProvider = contextSecretProvider
    }

    private func handleSFUDegraded(reason: String) {
        debug("sfu transport degraded reason=\(reason)")
        scheduleSFUReconnect(reason: reason)
    }

    private func scheduleSFUReconnect(reason: String) {
        guard sfuReconnectTask == nil else {
            debug("sfu reconnect already scheduled")
            return
        }
        debug("scheduling sfu reconnect reason=\(reason)")

        sfuReconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sfuReconnectTask = nil }

            // Brief delay so in-flight sends finish before we tear down.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            self.sfuClient.stop()
            self.debug("sfu stopped for reconnect")

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            do {
                self.bindSFUCallbacks()
                try await self.sfuClient.start()
                self.debug("sfu reconnected successfully")
                self.sendPresence(advancingHeartbeat: false)
            } catch {
                self.debug(
                    "sfu reconnect failed error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func bindP2PCallbacks(_ p2pClient: KeepTalkingP2PRTCClient) {
        p2pClient.onEnvelope = { [weak self, weak p2pClient] envelope in
            guard let self, let p2pClient,
                self.isCurrentP2PClient(p2pClient)
            else { return }
            self.onEnvelope?(envelope)
        }
        p2pClient.onBlobData = { [weak self, weak p2pClient] data in
            guard let self, let p2pClient,
                self.isCurrentP2PClient(p2pClient)
            else { return }
            self.onBlobData?(data)
        }
        p2pClient.onRawMessage = { [weak self, weak p2pClient] raw in
            guard let self, let p2pClient,
                self.isCurrentP2PClient(p2pClient)
            else { return }
            self.onRawMessage?(raw)
        }
        p2pClient.onPeerConnect = { [weak self, weak p2pClient] nodeID in
            guard let self, let p2pClient,
                self.isCurrentP2PClient(p2pClient)
            else { return }
            self.reportPeerConnected(nodeID, source: "p2p")
        }
        p2pClient.onTransportDegraded = {
            [weak self, weak p2pClient] reason in
            guard let self, let p2pClient,
                self.isCurrentP2PClient(p2pClient)
            else { return }
            self.transition(to: .sfu, reason: reason)
            self.teardownP2PClient()
        }
        p2pClient.onLog = onLog
        p2pClient.contextSecretProvider = contextSecretProvider
    }

    // MARK: - Heartbeat & liveness

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.heartbeatIntervalSeconds)
                )
                if Task.isCancelled { break }
                self.sendPresence(advancingHeartbeat: true)
                self.checkP2PPeerLiveness()
            }
        }
    }

    /// After each heartbeat wave, check if the P2P peer is still confirmed
    /// in the liveness state.  If they've missed enough waves, fall back to SFU.
    private func checkP2PPeerLiveness() {
        let state = stateQueue.sync { routeState }
        guard let p2pClient = state.p2pClient else {
            stateQueue.sync { peerMissedWaves = 0 }
            return
        }

        // The P2P peer is the remote node the P2P client connected to.
        let stats = p2pClient.runtimeStats()
        // Check if ANY discovered peer (excluding self) is still confirmed online.
        let onlineNodes = livenessState.onlineNodeIDs()
        let remotePeersOnline = onlineNodes.subtracting([config.node])

        if remotePeersOnline.isEmpty {
            let missed = stateQueue.sync { () -> Int in
                peerMissedWaves += 1
                return peerMissedWaves
            }
            debug(
                "p2p peer liveness check: no peers online missedWaves=\(missed)/\(Self.peerOfflineWavesThreshold) stats=\(stats.route ?? "?")"
            )
            if missed >= Self.peerOfflineWavesThreshold {
                debug("p2p peer offline; falling back to sfu")
                transition(to: .sfu, reason: "peer offline")
                teardownP2PClient()
            }
        } else {
            stateQueue.sync { peerMissedWaves = 0 }
        }
    }

    // MARK: - Presence & signaling

    private func sendPresence(advancingHeartbeat: Bool = false) {
        if advancingHeartbeat {
            _ = livenessState.beginHeartbeatWave(
                minimumInterval: Self.heartbeatIntervalSeconds
            )
        }
        do {
            try sfuClient.sendEnvelope(
                .p2pPresence(KeepTalkingP2PPresencePayload(node: config.node))
            )
        } catch {
            debug("send presence failed error=\(error.localizedDescription)")
        }
    }

    private func sendSignal(to: UUID, data: KeepTalkingP2PSignalData) {
        let payload = KeepTalkingP2PSignalPayload(
            from: config.node,
            to: to,
            data: data
        )
        do {
            try sfuClient.sendEnvelope(.p2pSignal(payload))
        } catch {
            debug(
                "send signaling envelope failed error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Peer tracking

    private func rememberPeer(_ node: UUID) {
        _ = stateQueue.sync {
            discoveredPeers.insert(node)
        }
    }

    private func reportPeerConnected(_ nodeID: UUID, source: String) {
        guard nodeID != config.node else { return }
        rememberPeer(nodeID)

        let livenessSource: KeepTalkingContextLivenessState.Source?
        switch source {
            case "presence": livenessSource = .presence
            case "p2p": livenessSource = .p2p
            default: livenessSource = nil
        }

        guard let livenessSource else { return }
        let shouldNotify = livenessState.shouldNotifyPeerConnect(
            nodeID,
            source: livenessSource
        )
        guard shouldNotify else { return }
        debug(
            "peer reachable source=\(source) node=\(nodeID.uuidString.lowercased())"
        )
        onPeerConnect?(nodeID)
    }

    private func peersSnapshot() -> [UUID] {
        stateQueue.sync { Array(discoveredPeers) }
    }

    // MARK: - SFU envelope handling

    private func handleSFUEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
            case .p2pPresence(let presence):
                try await handlePresence(presence)
            case .p2pSignal(let signalPayload):
                handleP2PSignal(signalPayload)
            default:
                onEnvelope?(envelope)
        }
    }

    private func handlePresence(_ presence: KeepTalkingP2PPresencePayload)
        async throws
    {
        let relations =
            try await KeepTalkingNodeRelation
            .query(on: localStore.database)
            .filter(\.$from.$id == config.node)
            .filter(\.$to.$id == presence.node)
            .all()

        guard
            let currentContext = try await KeepTalkingContext.query(
                on: localStore.database
            ).filter(\.$id == config.contextID).first()
        else {
            throw KeepTalkingClientError.missingNode
        }

        let shouldConnect = relations.contains { relation in
            switch relation.relationship {
                case .pending, .owner, .trustedInAllContext:
                    return true
                case .trusted(_):
                    return relation.allows(context: currentContext)
            }
        }

        debug(
            "presence node=\(presence.node.uuidString.lowercased()) connect=\(shouldConnect)"
        )

        if presence.node == config.node {
            debug(
                "received presence for local node id=\(config.node.uuidString.lowercased()); check that each client uses a unique --node UUID"
            )
        } else if shouldConnect {
            beginP2PTrial(
                trigger:
                    "presence:\(presence.node.uuidString.lowercased())"
            )
        } else {
            debug(
                "presence ignored for p2p trial: relation policy does not allow node=\(presence.node.uuidString.lowercased())"
            )
        }

        rememberPeer(presence.node)
        let observation = livenessState.observePresence(
            from: presence.node,
            echoCooldown: Self.presenceEchoCooldownSeconds
        )
        if observation.shouldEcho {
            sendPresence()
        }
        if observation.confirmedCurrentWave {
            reportPeerConnected(presence.node, source: "presence")
        }
        currentP2PClient?.receivePresence(from: presence.node)
        onEnvelope?(.p2pPresence(presence))
    }

    private func handleP2PSignal(_ signalPayload: KeepTalkingP2PSignalPayload)
    {
        if signalPayload.from == config.node {
            debug(
                "received signaling envelope from local node id=\(config.node.uuidString.lowercased()); check duplicate --node UUID usage"
            )
        }
        rememberPeer(signalPayload.from)
        currentP2PClient?.receiveSignal(signalPayload)
        onEnvelope?(.p2pSignal(signalPayload))
    }
}
