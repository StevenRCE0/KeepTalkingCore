import Foundation
import NIOConcurrencyHelpers

/// The client's connection lifecycle, carved out of `KeepTalkingClient`.
///
/// The transport is process-wide (``KeepTalkingTransport``) and outlives the
/// client. Connecting **attaches** this client's context to it as a room;
/// disconnecting **detaches**. Nothing here starts, stops or restarts a
/// transport, and detaching is cheap, so teardown is synchronous.
///
/// The connection owns:
/// - the generation-tracked connect/disconnect state machine;
/// - the room's attachment and its events;
/// - the client-side liveness the transport knows nothing about: the
///   presence heartbeat, reachability edges, and the resync each edge runs;
/// - the three state signals derived from all of it: `lifecycle`, `presence`
///   and `transportStats`.
///
/// The state machine is a lock, not an actor, on purpose: an actor would make
/// `disconnect()` async (the app and CLI call it synchronously) and put an
/// executor hop in the realtime voice-datagram path. Everything the lock
/// guards lives in `State`, which is only reachable inside `withLockedValue`;
/// a helper that needs the lock held takes `inout State`, so "lock held" is
/// enforced by the type rather than a comment.
final class KeepTalkingClientConnection: Sendable {
    unowned let client: KeepTalkingClient
    // Held strongly, not reached through `client`: a signal box outliving
    // the client is harmless; an unowned hop through a dead client is a
    // crash.
    private let signals: KeepTalkingClientSignals

    var lifecycle: KeepTalkingStateSignal<KeepTalkingClientLifecycle> { signals.lifecycle }
    var presence: KeepTalkingStateSignal<KeepTalkingClientPresence> { signals.presence }
    var transportStats: KeepTalkingStateSignal<KeepTalkingRuntimeStats> { signals.transportStats }

    private static let presenceSweepSeconds: TimeInterval = 10
    private static let statsSampleSeconds: TimeInterval = 1
    /// The KeepTalking heartbeat: how often we tell the room we're here. It's
    /// what members on the SFU, who have no link to us, see us by.
    private static let presenceHeartbeatSeconds: TimeInterval = 13

    /// Everything the lifecycle lock guards.
    private struct State: Sendable {
        var generation: UInt64 = 0
        var activeConnectGeneration: UInt64?
        var isConnected = false
        /// The room on the process-wide transport, from attach to detach.
        var attachment: (any KeepTalkingTransportAttachment)?
        /// Last status the attachment reported, folded into `lifecycle`.
        var status: KeepTalkingTransportStatus = .offline
        /// The periodic maintenance heartbeat (ContextMaintenance
        /// `.heartbeat`). Started on connect, cancelled on disconnect.
        var maintenanceTask: Task<Void, Never>?
        /// Ancillary work that starts once connected. It must not keep
        /// `connect()` — and so the app's connection UI — pending.
        var postConnectTask: Task<Void, Never>?
        var presenceHeartbeatTask: Task<Void, Never>?
        var presenceSweepTask: Task<Void, Never>?
        var statsSamplerTask: Task<Void, Never>?

        /// `generation` is the connect currently being brought up.
        func isCurrentConnect(_ generation: UInt64) -> Bool {
            self.generation == generation && activeConnectGeneration == generation
        }

        /// Connecting or connected.
        var isLive: Bool {
            activeConnectGeneration == generation || isConnected
        }

        func isLifecycleActive(_ generation: UInt64) -> Bool {
            self.generation == generation && isLive
        }

        /// Hands back every task to cancel and forgets them.
        mutating func takeTasks() -> [Task<Void, Never>] {
            defer {
                maintenanceTask = nil
                postConnectTask = nil
                presenceHeartbeatTask = nil
                presenceSweepTask = nil
                statsSamplerTask = nil
            }
            return [maintenanceTask, postConnectTask, presenceHeartbeatTask, presenceSweepTask, statsSamplerTask]
                .compactMap { $0 }
        }
    }

    private let state = NIOLockedValueBox(State())

    private var config: KeepTalkingConfig { client.config }

    init(client: KeepTalkingClient) {
        self.client = client
        self.signals = client.signals
    }

    // MARK: - Sending

    /// The room's attachment, while connecting or connected.
    private func attachment() throws -> any KeepTalkingTransportAttachment {
        guard let attachment = state.withLockedValue({ $0.attachment }) else {
            throw client.transport.isAvailable
                ? KeepTalkingTransportError.notAttached
                : KeepTalkingTransportError.unavailable
        }
        return attachment
    }

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        try attachment().send(envelope)
    }

    func sendDatagram(_ datagram: Data) throws {
        try attachment().sendDatagram(datagram)
    }

    func openBlobStream(to node: UUID, header: Data) async throws -> any KeepTalkingBlobStreamWriter {
        try await attachment().openBlobStream(to: node, header: header)
    }

    func expectBlobStream(from node: UUID) {
        try? attachment().expectBlobStream(from: node)
    }

    /// The room's status now; `.offline` when not attached.
    func transportStatus() -> KeepTalkingTransportStatus {
        (try? attachment().status()) ?? .offline
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        (try? attachment().stats()) ?? .zero
    }

    // MARK: - Transport events

    /// Events from one attachment, tagged with the generation that attached
    /// it: anything from a superseded attachment is dropped.
    private func handle(_ event: KeepTalkingTransportEvent, generation: UInt64) {
        guard isConnectionLifecycleActive(generation) else {
            if case .blobStream(let reader, _) = event { reader.cancel() }
            return
        }
        switch event {
            case .envelope(let envelope, let from):
                if let from { noteReachable(from, generation: generation) }
                if let presence = envelope as? KeepTalkingP2PPresencePayload {
                    noteReachable(presence.node, generation: generation, viaPresence: true)
                }
                Task {
                    guard self.isConnectionLifecycleActive(generation) else { return }
                    await self.client.handleTransportEnvelope(envelope)
                }
            case .datagram(let datagram):
                _ = client.activeVoiceSession?.receiveDatagram(datagram)
            case .blobStream(let reader, let from):
                noteReachable(from, generation: generation)
                Task {
                    guard self.isConnectionLifecycleActive(generation) else {
                        reader.cancel()
                        return
                    }
                    await self.client.handleIncomingBlobStream(reader, from: from)
                }
            case .peerConnected(let node):
                noteReachable(node, generation: generation)
            case .peerRerouted(let node):
                // Whatever went into the old link may be gone: resync even
                // when liveness never saw the node leave.
                guard node != config.node else { return }
                notePeerOnline(node)
                Task {
                    guard self.isConnectionLifecycleActive(generation) else { return }
                    await self.client.handlePeerConnect(nodeID: node, generation: generation)
                }
            case .readyToSend:
                sendPresenceHeartbeat()
                Task {
                    guard self.isConnectionLifecycleActive(generation) else { return }
                    await self.client.drainOutbox()
                }
            case .statusChanged(let status):
                noteTransportStatus(status)
            case .log(let line):
                client.onLog?(line)
        }
    }

    /// Feeds liveness with traffic from `node`. On an offline→online edge it
    /// records presence, echoes ours, and runs the node-online resync, plus
    /// the discovery a presence envelope gets (unless that's what we're
    /// handling).
    private func noteReachable(_ node: UUID, generation: UInt64, viaPresence: Bool = false) {
        guard node != config.node else { return }
        let observation = client.livenessState.observePresence(from: node, echoCooldown: 1)
        if observation.shouldEcho { sendPresenceHeartbeat() }
        guard observation.isNewConnection else { return }
        client.debug("peer \(node.uuidString.prefix(8)) reachable")
        notePeerOnline(node)
        Task {
            guard self.isConnectionLifecycleActive(generation) else { return }
            if !viaPresence {
                try? await self.client.handleIncomingEnvelope(KeepTalkingP2PPresencePayload(node: node))
            }
            await self.client.handlePeerConnect(nodeID: node, generation: generation)
        }
    }

    private func sendPresenceHeartbeat() {
        try? send(KeepTalkingP2PPresencePayload(node: config.node))
    }

    // MARK: - Lifecycle state machine

    /// Reserves the next generation for a connect, or returns nil when one is
    /// already in flight or live.
    private func reserveConnect(_ state: inout State) -> UInt64? {
        guard state.activeConnectGeneration == nil, !state.isConnected else { return nil }
        state.generation &+= 1
        state.activeConnectGeneration = state.generation
        state.status = KeepTalkingTransportStatus(state: .connecting, path: nil)
        publishLifecycle(state, .connecting, cause: .connectRequested)
        return state.generation
    }

    private func ensureCurrentConnect(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard state.withLockedValue({ $0.isCurrentConnect(generation) }) else {
            throw CancellationError()
        }
    }

    func isConnectionActive(_ generation: UInt64) -> Bool {
        state.withLockedValue { $0.generation == generation && $0.isConnected }
    }

    func isConnectionLifecycleActive(_ generation: UInt64) -> Bool {
        state.withLockedValue { $0.isLifecycleActive(generation) }
    }

    /// Keeps the attachment if `generation` is still the connect in flight;
    /// otherwise the caller detaches it.
    private func install(
        _ attachment: any KeepTalkingTransportAttachment,
        generation: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard state.isCurrentConnect(generation) else { return false }
            state.attachment = attachment
            return true
        }
    }

    private func commitConnect(_ generation: UInt64) -> Bool {
        // Read outside the lock: the status reads the transport.
        let status = transportStatus()
        return state.withLockedValue { state in
            guard state.isCurrentConnect(generation) else { return false }
            state.activeConnectGeneration = nil
            state.isConnected = true
            state.status = status
            state.maintenanceTask = client.makeMaintenanceTask(generation: generation)
            state.postConnectTask = makePostConnectTask(generation: generation)
            state.presenceHeartbeatTask = makePresenceHeartbeatTask(generation: generation)
            state.presenceSweepTask = makePresenceSweepTask(generation: generation)
            state.statsSamplerTask = makeStatsSamplerTask(generation: generation)
            publishLifecycle(state, .connected, cause: .connected)
            return true
        }
    }

    /// Ends the current generation: hands back the attachment and tasks to
    /// release outside the lock. Nil when there's nothing live to end.
    private func reserveDisconnect(
        _ state: inout State,
        ifConnecting expectedGeneration: UInt64?,
        cause: KeepTalkingClientLifecycle.Cause
    ) -> (attachment: (any KeepTalkingTransportAttachment)?, tasks: [Task<Void, Never>])? {
        if let expectedGeneration {
            guard state.isCurrentConnect(expectedGeneration) else { return nil }
        } else {
            guard state.isLive else { return nil }
        }
        state.generation &+= 1
        state.activeConnectGeneration = nil
        state.isConnected = false
        state.status = .offline
        defer { state.attachment = nil }
        publishLifecycle(state, .disconnecting, cause: cause)
        return (state.attachment, state.takeTasks())
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
                transport: live ? state.status : .offline,
                cause: cause
            )
        )
    }

    private func noteTransportStatus(_ status: KeepTalkingTransportStatus) {
        state.withLockedValue { state in
            guard state.isLive, state.status != status else { return }
            state.status = status
            // While connecting, the status is the connect's own business and
            // `connected` carries the live reading at commit.
            guard lifecycle.current.phase == .connected else { return }
            publishLifecycle(state, .connected, cause: .transportChanged)
        }
    }

    // MARK: - Connect / disconnect

    /// Attaches the context to the process-wide transport and persists local
    /// node state.
    func connect() async throws {
        try Task.checkCancellation()
        guard client.transport.isAvailable else { throw KeepTalkingTransportError.unavailable }
        guard let generation = state.withLockedValue({ reserveConnect(&$0) }) else {
            throw KeepTalkingClientError.alreadyConnected
        }
        try await performConnect(generation)
    }

    /// The connect sequence for an already reserved generation.
    private func performConnect(_ generation: UInt64) async throws {
        do {
            guard let multiplexer = client.transport.multiplexer else {
                throw KeepTalkingTransportError.unavailable
            }
            await client.mcpManager.setHTTPAuthURLHandler(client.mcpHTTPAuthURLHandler)
            #if os(macOS)
            await client.acpManager.setAuthHandler(client.acpAuthHandler)
            #endif
            try ensureCurrentConnect(generation)
            _ = try await client.ensure(config.contextID, for: KeepTalkingContext.self)
            let secret = try await client.ensureGroupChatSecret(for: config.contextID)
            try ensureCurrentConnect(generation)

            client.openContextSyncRequests(generation: generation)
            let attachment = try await multiplexer.attach(
                KeepTalkingTransportRoom(contextID: config.contextID, nodeID: config.node, secret: secret),
                events: { [weak self] event in self?.handle(event, generation: generation) }
            )
            guard install(attachment, generation: generation) else {
                attachment.detach()
                throw CancellationError()
            }
            try await client.persistMyNode()
            guard commitConnect(generation) else { throw CancellationError() }
        } catch {
            endConnection(ifConnecting: generation, cause: .connectFailed(error.localizedDescription))
            throw error
        }
    }

    /// Detaches the context and fails any pending remote requests. Cheap and
    /// synchronous: the shared transport stays up for every other context.
    func disconnect() {
        endConnection(ifConnecting: nil, cause: .disconnectRequested)
    }

    /// Ends the live generation (or, with `ifConnecting`, only that connect
    /// in flight): detaches, cancels the connection's tasks, fails pending
    /// requests, and reads `disconnecting → idle`.
    private func endConnection(ifConnecting generation: UInt64?, cause: KeepTalkingClientLifecycle.Cause) {
        let reserved = state.withLockedValue {
            reserveDisconnect(&$0, ifConnecting: generation, cause: cause)
        }
        guard let reserved else { return }
        let (attachment, tasks) = reserved
        tasks.forEach { $0.cancel() }
        attachment?.detach()
        failPendingRequests()
        // The next connect then sees every peer come online again, which is
        // what drives the resync after a reconnect.
        client.livenessState.reset()
        state.withLockedValue { state in
            publishLifecycle(state, .idle, cause: cause == .disconnectRequested ? .tornDown : cause)
            if !presence.current.onlineNodeIDs.isEmpty {
                presence.send(.init(onlineNodeIDs: [], change: .reset))
            }
        }
        transportStats.send(ifChanged: .zero)
    }

    private func failPendingRequests() {
        client.failAllPendingActionCalls(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingActionCatalogRequests(error: KeepTalkingClientError.clientDisconnected)
        client.failAllPendingContextSync(error: KeepTalkingClientError.clientDisconnected)
    }

    /// Moves a live client to a new room: the context's secret changed (a
    /// join replaced it), and the secret addresses the room. Detach and
    /// attach again on the same client, so nothing that captured it is lost.
    func reattachIfConnected() async throws {
        let reserved = state.withLockedValue {
            state -> (UInt64, (any KeepTalkingTransportAttachment)?, [Task<Void, Never>])? in
            guard state.isConnected else { return nil }
            defer { state.attachment = nil }
            state.isConnected = false
            state.generation &+= 1
            state.activeConnectGeneration = state.generation
            state.status = KeepTalkingTransportStatus(state: .connecting, path: nil)
            publishLifecycle(state, .connecting, cause: .connectRequested)
            return (state.generation, state.attachment, state.takeTasks())
        }
        guard let reserved else { return }
        let (generation, attachment, tasks) = reserved
        tasks.forEach { $0.cancel() }
        // Outside our lock: a detach can report to other rooms' clients.
        attachment?.detach()
        failPendingRequests()
        client.livenessState.reset()
        try await performConnect(generation)
    }

    // MARK: - Presence

    // Presence is a read-modify-write on the `presence` signal. It keeps no
    // field of its own in `State`; it takes the same lock so a sweep, a
    // reachability edge and a reset never interleave.

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

    // MARK: - Connected tasks

    private func makeRepeatingTask(
        generation: UInt64,
        every seconds: TimeInterval,
        _ body: @escaping @Sendable (KeepTalkingClientConnection) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.isConnectionActive(generation) else { break }
                await body(self)
            }
        }
    }

    private func makePresenceHeartbeatTask(generation: UInt64) -> Task<Void, Never> {
        makeRepeatingTask(generation: generation, every: Self.presenceHeartbeatSeconds) {
            $0.sendPresenceHeartbeat()
        }
    }

    private func makePresenceSweepTask(generation: UInt64) -> Task<Void, Never> {
        makeRepeatingTask(generation: generation, every: Self.presenceSweepSeconds) { $0.sweepPresence() }
    }

    private func makeStatsSamplerTask(generation: UInt64) -> Task<Void, Never> {
        makeRepeatingTask(generation: generation, every: Self.statsSampleSeconds) {
            $0.transportStats.send(ifChanged: $0.runtimeStats())
        }
    }

    private func makePostConnectTask(generation: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, self.isConnectionActive(generation) else { return }
            let client = self.client
            self.sendPresenceHeartbeat()
            await client.dispatchMaintenance(.connected, generation: generation)
            guard !Task.isCancelled, self.isConnectionActive(generation), client.kvService != nil
            else { return }
            do {
                try await client.registerCurrentNodeID()
            } catch {
                guard !Task.isCancelled else { return }
                client.debug("[kv] KV registration failed: \(error)")
            }
        }
    }
}
