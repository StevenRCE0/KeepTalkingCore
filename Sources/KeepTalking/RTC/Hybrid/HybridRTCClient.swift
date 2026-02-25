import FluentKit
import Foundation

final class KeepTalkingHybridRTCClient: KeepTalkingTransportClient,
    @unchecked Sendable
{
    var onMessage: (@Sendable (KeepTalkingContextMessage) -> Void)? {
        didSet { bindCallbacks() }
    }
    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)? {
        didSet { bindCallbacks() }
    }
    var onRawMessage: (@Sendable (String) -> Void)? {
        didSet { bindCallbacks() }
    }
    var onPeerConnect: (@Sendable (UUID) -> Void)? {
        didSet { bindCallbacks() }
    }
    var onLog: (@Sendable (String) -> Void)? {
        didSet { bindCallbacks() }
    }

    private let config: KeepTalkingConfig
    private let localStore: KeepTalkingLocalStore
    private let sfuClient: KeepTalkingRTCClient
    private var p2pClient: KeepTalkingP2PRTCClient?
    private var p2pUpgradeTask: Task<Void, Never>?

    private let stateQueue = DispatchQueue(label: "KeepTalking.hybrid.state")
    private var discoveredPeers = Set<UUID>()
    private var notifiedConnectedPeers = Set<UUID>()
    private var activeTransport: KeepTalkingTransportClient
    private var activeRoute = "sfu"
    private var isP2PTrialRunning = false

    init(config: KeepTalkingConfig, localStore: any KeepTalkingLocalStore) {
        self.config = config
        self.localStore = localStore

        sfuClient = KeepTalkingRTCClient(config: config)
        activeTransport = sfuClient

        bindCallbacks()
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [hybrid] \(message)")
    }

    func logAsHybridClient(_ message: String) {
        debug(message)
    }

    func start() async throws {
        stateQueue.sync {
            discoveredPeers.removeAll()
            notifiedConnectedPeers.removeAll()
        }
        try await sfuClient.start()
        setActiveTransport(sfuClient, route: "sfu")
        rememberPeer(config.node)
        sendPresence()
        debug("sfu route selected")
        beginP2PTrial(trigger: "startup")
    }

    func stop() {
        p2pUpgradeTask?.cancel()
        p2pUpgradeTask = nil
        stateQueue.sync {
            isP2PTrialRunning = false
            notifiedConnectedPeers.removeAll()
        }
        p2pClient?.stop()
        sfuClient.stop()
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        do {
            try stateQueue.sync {
                try activeTransport.sendEnvelope(envelope)
            }
        } catch {
            let shouldFallback = stateQueue.sync { activeRoute == "p2p" }
            guard shouldFallback else {
                throw error
            }
            debug("p2p send failed; falling back to sfu error=\(error.localizedDescription)")
            fallbackToSFU(reason: "p2p send failure")
            try sfuClient.sendEnvelope(envelope)
        }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        stateQueue.sync {
            let stats = activeTransport.runtimeStats()
            return KeepTalkingRuntimeStats(
                sent: stats.sent,
                received: stats.received,
                outboundLabel: stats.outboundLabel,
                outboundState: stats.outboundState,
                inboundLabel: stats.inboundLabel,
                inboundState: stats.inboundState,
                retainedChannels: stats.retainedChannels,
                route: activeRoute
            )
        }
    }

    func requestP2PTrial() {
        beginP2PTrial(trigger: "manual", allowWhileOnP2P: true)
    }

    private func setActiveTransport(
        _ transport: KeepTalkingTransportClient,
        route: String
    ) {
        stateQueue.sync {
            activeTransport = transport
            activeRoute = route
        }
    }

    private func fallbackToSFU(reason: String) {
        let switched = stateQueue.sync {
            guard activeRoute != "sfu" else { return false }
            activeTransport = sfuClient
            activeRoute = "sfu"
            return true
        }
        if switched {
            debug("route switched to sfu reason=\(reason)")
        }
    }

    private func beginP2PTrial(
        trigger: String,
        allowWhileOnP2P: Bool = false
    ) {
        guard config.p2pAttemptTimeoutSeconds > 0 else {
            debug(
                "p2p trial skipped trigger=\(trigger) timeout=\(config.p2pAttemptTimeoutSeconds)"
            )
            return
        }

        let state = stateQueue.sync { () -> (route: String, running: Bool) in
            (activeRoute, isP2PTrialRunning)
        }
        guard state.route != "p2p" || allowWhileOnP2P else {
            debug("p2p trial skipped trigger=\(trigger) reason=already-on-p2p")
            return
        }
        guard !state.running || allowWhileOnP2P else {
            debug("p2p trial skipped trigger=\(trigger) reason=trial-in-progress")
            return
        }
        if state.route == "p2p" {
            fallbackToSFU(reason: "forcing p2p retrial trigger=\(trigger)")
        }

        p2pUpgradeTask?.cancel()
        p2pUpgradeTask = nil
        p2pClient?.stop()

        let p2pClient = makeP2PClient()
        self.p2pClient = p2pClient
        bindCallbacks()
        stateQueue.sync {
            isP2PTrialRunning = true
        }
        debug(
            "starting p2p trial trigger=\(trigger) timeout=\(config.p2pAttemptTimeoutSeconds)"
        )

        p2pUpgradeTask = Task { [weak self, p2pClient] in
            guard let self else { return }
            defer {
                self.stateQueue.sync {
                    self.isP2PTrialRunning = false
                }
                self.p2pUpgradeTask = nil
            }

            do {
                try await p2pClient.start()
                setActiveTransport(p2pClient, route: "p2p")
                debug("p2p route selected; keeping sfu as warm fallback")
            } catch {
                p2pClient.stop()
                debug(
                    "p2p trial failed trigger=\(trigger) error=\(error.localizedDescription)"
                )
            }
        }
    }

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

    private func sendPresence() {
        do {
            try sfuClient.sendEnvelope(
                .p2pPresence(KeepTalkingP2PPresencePayload(node: config.node))
            )
        } catch {
            debug("send presence failed error=\(error.localizedDescription)")
        }
    }

    private func rememberPeer(_ node: UUID) {
        _ = stateQueue.sync {
            discoveredPeers.insert(node)
        }
    }

    private func reportPeerConnected(_ nodeID: UUID, source: String) {
        guard nodeID != config.node else { return }
        let inserted = stateQueue.sync { () -> Bool in
            discoveredPeers.insert(nodeID)
            return notifiedConnectedPeers.insert(nodeID).inserted
        }
        guard inserted else { return }
        debug(
            "peer reachable source=\(source) node=\(nodeID.uuidString.lowercased())"
        )
        onPeerConnect?(nodeID)
    }

    private func peersSnapshot() -> [UUID] {
        stateQueue.sync {
            Array(discoveredPeers)
        }
    }

    private func handleSFUEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
        case .p2pPresence(let presence):
            let shouldConnect =
                try await KeepTalkingNodeRelation
                .query(on: localStore.database)
                .filter(\.$from.$id == config.node)
                .filter(\.$to.$id == presence.node)
                .filter(\.$relationship ~~ [.owner, .trusted, .pending])
                .count() > 0

            debug("presence node=\(presence.node.uuidString.lowercased()) connect=\(shouldConnect)")

            if presence.node == config.node {
                debug(
                    "received presence for local node id=\(config.node.uuidString.lowercased()); check that each client uses a unique --node UUID"
                )
            } else if shouldConnect {
                beginP2PTrial(
                    trigger: "presence:\(presence.node.uuidString.lowercased())"
                )
            } else {
                debug(
                    "presence ignored for p2p trial: relation policy does not allow node=\(presence.node.uuidString.lowercased())"
                )
            }
            rememberPeer(presence.node)
            p2pClient?.receivePresence(from: presence.node)
            onEnvelope?(envelope)
        case .p2pSignal(let signalPayload):
            if signalPayload.from == config.node {
                debug(
                    "received signaling envelope from local node id=\(config.node.uuidString.lowercased()); check duplicate --node UUID usage"
                )
            }
            rememberPeer(signalPayload.from)
            p2pClient?.receiveSignal(signalPayload)
            onEnvelope?(envelope)
        default:
            onEnvelope?(envelope)
        }
    }

    private func bindCallbacks() {
        let forwardMessage: @Sendable (KeepTalkingContextMessage) -> Void = {
            [weak self] message in
            self?.onMessage?(message)
        }
        let forwardRaw: @Sendable (String) -> Void = { [weak self] raw in
            self?.onRawMessage?(raw)
        }
        let logger = onLog

        sfuClient.onMessage = forwardMessage
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
        sfuClient.onRawMessage = forwardRaw
        sfuClient.onPeerConnect = { [weak self] nodeID in
            self?.reportPeerConnected(nodeID, source: "sfu")
        }
        sfuClient.onLog = logger

        p2pClient?.onMessage = forwardMessage
        p2pClient?.onEnvelope = { [weak self] envelope in
            self?.onEnvelope?(envelope)
        }
        p2pClient?.onRawMessage = forwardRaw
        p2pClient?.onPeerConnect = { [weak self] nodeID in
            self?.reportPeerConnected(nodeID, source: "p2p")
        }
        p2pClient?.onTransportDegraded = { [weak self] reason in
            self?.fallbackToSFU(reason: reason)
        }
        p2pClient?.onLog = logger
    }
}
