import Foundation
import NIOConcurrencyHelpers

/// The client's connection lifecycle, carved out of `KeepTalkingClient`.
///
/// Owns the generation-tracked connect/disconnect state machine, the
/// transport callback binding, and the three state signals derived from them:
/// `lifecycle`, `presence` and `transportStats`. The decision logic is the one
/// that lived in the client; this object only adds the emits.
///
/// Teardown serialization: `rtcClient.stop()` synchronously closes peer
/// connections, which joins worker threads and can block for hundreds of
/// milliseconds. It runs on a detached task so MainActor callers don't freeze
/// the UI, and `connect()` awaits any in-flight teardown so a tight
/// disconnect→connect sequence still serializes correctly.
///
/// The state machine is a lock, not an actor, on purpose: an actor would make
/// `disconnect()` async (the app and CLI call it synchronously) and put an
/// executor hop in the realtime voice-frame path. Everything the lock guards
/// lives in `State`, which is only reachable inside `withLockedValue`; a
/// helper that needs the lock held takes `inout State` (or a `State` copy for
/// read-only use), so "lock held" is enforced by the type rather than a
/// comment.
final class KeepTalkingClientConnection: Sendable {
    unowned let client: KeepTalkingClient
    // Held strongly, not reached through `client`: the detached teardown
    // publishes `.idle` after `rtcClient.stop()` returns, which can be after
    // the client that scheduled it was already released (settings restarts
    // drop the whole client dictionary). The signal box outliving the client
    // is harmless; an unowned hop through a dead client is a crash.
    private let signals: KeepTalkingClientSignals

    var lifecycle: KeepTalkingStateSignal<KeepTalkingClientLifecycle> { signals.lifecycle }
    var presence: KeepTalkingStateSignal<KeepTalkingClientPresence> { signals.presence }
    var transportStats: KeepTalkingStateSignal<KeepTalkingRuntimeStats> { signals.transportStats }

    private static let presenceSweepSeconds: TimeInterval = 10
    private static let statsSampleSeconds: TimeInterval = 1

    /// Everything the lifecycle lock guards.
    private struct State: Sendable {
        var pendingTeardown: Task<Void, Never>?
        var generation: UInt64 = 0
        var activeConnectGeneration: UInt64?
        var isConnected = false
        var isDisconnecting = false
        /// Last transport report, folded into `lifecycle`.
        var lastBroadcastState: BroadcastChannelState = .failed
        var lastRoute: KeepTalkingTransportRoute = .sfu
        /// What the next `.idle` says.
        var terminalCause: KeepTalkingClientLifecycle.Cause = .tornDown
        /// The periodic maintenance heartbeat (ContextMaintenance `.heartbeat`
        /// trigger). Started on `connect()`, cancelled on `disconnect()`.
        var maintenanceTask: Task<Void, Never>?
        /// Ancillary work that starts after the transport is usable. It must
        /// not keep `connect()` — and therefore the app's connection UI —
        /// pending.
        var postConnectTask: Task<Void, Never>?
        var presenceSweepTask: Task<Void, Never>?
        var statsSamplerTask: Task<Void, Never>?

        /// `generation` is the connect currently being brought up.
        func isCurrentConnect(_ generation: UInt64) -> Bool {
            self.generation == generation && activeConnectGeneration == generation
        }

        /// Connecting or connected, and not tearing down. `activeConnectGeneration`
        /// is only ever the current generation or nil, so this is the same test
        /// `isLifecycleActive` makes for the current generation.
        var isLive: Bool {
            !isDisconnecting && (activeConnectGeneration == generation || isConnected)
        }

        func isLifecycleActive(_ generation: UInt64) -> Bool {
            self.generation == generation
                && !isDisconnecting
                && (activeConnectGeneration == generation || isConnected)
        }
    }

    /// What reserving a disconnect hands back to the caller: the tasks it
    /// cancels outside the lock, the teardown it may await, and the generation
    /// it closes with `finishDisconnect`.
    private struct DisconnectHandoff: Sendable {
        var maintenanceTask: Task<Void, Never>?
        var postConnectTask: Task<Void, Never>?
        var teardown: Task<Void, Never>
        var generation: UInt64
    }

    private let state = NIOLockedValueBox(State())

    private var rtcClient: any KeepTalkingTransportClient { client.rtcClient }
    private var config: KeepTalkingConfig { client.config }

    init(client: KeepTalkingClient) {
        self.client = client
        self.signals = client.signals
    }

    // MARK: - Transport binding

    /// Installs the transport callbacks. Each one takes a lifecycle snapshot
    /// synchronously and re-checks it inside the task it spawns, so a
    /// callback that fires during teardown is dropped instead of acting on a
    /// stale generation.
    func bindTransport() {
        let rtcClient = client.rtcClient
        rtcClient.contextSecretProvider = { [weak client] contextID in
            try await client?.loadGroupChatSecret(for: contextID)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            guard let self, let generation = self.connectionLifecycleSnapshot(),
                self.isConnectionLifecycleActive(generation)
            else { return }
            self.client.rawMessages.send(raw)
        }
        rtcClient.onBlobData = { [weak self] data in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                do {
                    try await self.client.blobFrameProcessor.process {
                        guard self.isConnectionLifecycleActive(generation) else { return }
                        try await self.client.handleIncomingBlobFrameData(data)
                    }
                } catch {
                    self.client.onLog?(
                        "[client/blob] failed handling blob frame error=\(error.localizedDescription)"
                    )
                }
            }
        }
        rtcClient.onRealtimeData = { [weak self] data in
            guard let self, let generation = self.connectionLifecycleSnapshot(),
                self.isConnectionLifecycleActive(generation)
            else { return }
            _ = self.client.activeVoiceSession?.receiveRelayedFrame(data)
        }
        rtcClient.onEnvelope = { [weak self] envelope in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                do {
                    try await self.client.handleIncomingEnvelope(envelope)
                } catch {
                    self.client.onLog?(
                        "[client] failed handling envelope error=\(error.localizedDescription)"
                    )
                }
            }
        }
        rtcClient.onTrustEnvelope = { [weak self] envelope in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.client.handleIncomingTrustEnvelope(envelope)
            }
        }
        rtcClient.onPeerConnect = { [weak self] nodeID in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            self.notePeerOnline(nodeID)
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.client.handlePeerConnect(
                    nodeID: nodeID,
                    generation: generation
                )
            }
        }
        rtcClient.onBroadcastReady = { [weak self] in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.client.drainOutbox()
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.client.dispatchMaintenance(
                    .heartbeat,
                    generation: generation
                )
            }
        }
        rtcClient.onTransportStateChange = { [weak self] state, route in
            self?.noteTransportState(state, route: route)
        }
    }

    // MARK: - Lifecycle state machine

    private func pendingTeardownSnapshot() -> Task<Void, Never>? {
        state.withLockedValue { $0.pendingTeardown }
    }

    private func beginConnect() -> UInt64? {
        state.withLockedValue { reserveConnect(&$0) }
    }

    /// Reserves the next generation for a connect, or returns nil when one is
    /// already in flight, live, or tearing down.
    private func reserveConnect(_ state: inout State) -> UInt64? {
        guard state.activeConnectGeneration == nil, !state.isConnected, !state.isDisconnecting
        else { return nil }
        state.generation &+= 1
        state.activeConnectGeneration = state.generation
        state.lastBroadcastState = .connecting
        state.lastRoute = .sfu
        publishLifecycle(state, .connecting, cause: .connectRequested)
        return state.generation
    }

    private func ensureCurrentConnect(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard state.withLockedValue({ $0.isCurrentConnect(generation) }) else {
            throw CancellationError()
        }
    }

    private func prepareTransportStart(_ generation: UInt64) throws -> Task<Void, Error> {
        try state.withLockedValue { state in
            guard state.isCurrentConnect(generation) else { throw CancellationError() }
            return try rtcClient.start()
        }
    }

    private func cancelConnect(_ generation: UInt64, error: any Error) {
        state.withLockedValue { state in
            guard state.isCurrentConnect(generation) else { return }
            state.activeConnectGeneration = nil
            publishLifecycle(state, .idle, cause: .connectFailed(error.localizedDescription))
        }
    }

    func isConnectionActive(_ generation: UInt64) -> Bool {
        state.withLockedValue { $0.generation == generation && $0.isConnected }
    }

    private func connectionLifecycleSnapshot() -> UInt64? {
        state.withLockedValue { $0.isLive ? $0.generation : nil }
    }

    func isConnectionLifecycleActive(_ generation: UInt64) -> Bool {
        state.withLockedValue { $0.isLifecycleActive(generation) }
    }

    private func commitConnect(
        _ generation: UInt64,
        transport: BroadcastChannelState,
        route: KeepTalkingTransportRoute
    ) -> Bool {
        state.withLockedValue { state in
            guard state.isCurrentConnect(generation) else { return false }

            state.activeConnectGeneration = nil
            state.isConnected = true
            state.lastBroadcastState = transport
            state.lastRoute = route
            state.maintenanceTask?.cancel()
            state.maintenanceTask = client.makeMaintenanceTask(generation: generation)
            state.postConnectTask?.cancel()
            state.postConnectTask = makePostConnectTask(generation: generation)
            state.presenceSweepTask?.cancel()
            state.presenceSweepTask = makePresenceSweepTask(generation: generation)
            state.statsSamplerTask?.cancel()
            state.statsSamplerTask = makeStatsSamplerTask(generation: generation)
            publishLifecycle(state, .connected, cause: .connected)
            return true
        }
    }

    private func beginDisconnect(
        ifConnecting expectedGeneration: UInt64? = nil,
        terminal: KeepTalkingClientLifecycle.Cause
    ) -> DisconnectHandoff? {
        state.withLockedValue {
            reserveDisconnect(&$0, ifConnecting: expectedGeneration, terminal: terminal)
        }
    }

    /// Moves to the next generation, detaches the transport stop, and hands the
    /// cancellable tasks back to the caller. With `ifConnecting` set it only
    /// acts on that exact in-flight connect and returns nil otherwise.
    private func reserveDisconnect(
        _ state: inout State,
        ifConnecting expectedGeneration: UInt64?,
        terminal: KeepTalkingClientLifecycle.Cause
    ) -> DisconnectHandoff? {
        if let expectedGeneration, !state.isCurrentConnect(expectedGeneration) {
            return nil
        }
        state.generation &+= 1
        let generation = state.generation
        state.activeConnectGeneration = nil
        state.isConnected = false
        state.isDisconnecting = true
        let maintenance = state.maintenanceTask
        let postConnect = state.postConnectTask
        state.maintenanceTask = nil
        state.postConnectTask = nil
        state.presenceSweepTask?.cancel()
        state.presenceSweepTask = nil
        state.statsSamplerTask?.cancel()
        state.statsSamplerTask = nil
        state.terminalCause = terminal

        let previous = state.pendingTeardown
        let rtc = rtcClient
        let teardown = Task.detached(priority: .userInitiated) { [weak self] in
            if let previous { await previous.value }
            rtc.stop()
            self?.completeTeardown(generation: generation)
        }
        state.pendingTeardown = teardown
        // Only a live connection has something to announce: a redundant
        // `disconnect()` on an idle client bumps the generation and schedules
        // another stop exactly as before, but stays silent.
        switch lifecycle.current.phase {
            case .connecting, .connected:
                publishLifecycle(
                    state,
                    .disconnecting,
                    cause: terminal == .tornDown ? .disconnectRequested : terminal
                )
            case .idle, .disconnecting:
                break
        }
        if !presence.current.onlineNodeIDs.isEmpty {
            presence.send(.init(onlineNodeIDs: [], change: .reset))
        }
        return DisconnectHandoff(
            maintenanceTask: maintenance,
            postConnectTask: postConnect,
            teardown: teardown,
            generation: generation
        )
    }

    /// A teardown and the next connect reserved as ONE transition, for
    /// `reestablishTransport()`: the old teardown always finds a newer
    /// generation, so a bounce can never publish `idle` — even when the
    /// transport stops faster than the connect could reserve on its own.
    private func beginReconnect() -> (
        maintenance: Task<Void, Never>?, postConnect: Task<Void, Never>?, generation: UInt64
    ) {
        state.withLockedValue { state in
            guard let torn = reserveDisconnect(&state, ifConnecting: nil, terminal: .tornDown)
            else {
                preconditionFailure("an unconditional teardown cannot be refused")
            }
            state.isDisconnecting = false
            guard let generation = reserveConnect(&state) else {
                preconditionFailure("a connect cannot be refused right after a teardown")
            }
            return (torn.maintenanceTask, torn.postConnectTask, generation)
        }
    }

    private func finishDisconnect(_ generation: UInt64) {
        state.withLockedValue { state in
            if state.generation == generation { state.isDisconnecting = false }
        }
    }

    /// Tail of the detached teardown: the transport has stopped. Publishes
    /// `.idle` unless a newer generation already superseded this teardown —
    /// which is exactly what `reestablishTransport()` does, so a bounce reads
    /// `connected → disconnecting → connecting → connected` with no `idle`.
    private func completeTeardown(generation: UInt64) {
        state.withLockedValue { state in
            guard state.generation == generation,
                lifecycle.current.phase == .disconnecting
            else { return }
            publishLifecycle(state, .idle, cause: state.terminalCause)
        }
    }

    /// Emits a lifecycle value from a locked `State`. Delivery is
    /// asynchronous, so emitting under the lock is safe.
    private func publishLifecycle(
        _ state: State,
        _ phase: KeepTalkingClientLifecycle.Phase,
        cause: KeepTalkingClientLifecycle.Cause
    ) {
        let live = phase == .connecting || phase == .connected
        lifecycle.send(
            .init(
                phase: phase,
                generation: state.generation,
                transport: live ? .init(state.lastBroadcastState) : .down,
                route: live ? state.lastRoute : .sfu,
                cause: cause
            )
        )
    }

    private func noteTransportState(
        _ transport: BroadcastChannelState,
        route: KeepTalkingTransportRoute
    ) {
        state.withLockedValue { state in
            guard state.isLive else { return }
            state.lastBroadcastState = transport
            state.lastRoute = route
            // Only a live connection republishes: while connecting, the
            // backbone's intermediate states are the connect's own business
            // and `connected` carries the live reading at commit.
            let current = lifecycle.current
            guard current.phase == .connected else { return }
            let health = KeepTalkingClient.TransportHealth(transport)
            guard health != current.transport || route != current.route else { return }
            publishLifecycle(state, .connected, cause: .transportChanged)
        }
    }

    // MARK: - Connect / disconnect

    /// Starts transports and persists local node state.
    func connect() async throws {
        try Task.checkCancellation()
        guard let generation = beginConnect() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try await performConnect(generation)
    }

    /// The connect sequence for an already reserved generation.
    private func performConnect(_ generation: UInt64) async throws {
        var transportStarted = false
        do {
            // Ensure any in-flight teardown from a previous disconnect() completes
            // before bringing the transport back up.
            if let teardown = pendingTeardownSnapshot() {
                await teardown.value
            }
            try ensureCurrentConnect(generation)

            await client.mcpManager.setHTTPAuthURLHandler(client.mcpHTTPAuthURLHandler)
            #if os(macOS)
            await client.acpManager.setAuthHandler(client.acpAuthHandler)
            #endif
            try ensureCurrentConnect(generation)
            _ = try await client.ensure(config.contextID, for: KeepTalkingContext.self)
            try ensureCurrentConnect(generation)

            client.openContextSyncRequests(generation: generation)
            let startTask = try prepareTransportStart(generation)
            transportStarted = true
            try await startTask.waitPropagatingCancellation()
            try ensureCurrentConnect(generation)
            try await client.persistMyNode()
            try ensureCurrentConnect(generation)

            // Read outside the lock so the commit never re-enters the transport.
            let transport = rtcClient.broadcastState()
            let route = rtcClient.currentRoute()
            guard commitConnect(generation, transport: transport, route: route) else {
                throw CancellationError()
            }
        } catch {
            if transportStarted,
                let teardown = scheduleDisconnect(
                    ifConnecting: generation,
                    terminal: .connectFailed(error.localizedDescription)
                )
            {
                await teardown.value
            } else {
                client.failAllPendingContextSync(
                    error: KeepTalkingClientError.clientDisconnected
                )
                cancelConnect(generation, error: error)
            }
            throw error
        }
    }

    /// Stops transports and fails any pending remote requests.
    ///
    /// Lightweight bookkeeping (failing pending continuations, cancelling
    /// debounce tasks) runs synchronously. The WebRTC teardown is dispatched
    /// to a detached task because `peer.close()` synchronously joins WebRTC
    /// worker threads — calling it from MainActor would freeze the UI for
    /// hundreds of milliseconds. A subsequent `connect()` will await the
    /// in-flight teardown before restarting the transport.
    func disconnect() {
        _ = scheduleDisconnect()
    }

    private func scheduleDisconnect(
        ifConnecting generation: UInt64? = nil,
        terminal: KeepTalkingClientLifecycle.Cause = .tornDown
    ) -> Task<Void, Never>? {
        guard let handoff = beginDisconnect(ifConnecting: generation, terminal: terminal) else {
            return nil
        }
        defer { finishDisconnect(handoff.generation) }
        handoff.maintenanceTask?.cancel()
        handoff.postConnectTask?.cancel()
        client.failAllPendingActionCalls(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingActionCatalogRequests(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingContextSync(error: KeepTalkingClientError.clientDisconnected)
        return handoff.teardown
    }

    /// Awaitable variant of `disconnect()` that returns once the WebRTC
    /// transport has fully torn down.
    func disconnectAndWait() async {
        if let teardown = scheduleDisconnect() { await teardown.value }
    }

    /// Tears the transport down and brings it back up **on this same client
    /// instance**. Unlike the app dropping and rebuilding a `KeepTalkingClient`,
    /// this preserves every object that captured the client — most importantly
    /// an `activeVoiceSession`, whose send closures route through
    /// `rtcClient`. The voice session keeps running across the bounce; its
    /// heartbeat re-announces over the freshly-started transport.
    ///
    /// `connect()` awaits the detached teardown `disconnect()` schedules, so
    /// the stop fully completes before the restart.
    func reestablishTransport() async throws {
        client.debug("reestablishTransport: bouncing transport in place")
        let (maintenance, postConnect, generation) = beginReconnect()
        maintenance?.cancel()
        postConnect?.cancel()
        client.failAllPendingActionCalls(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingActionCatalogRequests(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingContextSync(error: KeepTalkingClientError.clientDisconnected)
        try await performConnect(generation)
    }

    // MARK: - Transport health

    /// Reads `TransportHealth` from the transport's current broadcast state.
    /// Pure read, no I/O.
    func transportHealth() -> KeepTalkingClient.TransportHealth {
        .init(rtcClient.broadcastState())
    }

    /// Actively confirms a `.healthy` backbone is really carrying bytes, not
    /// wedged open (e.g. the keepalive task starved across a long suspend).
    ///
    /// Sends one presence wave plus a native SFU roster request, then watches
    /// the transport's inbound counter for progress within `timeout`. Any
    /// inbound byte — a presence echo, roster reply, or peer's traffic —
    /// counts. Returns `true` if inbound advanced (live), `false` on timeout
    /// (wedged → caller should re-establish).
    ///
    /// Only worth calling when `transportHealth() == .healthy`: `.recovering`
    /// already self-heals and `.down` is unambiguous.
    func probeTransport(timeout: Duration) async -> Bool {
        let before = rtcClient.runtimeStats().received
        rtcClient.sendLivenessProbe()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if rtcClient.runtimeStats().received > before {
                return true
            }
        }
        return false
    }

    // MARK: - Presence

    // Presence is a read-modify-write on the `presence` signal. It keeps no
    // field of its own in `State`; it takes the same lock so a sweep, a
    // peer-connect edge and a teardown reset never interleave.

    /// The peer-connect edge from the transport, recorded before the
    /// node-online maintenance runs.
    private func notePeerOnline(_ nodeID: UUID) {
        guard nodeID != config.node else { return }
        state.withLockedValue { _ in
            var online = presence.current.onlineNodeIDs
            guard online.insert(nodeID).inserted else { return }
            presence.send(.init(onlineNodeIDs: online, change: .online(nodeID)))
        }
    }

    /// Reconciles `presence` with the liveness window: one `.offline` per peer
    /// that aged out, one `.online` per peer seen without an edge. Runs every
    /// `presenceSweepSeconds` while connected and on every node-online
    /// maintenance pass; `now` is injectable for tests.
    func sweepPresence(now: Date = Date()) {
        let live = client.livenessState.onlineNodeIDs(now: now).subtracting([config.node])
        state.withLockedValue { _ in
            var online = presence.current.onlineNodeIDs
            for departed in online.subtracting(live).sorted(by: { $0.uuidString < $1.uuidString }) {
                online.remove(departed)
                presence.send(.init(onlineNodeIDs: online, change: .offline(departed)))
            }
            for arrived in live.subtracting(online).sorted(by: { $0.uuidString < $1.uuidString }) {
                online.insert(arrived)
                presence.send(.init(onlineNodeIDs: online, change: .online(arrived)))
            }
        }
    }

    private func makePresenceSweepTask(generation: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.presenceSweepSeconds))
                guard !Task.isCancelled, let self, self.isConnectionActive(generation)
                else { break }
                self.sweepPresence()
            }
        }
    }

    // MARK: - Post-connect work

    private func makePostConnectTask(generation: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, self.isConnectionActive(generation) else { return }

            let client = self.client
            await client.dispatchMaintenance(
                .connected,
                generation: generation
            )
            guard !Task.isCancelled,
                self.isConnectionActive(generation),
                client.kvService != nil
            else { return }
            do {
                try await client.registerCurrentNodeID()
            } catch {
                guard !Task.isCancelled else { return }
                client.debug("[kv] KV registration failed: \(error)")
            }
        }
    }

    // MARK: - Transport stats

    private func makeStatsSamplerTask(generation: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.statsSampleSeconds))
                guard !Task.isCancelled, let self, self.isConnectionActive(generation)
                else { break }
                self.transportStats.send(ifChanged: self.rtcClient.runtimeStats())
            }
        }
    }
}
