import FluentKit
import Foundation

/// Logic-only orchestrator that routes envelopes through broadcast and direct channels.
///
/// ContextTransport has NO transport-specific knowledge — it depends only on
/// `KeepTalkingTransportChannelProtocol` and `KeepTalkingPeerTransportChannel`.
/// It does not know about SFU, P2P, WebRTC, ICE, or data channels.
///
/// Routing:
///   switch envelope.routingStrategy:
///     .sfuOnly       → broadcast.send (no P2P attempt)
///     .preferDirect  → directChannels[target] → fallback broadcast
///     .conservative  → broadcast → fallback directChannels[target]
///   all failed → throw
///
/// Receive:
///   dedup(sender, seq) → dup? drop
///   envelopeType == .p2pSignaling → consume internally
///   else → deliver to app
public final class KeepTalkingContextTransport: KeepTalkingTransportClient, @unchecked Sendable {

    private static let heartbeatIntervalSeconds: TimeInterval = 13
    private static let presenceEchoCooldownSeconds: TimeInterval = 1
    private static let peerOfflineWavesThreshold = 2

    // MARK: - KeepTalkingTransportClient conformance

    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onBroadcastReady: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    // MARK: - Public state

    /// Called when a participant joins or leaves.
    public var onParticipantChange: (@Sendable (ParticipantEvent) -> Void)?

    public enum ParticipantEvent: Sendable {
        case joined(nodeID: UUID)
        case left(nodeID: UUID)
    }

    // MARK: - Dependencies

    private let config: KeepTalkingConfig
    private let livenessState: KeepTalkingContextLivenessState

    /// The always-on broadcast backbone.
    let broadcast: any KeepTalkingBroadcastTransportChannel

    /// Factory for creating peer direct channels — injected for testability.
    private let directChannelFactory: (UUID) -> any KeepTalkingPeerTransportChannel

    // MARK: - Internal state

    private var directChannels: [UUID: any KeepTalkingPeerTransportChannel] = [:]
    private let dedup = KeepTalkingEnvelopeDedup()
    /// Monotonic per-send counter, used ONLY for receiver-side dedup keyed on
    /// `(senderNode, sequence)`. Seeded from a millisecond time base rather
    /// than 0 so that a transport bounce (`reestablishTransport`) or process
    /// restart resumes *above* any sequence a peer still remembers for this
    /// node. Restarting at 0 caused re-announces (incl. `voice.started`) to be
    /// silently deduped by peers that hadn't reset — manifesting as one-way
    /// discovery ("A sees B, B never sees A"). Never reset on `start()`.
    private var sendSequence: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    private let sequenceLock = NSLock()
    private var heartbeatTask: Task<Void, Never>?
    private var discoveredPeers = Set<UUID>()
    private var peerMissedWaves: [UUID: Int] = [:]
    private let stateQueue = DispatchQueue(label: "kt.context-transport.state")

    /// Strategy instances keyed by policy. Each owns its own state
    /// (e.g. conservative tracks per-peer promotion internally).
    private let strategies: [KeepTalkingRoutingPolicy: any KeepTalkingRoutingStrategy] = [
        .preferDirect: KeepTalkingPreferDirectStrategy(),
        .sfuOnly: KeepTalkingSFUOnlyStrategy(),
        .conservative: KeepTalkingConservativeStrategy(),
    ]

    // MARK: - Init

    init(
        config: KeepTalkingConfig,
        livenessState: KeepTalkingContextLivenessState,
        broadcast: any KeepTalkingBroadcastTransportChannel,
        directChannelFactory: @escaping (UUID) -> any KeepTalkingPeerTransportChannel
    ) {
        self.config = config
        self.livenessState = livenessState
        self.broadcast = broadcast
        self.directChannelFactory = directChannelFactory
    }

    /// Convenience initializer that creates a default broadcast channel and direct channel factory.
    convenience init(
        config: KeepTalkingConfig,
        livenessState: KeepTalkingContextLivenessState
    ) {
        let broadcast = KeepTalkingBroadcastChannel(config: config)
        self.init(
            config: config,
            livenessState: livenessState,
            broadcast: broadcast,
            directChannelFactory: { [config, livenessState] peerNodeID in
                KeepTalkingDirectChannel(
                    peerNodeID: peerNodeID,
                    config: config,
                    localNodeID: config.node,
                    peersSnapshot: { Array(livenessState.onlineNodeIDs()) }
                )
            }
        )
    }

    // MARK: - Lifecycle

    func start() async throws {
        stateQueue.sync {
            discoveredPeers.removeAll()
            peerMissedWaves = [:]
        }
        livenessState.reset()
        dedup.reset()
        // NB: do NOT reset `sendSequence` here. It must stay monotonic across
        // restarts so peers don't dedup our re-announces against sequences
        // they already saw (see the property's doc comment). Our *own* dedup
        // is reset above so we re-accept peers' re-announces after a bounce.

        bindBroadcastCallbacks()
        try await broadcast.start()

        rememberPeer(config.node)
        sendPresence()
        startHeartbeatLoop()
        debug("broadcast channel ready")
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        livenessState.reset()

        for (_, direct) in directChannels {
            direct.teardown()
        }
        stateQueue.sync {
            directChannels.removeAll()
            peerMissedWaves = [:]
        }
        for (_, strategy) in strategies { strategy.reset() }

        broadcast.stop()
    }

    // MARK: - Send (strategy-based dispatch)

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        let sequenced = makeSequenced(envelope)
        try send(
            policy: envelope.routingPolicy,
            targetPeerNodeID: envelope.targetPeerNodeID,
            sendViaP2P: { direct in
                try direct.send(sequenced)
            },
            sendViaSFU: {
                try broadcast.send(sequenced)
            }
        )
    }

    func sendBlobData(
        _ data: Data,
        targetPeerNodeID: UUID?
    ) throws {
        try send(
            policy: .preferDirect,
            targetPeerNodeID: targetPeerNodeID,
            sendViaP2P: { direct in
                try direct.sendBlobData(data)
            },
            sendViaSFU: {
                try broadcast.sendBlobData(data)
            }
        )
    }

    func sendBlobDataViaBroadcast(_ data: Data) throws {
        guard broadcast.isReady else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try broadcast.sendBlobData(data)
    }

    func sendRealtimeDataViaBroadcast(_ data: Data) throws {
        guard broadcast.isReady else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try broadcast.sendRealtimeData(data)
    }

    func currentRoute() -> KeepTalkingTransportRoute {
        let hasReadyDirect = stateQueue.sync { directChannels.values.contains(where: { $0.isReady }) }
        return hasReadyDirect ? .p2p : .sfu
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let stats = broadcast.runtimeStats()
        return KeepTalkingRuntimeStats(
            sent: stats.sent,
            received: stats.received,
            outboundLabel: stats.outboundLabel,
            outboundState: stats.outboundState,
            inboundLabel: stats.inboundLabel,
            inboundState: stats.inboundState,
            retainedChannels: stats.retainedChannels,
            route: currentRoute().rawValue
        )
    }

    func broadcastState() -> BroadcastChannelState {
        broadcast.state
    }

    func sendLivenessProbe() {
        // Reuse the heartbeat presence wave. A reply (presence echo or SFU
        // roster response) lands on the counted inbound path, which
        // `probeTransport()` watches via `runtimeStats().received`.
        sendPresence()
    }

    func requestP2PTrial() {
        let peers = stateQueue.sync { Array(discoveredPeers.filter { $0 != config.node }) }
        for peer in peers {
            handleParticipantJoined(peer)
        }
    }

    func preferReliableRoute(reason: String) {
        debug("preferring reliable route reason=\(reason)")
        // Tear down all direct channels — broadcast covers
        let channels = stateQueue.sync { Array(directChannels.keys) }
        for nodeID in channels {
            handleParticipantLeft(nodeID)
        }
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [transport] route=\(currentRoute().rawValue) \(message)")
    }

    // MARK: - Sequencing

    private func nextSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sendSequence += 1
        return sendSequence
    }

    private func makeSequenced(_ envelope: any KeepTalkingEnvelope) -> KeepTalkingSequencedEnvelope {
        KeepTalkingSequencedEnvelope(
            senderNode: config.node,
            sequence: nextSequence(),
            envelope: envelope
        )
    }

    // MARK: - Broadcast callback binding

    private func bindBroadcastCallbacks() {
        broadcast.onReceive = { [weak self] sequenced in
            self?.handleIncoming(sequenced)
        }
        broadcast.onStateChange = { [weak self] in
            if self?.broadcast.isReady ?? false {
                self?.bindBroadcastBlobCallback()
                self?.onBroadcastReady?()
            }
            self?.debug("broadcast state changed to \(self?.broadcast.state.description ?? "?")")
        }
        broadcast.onLog = onLog
        broadcast.contextSecretProvider = contextSecretProvider
    }

    private func bindBroadcastBlobCallback() {
        broadcast.onBlobData = { [weak self] data in
            self?.onBlobData?(data)
        }
        broadcast.onRealtimeData = { [weak self] data in
            self?.onRealtimeData?(data)
        }
    }

    // MARK: - Receive (dedup + type dispatch)

    private func handleIncoming(_ sequenced: KeepTalkingSequencedEnvelope) {
        // Dedup across both channels
        if sequenced.sequence != 0 {
            guard !dedup.checkAndRecord(sender: sequenced.senderNode, sequence: sequenced.sequence) else {
                return
            }
        }

        let envelope = sequenced.envelope

        // P2P signaling consumed internally — never reaches app
        switch envelope.envelopeType {
            case .p2pSignaling:
                handleP2PSignaling(envelope)
            case .chat, .service:
                onEnvelope?(envelope)
        }
    }

    // MARK: - P2P signaling (consumed internally)

    private func handleP2PSignaling(_ envelope: any KeepTalkingEnvelope) {
        switch envelope.kind {
            case .trustRequest, .trustAccept, .trustComplete, .trustReject:
                onTrustEnvelope?(envelope)
                return
            case .voiceCallStarted, .voiceCallEnded, .voiceCallSignal:
                onEnvelope?(envelope)
                return
            default:
                break
        }

        var handlers = KeepTalkingEnvelopeHandlers()
        handlers.registerP2PSignalHandler(for: self)
        handlers.registerP2PPresenceHandler(for: self)
        handlers.handle(envelope)
    }

    func consumeP2PPresence(
        _ presence: KeepTalkingP2PPresencePayload
    ) {
        handlePresence(presence)
    }

    func consumeP2PSignal(
        _ signal: KeepTalkingP2PSignalPayload
    ) {
        rememberPeer(signal.from)
        let direct = stateQueue.sync { directChannels[signal.from] }
        if direct == nil {
            handleParticipantJoined(signal.from)
        }
        stateQueue.sync { directChannels[signal.from] }?.receiveSignal(signal)
    }

    private func handlePresence(_ presence: KeepTalkingP2PPresencePayload) {
        let node = presence.node
        rememberPeer(node)

        let observation = livenessState.observePresence(
            from: node,
            echoCooldown: Self.presenceEchoCooldownSeconds
        )

        if observation.shouldEcho {
            sendPresence()
        }

        if observation.isNewConnection {
            reportPeerConnected(node, source: "presence")
        }

        // A direct upgrade kicks off a fresh ICE candidate gather, so drive it
        // only on a real reachability edge (offline→online) — never on every
        // ~13s heartbeat. Per-beat prods re-gather candidates each cycle (the
        // SDP-gathering storm) and, because handleParticipantJoined calls
        // requestRetrial, reset the channel's backoff and failure budget every
        // beat — defeating both the exponential backoff and the maxFailures
        // circuit breaker. This is the same wave→edge lesson the liveness state
        // already applies to reportPeerConnected and presence-echo; keep them
        // aligned. The `!hasChannel` backstop only fires until the channel
        // object exists, so it can't itself storm.
        if node != config.node {
            let hasChannel = stateQueue.sync { directChannels[node] != nil }
            if observation.isNewConnection || !hasChannel {
                handleParticipantJoined(node)
            }
        }

        // Forward presence to the app for higher-level handling
        onEnvelope?(presence)
    }

    // MARK: - Participant lifecycle

    private func handleParticipantJoined(_ nodeID: UUID) {
        guard nodeID != config.node else { return }
        if let existing = stateQueue.sync(execute: { directChannels[nodeID] }) {
            let s = existing.state
            guard s != .ready, s != .negotiating else { return }
            existing.requestRetrial()
            existing.attemptUpgrade()
            debug("participant retrying direct node=\(nodeID.uuidString.prefix(8))")
            return
        }

        let direct = directChannelFactory(nodeID)
        direct.onReceive = { [weak self] sequenced in
            self?.handleIncoming(sequenced)
        }
        direct.onBlobData = { [weak self] data in
            self?.onBlobData?(data)
        }
        direct.onRealtimeData = nil
        direct.onSignalOutput = { [weak self] signal in
            guard let self else { return }
            do {
                try self.broadcast.sendRawEnvelope(signal)
            } catch {
                self.debug("failed sending p2p signal via broadcast error=\(error.localizedDescription)")
            }
        }
        direct.onPeerAlive = { [weak self] nodeID in
            self?.handlePeerAlive(nodeID)
        }
        direct.onStateChange = { [weak self] in
            // Log for now
            if let direct = self?.stateQueue.sync(execute: { self?.directChannels[nodeID] }) {
                self?.debug("direct[\(nodeID.uuidString.prefix(8))] state changed isReady=\(direct.isReady)")
            }
        }
        direct.onLog = onLog
        direct.contextSecretProvider = contextSecretProvider

        stateQueue.sync { directChannels[nodeID] = direct }
        direct.attemptUpgrade()
        onParticipantChange?(.joined(nodeID: nodeID))
        debug("participant joined node=\(nodeID.uuidString.prefix(8))")
    }

    private func handleParticipantLeft(_ nodeID: UUID) {
        let direct = stateQueue.sync {
            directChannels.removeValue(forKey: nodeID)
        }
        direct?.teardown()
        onParticipantChange?(.left(nodeID: nodeID))
        debug("participant left node=\(nodeID.uuidString.prefix(8))")
    }

    // MARK: - Dual-source liveness

    private func handlePeerAlive(_ nodeID: UUID) {
        // ICE connected on DirectChannel — confirm peer alive independently of SFU presence
        let observation = livenessState.observePresence(
            from: nodeID,
            echoCooldown: Self.presenceEchoCooldownSeconds
        )
        if observation.isNewConnection {
            reportPeerConnected(nodeID, source: "p2p")
        }
    }

    // MARK: - Heartbeat & liveness

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
                if Task.isCancelled { break }
                self.sendPresence()
                self.checkPeerLiveness()
                self.tickStrategies()
            }
        }
    }

    private func sendPresence() {
        do {
            try broadcast.sendRawEnvelope(
                KeepTalkingP2PPresencePayload(node: config.node)
            )
        } catch {
            debug("send presence failed error=\(error.localizedDescription)")
        }
    }

    /// Check peer liveness using dual sources:
    /// - SFU presence heartbeats (via broadcast)
    /// - ICE connection state (via DirectChannel onPeerAlive)
    ///
    /// A peer is offline only if BOTH sources report no activity.
    private func checkPeerLiveness() {
        let onlineNodes = livenessState.onlineNodeIDs()
        let remotePeersOnline = onlineNodes.subtracting([config.node])

        let channels = stateQueue.sync { directChannels }
        for (nodeID, direct) in channels {
            let isOnlineViaPresence = remotePeersOnline.contains(nodeID)
            let isOnlineViaDirect = direct.isReady

            if !isOnlineViaPresence && !isOnlineViaDirect {
                let missed = stateQueue.sync { () -> Int in
                    peerMissedWaves[nodeID, default: 0] += 1
                    return peerMissedWaves[nodeID]!
                }
                if missed >= Self.peerOfflineWavesThreshold {
                    debug("peer offline node=\(nodeID.uuidString.prefix(8)) missedWaves=\(missed)")
                    handleParticipantLeft(nodeID)
                    _ = stateQueue.sync { peerMissedWaves.removeValue(forKey: nodeID) }
                }
            } else {
                _ = stateQueue.sync { peerMissedWaves.removeValue(forKey: nodeID) }
            }
        }
    }

    // MARK: - Conservative promotion

    /// Tick every strategy with each peer's current channel readiness.
    /// Stateless strategies no-op; the conservative strategy uses this
    /// to track promotion.
    private func tickStrategies() {
        let channels = stateQueue.sync { directChannels }
        for (_, strategy) in strategies {
            for (nodeID, direct) in channels {
                strategy.tick(peer: nodeID, p2pReady: direct.isReady)
            }
        }
    }

    // MARK: - Peer tracking

    private func rememberPeer(_ node: UUID) {
        stateQueue.sync { _ = discoveredPeers.insert(node) }
    }

    private func directChannel(for targetPeerNodeID: UUID?) -> (any KeepTalkingPeerTransportChannel)? {
        stateQueue.sync {
            if let targetPeerNodeID {
                return directChannels[targetPeerNodeID]
            }
            return directChannels.first(where: { $0.value.isReady })?.value
        }
    }

    private func send(
        policy: KeepTalkingRoutingPolicy,
        targetPeerNodeID: UUID?,
        sendViaP2P: ((any KeepTalkingPeerTransportChannel) throws -> Void),
        sendViaSFU: () throws -> Void
    ) throws {
        guard let strategy = strategies[policy] else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        let direct = directChannel(for: targetPeerNodeID)
        let availability = KeepTalkingRouteAvailability(
            p2pReady: direct?.isReady ?? false,
            sfuReady: broadcast.isReady,
            targetPeer: targetPeerNodeID
        )
        guard let route = strategy.resolve(availability) else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        switch route {
            case .p2p:
                guard let direct else {
                    throw KeepTalkingTransportError.allChannelsUnavailable
                }
                do {
                    try sendViaP2P(direct)
                } catch {
                    if let peer = targetPeerNodeID {
                        strategy.recordFault(for: peer)
                    }
                    debug(
                        "p2p send failed peer=\(direct.peerNodeID.uuidString.prefix(8)) error=\(error.localizedDescription)"
                    )
                    guard broadcast.isReady else { throw error }
                    try sendViaSFU()
                }
            case .sfu:
                try sendViaSFU()
        }
    }

    /// Called only on a connect edge (callers gate on `observation.isNewConnection`),
    /// so this just notifies — the per-source/per-wave dedup the old liveness state
    /// did is no longer needed (the edge itself, shared across sources, is the dedup).
    private func reportPeerConnected(_ nodeID: UUID, source: String) {
        guard nodeID != config.node else { return }
        rememberPeer(nodeID)
        debug("peer reachable source=\(source) node=\(nodeID.uuidString.prefix(8))")
        onPeerConnect?(nodeID)
    }
}

// MARK: - BroadcastChannelState description

extension BroadcastChannelState: CustomStringConvertible {
    public var description: String {
        switch self {
            case .connecting: return "connecting"
            case .ready: return "ready"
            case .reconnecting(let n): return "reconnecting(\(n))"
            case .failed: return "failed"
        }
    }
}
