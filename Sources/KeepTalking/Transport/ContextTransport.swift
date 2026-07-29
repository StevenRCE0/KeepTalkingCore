import Dispatch
import FluentKit
import Foundation

/// Logic-only orchestrator that routes envelopes through broadcast and direct channels.
///
/// ContextTransport has NO transport-specific knowledge — it depends only on
/// `KeepTalkingTransportChannelProtocol` and `KeepTalkingPeerTransportChannel`.
/// It does not know about SFU, P2P, WebRTC, ICE, or data channels.
///
/// Routing — three shapes, chosen by `allowsDirect` and whether the envelope
/// names a target:
///   !allowsDirect            → broadcast only (SFU reaches every peer)
///   allowsDirect + target    → that peer's direct channel, else broadcast
///   allowsDirect + no target → fan out over every ready direct channel, with
///                              broadcast covering peers that have none
///   nothing available → throw
///
/// The SFU stays the always-on backbone: presence, signaling, trust and voice
/// setup are `!allowsDirect` precisely because they must reach peers no direct
/// channel exists for yet. Direct channels are an opportunistic overlay.
///
/// A fanned-out envelope can reach a dual-connected peer twice. That is safe
/// because every fan-out-eligible kind is idempotent on receive — see
/// `KeepTalkingEnvelopeKind.isFanOutEligible`. There is no transport-level
/// dedup; duplicate suppression lives at persistence, keyed on row id.
///
/// Receive:
///   channel == .signaling → consume internally
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

    // MARK: - Dependencies

    private let config: KeepTalkingConfig
    private let livenessState: KeepTalkingContextLivenessState

    /// The always-on broadcast backbone.
    let broadcast: any KeepTalkingBroadcastTransportChannel

    /// Factory for creating peer direct channels — injected for testability.
    private let directChannelFactory: (UUID) -> any KeepTalkingPeerTransportChannel

    /// Fingerprint of the local network vantage point — injected so tests can
    /// drive an environment change without touching real interfaces.
    private let environmentDigest: @Sendable () -> String

    // MARK: - Internal state

    private var directChannels: [UUID: any KeepTalkingPeerTransportChannel] = [:]
    /// Once the context outgrows `maxDirectMeshSize` we stop maintaining a
    /// direct mesh and stay on the SFU. Sticky so a peer leaving does not flap
    /// the whole mesh back up; cleared on a transport start or when the network
    /// environment changes under us. Mirrors `KeepTalkingVoiceSession`'s auto
    /// mesh cap, which solved the same problem for the ICE mesh.
    private var directMeshDisabled = false
    /// Last sampled `environmentDigest()`. Guarded by `stateQueue` alongside
    /// `directMeshDisabled`, whose validity it decides.
    private var lastEnvironmentDigest: String?
    private var heartbeatTask: Task<Void, Never>?
    private var discoveredPeers = Set<UUID>()
    private var peerMissedWaves: [UUID: Int] = [:]
    private var lifecycleGeneration: UInt64 = 0
    private var activeStartGeneration: UInt64?
    private var isStarted = false
    private var isStopping = false
    private let stateQueue = DispatchQueue(label: "kt.context-transport.state")
    private let lifecycleOperationLock = NSLock()

    // MARK: - Init

    init(
        config: KeepTalkingConfig,
        livenessState: KeepTalkingContextLivenessState,
        broadcast: any KeepTalkingBroadcastTransportChannel,
        directChannelFactory: @escaping (UUID) -> any KeepTalkingPeerTransportChannel,
        environmentDigest: @escaping @Sendable () -> String = {
            KeepTalkingNetworkEnvironment.digest()
        }
    ) {
        self.environmentDigest = environmentDigest
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
        let digest = environmentDigest()
        stateQueue.sync {
            directMeshDisabled = false
            lastEnvironmentDigest = digest
        }
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

        broadcast.stop()
        stateQueue.sync {
            if lifecycleGeneration == stopped.2 { isStopping = false }
        }
    }

    // MARK: - Send

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        guard envelope.kind.allowsDirect else {
            try sendBroadcastOnly(
                sendViaSFU: { try broadcast.send(envelope) })
            return
        }
        if let target = envelope.targetPeerNodeID {
            try sendDirected(
                to: target,
                sendViaP2P: { try $0.send(envelope) },
                sendViaSFU: { try broadcast.send(envelope) }
            )
            return
        }
        try sendFannedOut(
            envelope,
            sendViaP2P: { try $0.send(envelope) },
            sendViaSFU: { try broadcast.send(envelope) }
        )
    }

    func sendBlobData(
        _ data: Data,
        targetPeerNodeID: UUID?
    ) throws {
        // Blob bytes are never fanned out: an untargeted blob is a broadcast,
        // not "send to everyone individually". Without this guard a nil target
        // would push the whole payload down every direct channel.
        guard let targetPeerNodeID else {
            try sendBroadcastOnly(
                sendViaSFU: { try broadcast.sendBlobData(data) })
            return
        }
        try sendDirected(
            to: targetPeerNodeID,
            sendViaP2P: { try $0.sendBlobData(data) },
            sendViaSFU: { try broadcast.sendBlobData(data) }
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

    // MARK: - Broadcast callback binding

    private func bindBroadcastCallbacks(generation: UInt64) {
        broadcast.onReceive = { [weak self] envelope in
            guard self?.isLifecycleActive(generation) == true else { return }
            self?.handleIncoming(envelope, generation: generation)
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
        _ envelope: any KeepTalkingEnvelope,
        generation: UInt64
    ) {
        // The lock still guards the lifecycle read — it was never dedup
        // scaffolding, and dropping it here would race teardown.
        lifecycleOperationLock.lock()
        let isActive = isLifecycleActive(generation)
        lifecycleOperationLock.unlock()
        guard isActive else { return }

        // Duplicate delivery is absorbed at persistence (by row id), not here:
        // fan-out can reach a dual-connected peer over both routes, and every
        // fan-out-eligible kind is idempotent. See `isFanOutEligible`.

        // P2P signaling consumed internally — never reaches app
        if envelope.channel == .signaling {
            handleP2PSignaling(envelope, generation: generation)
        } else {
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
        // aligned.
        //
        // The backstop fires only until a durable record of the decision
        // exists. A stored channel is that record in the normal case — its
        // state machine then owns the retry budget. When the mesh cap refused
        // this peer there is no channel to hold that state, so the disabled
        // flag is the record instead; without checking it, every beat would
        // allocate a channel the cap refuses again, which is exactly the storm
        // this comment claims cannot happen.
        if node != config.node {
            let needsBackstop = stateQueue.sync {
                directChannels[node] == nil && !directMeshDisabled
            }
            if observation.isNewConnection || needsBackstop {
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

    /// Whether a direct channel to `nodeID` should be maintained at all.
    ///
    /// A full mesh costs one ICE agent plus one HTTP/2 channel per peer per
    /// node, so it stops paying off well before the context does. Above the cap
    /// we tear the mesh down and let the SFU carry everything — it already
    /// reaches every peer, which is why it stays the backbone.
    private func admitsDirectMesh(joining nodeID: UUID) -> Bool {
        enum Admission {
            case admit
            case refuse
            case trip(projected: Int)
        }
        // One critical section: reading the flag a second time to tell "already
        // disabled" from "admitted" would let a concurrent trip flip the answer
        // between the two reads.
        let admission = stateQueue.sync { () -> Admission in
            if directMeshDisabled { return .refuse }
            let projected =
                directChannels.keys.contains(nodeID)
                ? directChannels.count
                : directChannels.count + 1
            guard projected > config.maxDirectMeshSize else { return .admit }
            directMeshDisabled = true
            return .trip(projected: projected)
        }
        switch admission {
            case .admit:
                return true
            case .refuse:
                return false
            case .trip(let projected):
                debug(
                    "direct mesh disabled: \(projected) peers would exceed maxDirectMeshSize=\(config.maxDirectMeshSize); staying on SFU"
                )
                tearDownDirectMesh()
                return false
        }
    }

    /// Closes every direct channel and drops them. Callers hold
    /// `lifecycleOperationLock`; teardown itself happens outside `stateQueue`.
    private func tearDownDirectMesh() {
        let channels = stateQueue.sync { () -> [any KeepTalkingPeerTransportChannel] in
            let existing = Array(directChannels.values)
            directChannels.removeAll()
            return existing
        }
        for channel in channels {
            channel.teardown()
        }
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
            guard admitsDirectMesh(joining: nodeID) else {
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
        direct.onReceive = { [weak self] envelope in
            guard
                self?.isCurrentDirectChannel(
                    directID,
                    nodeID: nodeID,
                    generation: generation
                ) == true
            else { return }
            self?.handleIncoming(envelope, generation: generation)
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
        guard admitsDirectMesh(joining: nodeID) else {
            lifecycleOperationLock.unlock()
            direct.teardown()
            return
        }
        stateQueue.sync { directChannels[nodeID] = direct }
        direct.attemptUpgrade()
        lifecycleOperationLock.unlock()
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
                self.reconcileNetworkEnvironment(generation: generation)
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

    /// Re-arm direct-path decisions that were reached in a different network.
    ///
    /// `directMeshDisabled` and an exhausted per-channel failure budget both
    /// encode "direct does not work from here". Neither survives a move to
    /// another network, and neither notices one: the mesh flag clears only on a
    /// transport start, and an abandoned channel revives only on a per-peer
    /// reachability edge that a still-online peer never produces. Sampling the
    /// environment digest each beat makes the move itself the trigger.
    ///
    /// Peers the cap refused have no channel to retry — clearing the flag is
    /// their retry, since the next presence beat's backstop re-creates them.
    ///
    /// Not private: the tests drive it directly rather than waiting out a beat.
    func reconcileNetworkEnvironment() {
        guard let generation = activeLifecycleGeneration() else { return }
        reconcileNetworkEnvironment(generation: generation)
    }

    private func reconcileNetworkEnvironment(generation: UInt64) {
        guard isLifecycleActive(generation) else { return }
        let digest = environmentDigest()

        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }
        guard isLifecycleActive(generation) else { return }

        let changed = stateQueue.sync { () -> Bool in
            guard let last = lastEnvironmentDigest else {
                lastEnvironmentDigest = digest
                return false
            }
            guard last != digest else { return false }
            lastEnvironmentDigest = digest
            directMeshDisabled = false
            return true
        }
        guard changed else { return }
        debug("network environment changed; re-arming direct paths")

        // Only channels that gave up or are waiting out a now-meaningless
        // backoff. A negotiation started in the old environment fails on its
        // own timeout, and restarting a ready channel would drop a live path.
        let retryable = stateQueue.sync {
            directChannels.values.filter { channel in
                switch channel.state {
                    case .abandoned, .backingOff: return true
                    default: return false
                }
            }
        }
        for channel in retryable {
            channel.requestRetrial()
            channel.attemptUpgrade()
        }
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

    private func readyDirectChannel(
        for targetPeerNodeID: UUID
    ) -> (any KeepTalkingPeerTransportChannel)? {
        let channel = stateQueue.sync { directChannels[targetPeerNodeID] }
        // `isReady` reaches into the channel's own queue, so it is evaluated
        // after `stateQueue` is released rather than nested inside it.
        guard let channel, channel.isReady else { return nil }
        return channel
    }

    /// Every peer we currently hold a ready direct channel to.
    private func readyDirectChannels() -> [(peer: UUID, channel: any KeepTalkingPeerTransportChannel)] {
        let snapshot = stateQueue.sync { directChannels }
        return snapshot.compactMap { peer, channel in
            channel.isReady ? (peer, channel) : nil
        }
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

    /// SFU only. Used by kinds that must reach every peer in the context,
    /// including ones no direct channel exists for.
    private func sendBroadcastOnly(sendViaSFU: () throws -> Void) throws {
        guard broadcast.isReady else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try sendViaSFU()
    }

    /// One named peer. Prefers its direct channel and falls back to the SFU,
    /// which can still reach the peer because the SFU is the always-on
    /// backbone every node stays joined to.
    private func sendDirected(
        to peer: UUID,
        sendViaP2P: ((any KeepTalkingPeerTransportChannel) throws -> Void),
        sendViaSFU: () throws -> Void
    ) throws {
        if let direct = readyDirectChannel(for: peer) {
            do {
                try sendViaP2P(direct)
                return
            } catch let error as KeepTalkingTransportError {
                // An oversized envelope is the publisher's bug, not a route
                // failure — retrying it on the SFU would just fail again.
                if case .envelopeTooLarge = error { throw error }
                debug(
                    "p2p send failed peer=\(peer.uuidString.prefix(8)) error=\(error.localizedDescription)"
                )
            } catch {
                debug(
                    "p2p send failed peer=\(peer.uuidString.prefix(8)) error=\(error.localizedDescription)"
                )
            }
        }
        guard broadcast.isReady else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try sendViaSFU()
    }

    /// Broadcast-addressed and direct-capable: hand the envelope to every ready
    /// direct channel, and let the SFU cover the peers that have none.
    ///
    /// Peers holding a direct channel may also receive the SFU copy, because an
    /// SFU broadcast reaches the whole context. That is safe only for kinds
    /// that are idempotent on receive — hence the `isFanOutEligible` check.
    private func sendFannedOut(
        _ envelope: any KeepTalkingEnvelope,
        sendViaP2P: ((any KeepTalkingPeerTransportChannel) throws -> Void),
        sendViaSFU: () throws -> Void
    ) throws {
        guard envelope.kind.isFanOutEligible else {
            // Soft, not a precondition: falling back to the SFU is always
            // correct, so an unexpected kind degrades instead of trapping.
            assertionFailure(
                "\(envelope.kind.rawValue) is untargeted and allowsDirect but not fan-out eligible"
            )
            debug("fan-out refused for kind=\(envelope.kind.rawValue); using broadcast")
            try sendBroadcastOnly(sendViaSFU: sendViaSFU)
            return
        }

        let direct = readyDirectChannels()
        var delivered = 0
        var oversize: KeepTalkingTransportError?
        for (peer, channel) in direct {
            do {
                try sendViaP2P(channel)
                delivered += 1
            } catch {
                // One bad channel must not stop the others; the SFU leg below
                // still covers this peer.
                if let transportError = error as? KeepTalkingTransportError,
                    case .envelopeTooLarge = transportError
                {
                    oversize = transportError
                }
                debug(
                    "fan-out leg failed peer=\(peer.uuidString.prefix(8)) error=\(error.localizedDescription)"
                )
            }
        }

        guard broadcast.isReady else {
            // No SFU: the fan-out legs are all we had. Succeed only if at
            // least one landed, otherwise report the send as failed.
            //
            // Report oversize as itself rather than as an outage. Every leg
            // failed the same size check and every retry will too, so the
            // outbox needs to see the real cause to drop the entry instead of
            // queueing it behind a wait for channels that are already up.
            guard delivered > 0 else {
                throw oversize ?? KeepTalkingTransportError.allChannelsUnavailable
            }
            return
        }
        try sendViaSFU()
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
