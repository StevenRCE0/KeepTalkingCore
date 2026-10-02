#if canImport(IrohLib)
import Foundation
import NIOConcurrencyHelpers

/// One context's view of a shared `KeepTalkingIrohTransportHost`, shaped as
/// the `KeepTalkingTransportClient` a `KeepTalkingClient` already speaks.
///
/// - **Topic** — the context publishes to its topic (derived from the
///   secret). Every payload is sealed with the topic's key: envelopes as a
///   `KeepTalkingEnvelopePacket`, blob frames as-is. No context or sender id
///   travels in the clear.
/// - **Delivery** — the host picks hub or mesh per publish; a directed
///   envelope goes straight to its target when that member is connected.
///   Inbound frames arrive from either route and are accepted if they open.
/// - **Backbone state** — the hub session, but a context with a connected
///   member counts as ready while the hub reconnects.
/// - **Route** — `.p2p` when some member talks over a direct path, `.sfu`
///   while everything rides the relay or the hub.
/// - **Liveness** — the KeepTalking heartbeat (`p2pPresence`) is published
///   to the topic every 13 s, as the old backbone did; inbound heartbeats
///   and link-up events feed the client's `KeepTalkingContextLivenessState`,
///   so `onPeerConnect` fires on real edges whichever route carried them.
final class KeepTalkingIrohContextTransport: KeepTalkingTransportClient,
    KeepTalkingLivenessBindableTransport, @unchecked Sendable
{
    enum TransportError: LocalizedError {
        case notStarted
        case missingContextSecret(UUID)

        var errorDescription: String? {
            switch self {
                case .notStarted: return "The iroh context transport is not started."
                case .missingContextSecret(let context):
                    return "No group secret for context \(context); cannot derive its topic."
            }
        }
    }

    private static let heartbeatSeconds = 13

    private struct Callbacks {
        var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
        var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
        var onBlobData: KeepTalkingTransportBlobDataHandler?
        var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
        var onRawMessage: (@Sendable (String) -> Void)?
        var onPeerConnect: (@Sendable (UUID) -> Void)?
        var onBroadcastReady: (@Sendable () -> Void)?
        var onTransportStateChange: (@Sendable (BroadcastChannelState, KeepTalkingTransportRoute) -> Void)?
        var onLog: (@Sendable (String) -> Void)?
        var contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    }

    private struct State {
        var generation: UInt64 = 0
        var isActive = false
        var topic: KeepTalkingIrohTopic?
        var liveness: KeepTalkingContextLivenessState?
        var heartbeat: Task<Void, Never>?
        var sent = 0
        var received = 0
        var lastReported: (BroadcastChannelState, KeepTalkingTransportRoute)?
    }

    let host: KeepTalkingIrohTransportHost
    let contextID: UUID
    let nodeID: UUID
    private let callbacks = NIOLockedValueBox(Callbacks())
    private let state = NIOLockedValueBox(State())

    init(host: KeepTalkingIrohTransportHost, contextID: UUID, nodeID: UUID) {
        self.host = host
        self.contextID = contextID
        self.nodeID = nodeID
    }

    // MARK: - Callbacks

    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)? {
        get { callbacks.withLockedValue { $0.onEnvelope } }
        set { callbacks.withLockedValue { $0.onEnvelope = newValue } }
    }
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)? {
        get { callbacks.withLockedValue { $0.onTrustEnvelope } }
        set { callbacks.withLockedValue { $0.onTrustEnvelope = newValue } }
    }
    var onBlobData: KeepTalkingTransportBlobDataHandler? {
        get { callbacks.withLockedValue { $0.onBlobData } }
        set { callbacks.withLockedValue { $0.onBlobData = newValue } }
    }
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler? {
        get { callbacks.withLockedValue { $0.onRealtimeData } }
        set { callbacks.withLockedValue { $0.onRealtimeData = newValue } }
    }
    var onRawMessage: (@Sendable (String) -> Void)? {
        get { callbacks.withLockedValue { $0.onRawMessage } }
        set { callbacks.withLockedValue { $0.onRawMessage = newValue } }
    }
    var onPeerConnect: (@Sendable (UUID) -> Void)? {
        get { callbacks.withLockedValue { $0.onPeerConnect } }
        set { callbacks.withLockedValue { $0.onPeerConnect = newValue } }
    }
    var onBroadcastReady: (@Sendable () -> Void)? {
        get { callbacks.withLockedValue { $0.onBroadcastReady } }
        set { callbacks.withLockedValue { $0.onBroadcastReady = newValue } }
    }
    var onTransportStateChange: (@Sendable (BroadcastChannelState, KeepTalkingTransportRoute) -> Void)? {
        get { callbacks.withLockedValue { $0.onTransportStateChange } }
        set { callbacks.withLockedValue { $0.onTransportStateChange = newValue } }
    }
    var onLog: (@Sendable (String) -> Void)? {
        get { callbacks.withLockedValue { $0.onLog } }
        set { callbacks.withLockedValue { $0.onLog = newValue } }
    }
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? {
        get { callbacks.withLockedValue { $0.contextSecretProvider } }
        set { callbacks.withLockedValue { $0.contextSecretProvider = newValue } }
    }

    func bindLiveness(_ liveness: KeepTalkingContextLivenessState) {
        state.withLockedValue { $0.liveness = liveness }
    }

    // MARK: - Lifecycle

    func start() throws -> Task<Void, Error> {
        let generation = state.withLockedValue { state -> UInt64 in
            state.generation &+= 1
            state.isActive = true
            return state.generation
        }
        return Task {
            try await host.start()
            guard
                let provider = contextSecretProvider,
                let secret = try await provider(contextID)
            else { throw TransportError.missingContextSecret(contextID) }
            let topic = KeepTalkingIrohTopic(contextID: contextID, secret: secret)
            // Check-and-attach under our lock so a concurrent stop() either
            // runs first (we bail) or after (it detaches what we attached).
            try state.withLockedValue { state in
                guard state.isActive, state.generation == generation else {
                    throw CancellationError()
                }
                try host.attach(self, topic: topic, nodeID: nodeID, secret: secret)
                state.topic = topic
                state.heartbeat = Task { [weak self] in await self?.heartbeatLoop(generation) }
            }
            debug("attached to iroh host on topic \(KeepTalkingIrohTransportHost.hex(topic.topic).prefix(10))")
            reportState()
        }
    }

    func stop() {
        let heartbeat = state.withLockedValue { state -> Task<Void, Never>? in
            state.generation &+= 1
            state.isActive = false
            if let topic = state.topic { host.detach(topic: topic.topic) }
            state.topic = nil
            defer { state.heartbeat = nil }
            return state.heartbeat
        }
        heartbeat?.cancel()
        debug("detached from iroh host")
    }

    private var activeTopic: KeepTalkingIrohTopic? {
        state.withLockedValue { $0.isActive ? $0.topic : nil }
    }

    /// The KeepTalking heartbeat, published to the topic like the old
    /// backbone's; it's what tells hub-only peers we're here.
    private func heartbeatLoop(_ generation: UInt64) async {
        while !Task.isCancelled {
            guard state.withLockedValue({ $0.isActive && $0.generation == generation }) else { return }
            sendHeartbeat()
            try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
        }
    }

    private func sendHeartbeat() {
        try? sendEnvelope(KeepTalkingP2PPresencePayload(node: nodeID))
    }

    // MARK: - Sending

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        guard let topic = activeTopic else { throw TransportError.notStarted }
        let packet = try JSONEncoder().encode(KeepTalkingEnvelopePacket(envelope))
        try host.publish(
            .envelope,
            topic: topic.topic,
            payload: try topic.seal(packet),
            to: envelope.targetPeerNodeID
        )
        state.withLockedValue { $0.sent += 1 }
    }

    func sendBlobData(_ data: Data, targetPeerNodeID: UUID?) throws {
        guard let topic = activeTopic else { throw TransportError.notStarted }
        try host.publish(.blob, topic: topic.topic, payload: try topic.seal(data), to: targetPeerNodeID)
        state.withLockedValue { $0.sent += 1 }
    }

    func sendBlobDataViaBroadcast(_ data: Data) throws {
        try sendBlobData(data, targetPeerNodeID: nil)
    }

    /// Voice frames are already sealed with the call's key; they go out as
    /// datagrams through the hub or the mesh like any publish.
    func sendRealtimeDataViaBroadcast(_ data: Data) throws {
        guard let topic = activeTopic else { throw TransportError.notStarted }
        try host.sendDatagram(topic: topic.topic, payload: data)
    }

    // MARK: - State reads

    func currentRoute() -> KeepTalkingTransportRoute {
        guard let topic = activeTopic else { return .sfu }
        return host.hasDirectMember(in: topic.topic) ? .p2p : .sfu
    }

    func broadcastState() -> BroadcastChannelState {
        if let topic = activeTopic, !host.connectedMemberNodes(of: topic.topic).isEmpty { return .ready }
        return host.hubChannelState()
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let (sent, received) = state.withLockedValue { ($0.sent, $0.received) }
        let isOpen = activeTopic.map { host.canDeliver(to: $0.topic) } ?? false
        return KeepTalkingRuntimeStats(
            sent: sent,
            received: received,
            outboundLabel: "iroh",
            outboundState: isOpen ? 1 : 0,
            inboundLabel: "iroh",
            inboundState: isOpen ? 1 : 0,
            retainedChannels: activeTopic.map { host.connectedMemberNodes(of: $0.topic).count } ?? 0,
            route: currentRoute().rawValue
        )
    }

    /// Pings the topic; pongs advance `received`, which is what
    /// `KeepTalkingClient.probeTransport()` watches.
    func sendLivenessProbe() {
        guard let topic = activeTopic else { return }
        _ = try? host.publish(.ping, topic: topic.topic, payload: Data(), to: nil)
    }

    /// Path upgrades are iroh's job; nothing to trial.
    func requestP2PTrial() {}

    func preferReliableRoute(reason: String) {
        debug("preferReliableRoute(\(reason)) ignored: iroh picks paths itself")
    }

    func debug(_ message: String) {
        onLog?("[iroh \(contextID.uuidString.prefix(8))] \(message)")
    }

    // MARK: - From the host

    func hubJoined() {
        debug("hub snapshot received")
        sendHeartbeat()
        onBroadcastReady?()
        reportState()
    }

    func hubStateChanged() {
        // A hub that came back can take what the outbox holds.
        if host.hubChannelState() == .ready { onBroadcastReady?() }
        reportState()
    }

    func peerLinkUp(_ node: UUID) {
        guard activeTopic != nil else { return }
        observe(node)
        // A new member is reachable directly: let the outbox drain to it.
        onBroadcastReady?()
        reportState()
    }

    func peerLinkDown(_ node: UUID) {
        debug("link to \(node.uuidString.prefix(8)) down")
        reportState()
    }

    /// The member's traffic moved to its other live link (network died
    /// under Bluetooth, or came back). Whatever went into the dying link is
    /// lost, so run the node-online resync over the new one even when
    /// liveness never saw the node go away.
    func peerRerouted(_ node: UUID) {
        guard activeTopic != nil, node != nodeID else { return }
        debug("route to \(node.uuidString.prefix(8)) changed: resyncing")
        if !observe(node) { onPeerConnect?(node) }
        reportState()
    }

    func memberLeft(_ node: UUID) {
        debug("member \(node.uuidString.prefix(8)) left")
        reportState()
    }

    func routeMayHaveChanged() {
        reportState()
    }

    func deliver(
        _ kind: KeepTalkingIrohTransportHost.FrameKind,
        payload: Data,
        from node: UUID?,
        route: KeepTalkingIrohTransportHost.Route
    ) {
        guard let topic = activeTopic else { return }
        switch kind {
            case .ping:
                state.withLockedValue { $0.received += 1 }
                _ = try? host.publish(.pong, topic: topic.topic, payload: Data(), to: node)
            case .pong:
                state.withLockedValue { $0.received += 1 }
                if let node { observe(node) }
            case .blob:
                guard let opened = topic.open(payload) else { return }
                state.withLockedValue { $0.received += 1 }
                if let node { observe(node) }
                onBlobData?(opened)
            case .envelope:
                guard let opened = topic.open(payload) else {
                    debug("unopenable envelope via \(route.rawValue)")
                    return
                }
                state.withLockedValue { $0.received += 1 }
                if let node { observe(node) }
                deliverEnvelope(opened)
        }
    }

    func deliverRealtime(_ payload: Data, from node: UUID?) {
        guard activeTopic != nil else { return }
        onRealtimeData?(payload)
    }

    private func deliverEnvelope(_ packet: Data) {
        guard
            let decoded = try? JSONDecoder().decode(KeepTalkingEnvelopePacket.self, from: packet)
        else {
            debug("undecodable envelope packet")
            return
        }
        let envelope = decoded.envelope
        if let inner = envelope.transportContextID, inner != contextID {
            debug("dropped envelope for another context")
            return
        }
        if let presence = envelope as? KeepTalkingP2PPresencePayload {
            observe(presence.node, announce: false)
        }
        guard envelope.channel == .signaling else {
            onEnvelope?(envelope)
            return
        }
        switch envelope.kind {
            case .trustRequest, .trustAccept, .trustComplete, .trustReject:
                onTrustEnvelope?(envelope)
            case .voiceCallStarted, .voiceCallEnded, .voiceCallSignal, .p2pPresence:
                onEnvelope?(envelope)
            default:
                // ICE signalling has no meaning on iroh.
                break
        }
    }

    /// Feeds the client's liveness state; on an offline→online edge tells the
    /// client the way `ContextTransport` does — a connect callback, plus the
    /// presence envelope its node handlers turn into discovery (unless that
    /// envelope is itself what we're handling). Returns whether it did.
    @discardableResult
    private func observe(_ node: UUID, announce: Bool = true) -> Bool {
        guard node != nodeID, let liveness = state.withLockedValue({ $0.liveness }) else { return false }
        let observation = liveness.observePresence(from: node, echoCooldown: 1)
        guard observation.isNewConnection else { return false }
        debug("peer \(node.uuidString.prefix(8)) reachable")
        onPeerConnect?(node)
        if announce { onEnvelope?(KeepTalkingP2PPresencePayload(node: node)) }
        return true
    }

    private func reportState() {
        let current = (broadcastState(), currentRoute())
        let changed = state.withLockedValue { state -> Bool in
            if let last = state.lastReported, last.0 == current.0, last.1 == current.1 { return false }
            state.lastReported = current
            return true
        }
        if changed { onTransportStateChange?(current.0, current.1) }
    }
}
#endif
