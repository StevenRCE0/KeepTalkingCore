import Dispatch
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
    private var lifecycleGeneration: UInt64 = 0
    private var activeStartGeneration: UInt64?
    private var isStarted = false
    private var isStopping = false
    private let stateQueue = DispatchQueue(label: "kt.context-transport.state")
    private let lifecycleOperationLock = NSLock()

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

    func start() throws -> Task<Void, Error> {
        guard
            let generation = stateQueue.sync(execute: { () -> UInt64? in
                guard activeStartGeneration == nil, !isStarted, !isStopping else { return nil }
                lifecycleGeneration &+= 1
                activeStartGeneration = lifecycleGeneration
                discoveredPeers.removeAll()
                peerMissedWaves = [:]
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
        do {
            let startTask = try prepareBroadcastStart(generation: generation)
            try await startTask.waitPropagatingCancellation()
            try Task.checkCancellation()
            guard startHeartbeatLoop(generation: generation) else {
                throw CancellationError()
            }
        } catch {
            cancelStart(generation: generation)
            throw error
        }
        debug("broadcast channel ready")
    }

    private func prepareBroadcastStart(generation: UInt64) throws -> Task<Void, Error> {
        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }
        guard isLifecycleActive(generation) else { throw CancellationError() }

        livenessState.reset()
        dedup.reset()
        // Never reset `sendSequence`: peers may still remember this node's
        // prior sequence after a transport bounce.
        rememberPeer(config.node)
        bindBroadcastCallbacks(generation: generation)
        return try broadcast.start()
    }

    private func cancelStart(generation: UInt64) {
        lifecycleOperationLock.lock()
        let shouldStop = stateQueue.sync {
            guard lifecycleGeneration == generation else { return false }
            activeStartGeneration = nil
            isStopping = true
            return true
        }
        lifecycleOperationLock.unlock()
        guard shouldStop else { return }
        broadcast.stop()
        stateQueue.sync {
            if lifecycleGeneration == generation { isStopping = false }
        }
    }

    func stop() {
        lifecycleOperationLock.lock()
        let stopped = stateQueue.sync {
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            activeStartGeneration = nil
            isStarted = false
            isStopping = true
            let result = (heartbeatTask, Array(directChannels.values))
            heartbeatTask = nil
            directChannels.removeAll()
            discoveredPeers.removeAll()
            peerMissedWaves = [:]
            return (result.0, result.1, generation)
        }
        lifecycleOperationLock.unlock()
        stopped.0?.cancel()
        livenessState.reset()

        for direct in stopped.1 {
            direct.teardown()
        }
        for (_, strategy) in strategies { strategy.reset() }

        broadcast.stop()
        stateQueue.sync {
            if lifecycleGeneration == stopped.2 { isStopping = false }
        }
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
        sendPresence()
        broadcast.sendLivenessProbe()
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

    private func bindBroadcastCallbacks(generation: UInt64) {
        broadcast.onReceive = { [weak self] sequenced in
            guard self?.isLifecycleActive(generation) == true else { return }
            self?.handleIncoming(sequenced, generation: generation)
        }
        broadcast.onStateChange = { [weak self] in
            self?.handleBroadcastStateChange(generation: generation)
        }
        broadcast.onPeerJoined = { [weak self] in
            guard self?.isLifecycleActive(generation) == true else { return }
            self?.sendPresence()
        }
        broadcast.onLog = onLog
        broadcast.contextSecretProvider = contextSecretProvider
    }

    private func handleBroadcastStateChange(generation: UInt64) {
        guard isLifecycleActive(generation) else { return }
        if broadcast.isReady {
            bindBroadcastBlobCallback(generation: generation)
            sendPresence()
            onBroadcastReady?()
        }
        debug("broadcast state changed to \(broadcast.state.description)")
    }

    private func bindBroadcastBlobCallback(generation: UInt64) {
        broadcast.onBlobData = { [weak self] data in
            guard self?.isLifecycleActive(generation) == true else { return }
            self?.onBlobData?(data)
        }
        broadcast.onRealtimeData = { [weak self] data in
            guard self?.isLifecycleActive(generation) == true else { return }
            self?.onRealtimeData?(data)
        }
    }

    // MARK: - Receive (dedup + type dispatch)

    private func handleIncoming(
        _ sequenced: KeepTalkingSequencedEnvelope,
        generation: UInt64
    ) {
        lifecycleOperationLock.lock()
        guard isLifecycleActive(generation) else {
            lifecycleOperationLock.unlock()
            return
        }
        // Dedup across both channels
        if sequenced.sequence != 0 {
            guard !dedup.checkAndRecord(sender: sequenced.senderNode, sequence: sequenced.sequence) else {
                lifecycleOperationLock.unlock()
                return
            }
        }
        lifecycleOperationLock.unlock()

        let envelope = sequenced.envelope

        // P2P signaling consumed internally — never reaches app
        switch envelope.envelopeType {
            case .p2pSignaling:
                handleP2PSignaling(envelope, generation: generation)
            case .chat, .service:
                guard isLifecycleActive(generation) else { return }
                onEnvelope?(envelope)
        }
    }

    // MARK: - P2P signaling (consumed internally)

    private func handleP2PSignaling(
        _ envelope: any KeepTalkingEnvelope,
        generation: UInt64
    ) {
        guard isLifecycleActive(generation) else { return }
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
        handlers.onP2PSignal { [weak self] signal in
            self?.handleP2PSignal(signal, generation: generation)
        }
        handlers.onP2PPresence { [weak self] presence in
            self?.handlePresence(presence, generation: generation)
        }
        handlers.handle(envelope)
    }

    private func handleP2PSignal(
        _ signal: KeepTalkingP2PSignalPayload,
        generation: UInt64
    ) {
        guard rememberPeer(signal.from, generation: generation) else { return }
        let direct: KeepTalkingPeerTransportChannel? = stateQueue.sync {
            guard lifecycleGeneration == generation else { return nil }
            return directChannels[signal.from]
        }
        if direct == nil {
            handleParticipantJoined(signal.from, generation: generation)
        }
        lifecycleOperationLock.lock()
        guard isLifecycleActive(generation),
            let current = stateQueue.sync(execute: { directChannels[signal.from] })
        else {
            lifecycleOperationLock.unlock()
            return
        }
        current.receiveSignal(signal)
        lifecycleOperationLock.unlock()
    }

    private func handlePresence(
        _ presence: KeepTalkingP2PPresencePayload,
        generation: UInt64
    ) {
        let node = presence.node
        guard
            let observation = observePeerAlive(
                node,
                source: "presence",
                generation: generation
            )
        else { return }

        if observation.shouldEcho, isLifecycleActive(generation) {
            sendPresence()
        }

        // A direct upgrade kicks off a fresh ICE candidate gather, so drive it
        // only on a real reachability edge (offline→online) — never on every
        // ~13s heartbeat. Per-beat prods re-gather candidates each cycle (the
        // SDP-gathering storm) and, because handleParticipantJoined calls
        // requestRetrial, reset the channel's backoff and failure budget every
        // beat — defeating both the exponential backoff and the maxFailures
        // circuit breaker. This is the same wave→edge lesson the liveness state
        // already applies to peer notification and presence echo; keep them
        // aligned. The `!hasChannel` backstop only fires until the channel
        // object exists, so it can't itself storm.
        if node != config.node {
            let hasChannel = stateQueue.sync { directChannels[node] != nil }
            if observation.isNewConnection || !hasChannel {
                handleParticipantJoined(node, generation: generation)
            }
        }

        // Forward presence to the app for higher-level handling
        guard isLifecycleActive(generation) else { return }
        onEnvelope?(presence)
    }

    // MARK: - Participant lifecycle

    private func handleParticipantJoined(_ nodeID: UUID) {
        guard nodeID != config.node else { return }
        guard let generation = activeLifecycleGeneration() else { return }
        handleParticipantJoined(nodeID, generation: generation)
    }

    private func handleParticipantJoined(_ nodeID: UUID, generation: UInt64) {
        guard nodeID != config.node else { return }
        if let existing = stateQueue.sync(execute: { directChannels[nodeID] }) {
            lifecycleOperationLock.lock()
            guard isLifecycleActive(generation) else {
                lifecycleOperationLock.unlock()
                return
            }
            guard stateQueue.sync(execute: { directChannels[nodeID] === existing }) else {
                lifecycleOperationLock.unlock()
                return
            }
            let s = existing.state
            guard s != .ready, s != .negotiating else {
                lifecycleOperationLock.unlock()
                return
            }
            existing.requestRetrial()
            existing.attemptUpgrade()
            lifecycleOperationLock.unlock()
            debug("participant retrying direct node=\(nodeID.uuidString.prefix(8))")
            return
        }

        let direct = directChannelFactory(nodeID)
        let directID = ObjectIdentifier(direct)
        direct.onReceive = { [weak self] sequenced in
            guard
                self?.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                ) == true
            else { return }
            self?.handleIncoming(sequenced, generation: generation)
        }
        direct.onBlobData = { [weak self] data in
            guard
                self?.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                ) == true
            else { return }
            self?.onBlobData?(data)
        }
        direct.onRealtimeData = nil
        direct.onSignalOutput = { [weak self] signal in
            guard let self,
                self.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                )
            else { return }
            do {
                try self.broadcast.sendRawEnvelope(signal)
            } catch {
                self.debug("failed sending p2p signal via broadcast error=\(error.localizedDescription)")
            }
        }
        direct.onPeerAlive = { [weak self] nodeID in
            guard
                self?.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                ) == true
            else { return }
            self?.handlePeerAlive(nodeID, generation: generation)
        }
        direct.onStateChange = { [weak self] in
            guard let self,
                self.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                )
            else { return }
            // Log for now
            if let direct = self.stateQueue.sync(execute: { self.directChannels[nodeID] }) {
                self.debug("direct[\(nodeID.uuidString.prefix(8))] state changed isReady=\(direct.isReady)")
            }
        }
        direct.onLog = onLog
        direct.contextSecretProvider = contextSecretProvider

        lifecycleOperationLock.lock()
        guard isLifecycleActive(generation) else {
            lifecycleOperationLock.unlock()
            direct.teardown()
            return
        }
        guard stateQueue.sync(execute: { directChannels[nodeID] == nil }) else {
            lifecycleOperationLock.unlock()
            direct.teardown()
            return
        }
        stateQueue.sync { directChannels[nodeID] = direct }
        direct.attemptUpgrade()
        lifecycleOperationLock.unlock()
        onParticipantChange?(.joined(nodeID: nodeID))
        debug("participant joined node=\(nodeID.uuidString.prefix(8))")
    }

    private func handleParticipantLeft(_ nodeID: UUID) {
        guard let generation = activeLifecycleGeneration() else { return }
        handleParticipantLeft(nodeID, generation: generation, expectedChannel: nil)
    }

    private func handleParticipantLeft(
        _ nodeID: UUID,
        generation: UInt64,
        expectedChannel: (any KeepTalkingPeerTransportChannel)?
    ) {
        lifecycleOperationLock.lock()
        guard isLifecycleActive(generation) else {
            lifecycleOperationLock.unlock()
            return
        }
        let direct = stateQueue.sync { () -> (any KeepTalkingPeerTransportChannel)? in
            guard let current = directChannels[nodeID] else { return nil }
            if let expectedChannel, current !== expectedChannel { return nil }
            return directChannels.removeValue(forKey: nodeID)
        }
        lifecycleOperationLock.unlock()
        guard let direct else { return }
        direct.teardown()
        onParticipantChange?(.left(nodeID: nodeID))
        debug("participant left node=\(nodeID.uuidString.prefix(8))")
    }

    // MARK: - Dual-source liveness

    private func handlePeerAlive(_ nodeID: UUID, generation: UInt64) {
        _ = observePeerAlive(nodeID, source: "p2p", generation: generation)
    }

    // MARK: - Heartbeat & liveness

    private func startHeartbeatLoop(generation: UInt64) -> Bool {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return false }
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
                guard !Task.isCancelled, self.isLifecycleActive(generation) else { break }
                self.sendPresence()
                self.checkPeerLiveness(generation: generation)
                self.tickStrategies(generation: generation)
            }
        }
        let retained = stateQueue.sync {
            guard lifecycleGeneration == generation,
                activeStartGeneration == generation
            else { return false }
            heartbeatTask?.cancel()
            heartbeatTask = task
            activeStartGeneration = nil
            isStarted = true
            return true
        }
        if !retained { task.cancel() }
        return retained
    }

    private func isLifecycleActive(_ generation: UInt64) -> Bool {
        stateQueue.sync {
            lifecycleGeneration == generation
                && (activeStartGeneration == generation || isStarted)
        }
    }

    private func activeLifecycleGeneration() -> UInt64? {
        stateQueue.sync {
            guard !isStopping,
                activeStartGeneration == lifecycleGeneration || isStarted
            else { return nil }
            return lifecycleGeneration
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
    private func checkPeerLiveness(generation: UInt64) {
        guard isLifecycleActive(generation) else { return }
        let onlineNodes = livenessState.onlineNodeIDs()
        let remotePeersOnline = onlineNodes.subtracting([config.node])

        let channels = stateQueue.sync { directChannels }
        for (nodeID, direct) in channels {
            let isOnlineViaPresence = remotePeersOnline.contains(nodeID)
            let isOnlineViaDirect = direct.isReady

            if !isOnlineViaPresence && !isOnlineViaDirect {
                let missed = stateQueue.sync { () -> Int? in
                    guard lifecycleGeneration == generation else { return nil }
                    peerMissedWaves[nodeID, default: 0] += 1
                    return peerMissedWaves[nodeID]!
                }
                if let missed, missed >= Self.peerOfflineWavesThreshold {
                    debug("peer offline node=\(nodeID.uuidString.prefix(8)) missedWaves=\(missed)")
                    handleParticipantLeft(
                        nodeID,
                        generation: generation,
                        expectedChannel: direct
                    )
                    stateQueue.sync {
                        if lifecycleGeneration == generation {
                            peerMissedWaves.removeValue(forKey: nodeID)
                        }
                    }
                }
            } else {
                stateQueue.sync {
                    if lifecycleGeneration == generation {
                        peerMissedWaves.removeValue(forKey: nodeID)
                    }
                }
            }
        }
    }

    // MARK: - Conservative promotion

    /// Tick every strategy with each peer's current channel readiness.
    /// Stateless strategies no-op; the conservative strategy uses this
    /// to track promotion.
    private func tickStrategies(generation: UInt64) {
        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }
        guard isLifecycleActive(generation) else { return }
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

    private func rememberPeer(_ node: UUID, generation: UInt64) -> Bool {
        stateQueue.sync {
            guard lifecycleGeneration == generation,
                activeStartGeneration == generation || isStarted
            else { return false }
            _ = discoveredPeers.insert(node)
            return true
        }
    }

    private func directChannel(for targetPeerNodeID: UUID?) -> (any KeepTalkingPeerTransportChannel)? {
        guard let targetPeerNodeID else { return nil }
        return stateQueue.sync { directChannels[targetPeerNodeID] }
    }

    private func isCurrentDirectChannel(
        _ channelID: ObjectIdentifier,
        nodeID: UUID,
        generation: UInt64
    ) -> Bool {
        stateQueue.sync {
            guard lifecycleGeneration == generation,
                activeStartGeneration == generation || isStarted,
                let current = directChannels[nodeID]
            else { return false }
            return ObjectIdentifier(current) == channelID
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

    private func observePeerAlive(
        _ nodeID: UUID,
        source: String,
        generation: UInt64
    ) -> KeepTalkingContextLivenessState.PresenceObservation? {
        lifecycleOperationLock.lock()
        guard isLifecycleActive(generation) else {
            lifecycleOperationLock.unlock()
            return nil
        }
        stateQueue.sync { _ = discoveredPeers.insert(nodeID) }
        let observation = livenessState.observePresence(
            from: nodeID,
            echoCooldown: Self.presenceEchoCooldownSeconds
        )
        if observation.isNewConnection, nodeID != config.node {
            onPeerConnect?(nodeID)
        }
        lifecycleOperationLock.unlock()
        if observation.isNewConnection, nodeID != config.node {
            debug("peer reachable source=\(source) node=\(nodeID.uuidString.prefix(8))")
        }
        return observation
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
