#if canImport(IrohLib)
import Foundation
import NIOConcurrencyHelpers

/// One context's view of a shared `KeepTalkingIrohTransportHost`, shaped as
/// the `KeepTalkingTransportClient` a `KeepTalkingClient` already speaks.
///
/// Mapping onto the old two-route model:
/// - **Broadcast** fans out to every connected member (there is no server
///   path for payloads any more); a directed envelope goes to its target
///   when that peer is connected, otherwise to everyone as before.
/// - **Backbone state** is the hub session, but a context with a connected
///   member counts as ready even while the hub reconnects.
/// - **Route** is `.p2p` when some member talks over a direct path, `.sfu`
///   while everything rides the relay.
/// - **Liveness** feeds the client's `KeepTalkingContextLivenessState` from
///   link-up events, inbound frames and a 13 s heartbeat over connected
///   members, so `onPeerConnect` fires on real edges.
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
                    return "No group secret for context \(context); cannot seal presence."
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
            // Check-and-attach under our lock so a concurrent stop() either
            // runs first (we bail) or after (it detaches what we attached).
            try state.withLockedValue { state in
                guard state.isActive, state.generation == generation else {
                    throw CancellationError()
                }
                try host.attach(self, contextID: contextID, nodeID: nodeID, secret: secret)
                state.heartbeat = Task { [weak self] in await self?.heartbeatLoop(generation) }
            }
            debug("attached to iroh host")
            reportState()
        }
    }

    func stop() {
        let heartbeat = state.withLockedValue { state -> Task<Void, Never>? in
            state.generation &+= 1
            state.isActive = false
            host.detach(contextID: contextID)
            defer { state.heartbeat = nil }
            return state.heartbeat
        }
        heartbeat?.cancel()
        debug("detached from iroh host")
    }

    private var isActive: Bool { state.withLockedValue { $0.isActive } }

    private func heartbeatLoop(_ generation: UInt64) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
            guard state.withLockedValue({ $0.isActive && $0.generation == generation }) else { return }
            for node in host.connectedMemberNodes(of: contextID) {
                observe(node)
            }
        }
    }

    // MARK: - Sending

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        guard isActive else { throw TransportError.notStarted }
        let payload = try KeepTalkingPacketTransportCrypto.outboundPayload(
            for: envelope,
            localNodeID: nodeID,
            contextSecretProvider: contextSecretProvider
        )
        try host.send(.envelope, context: contextID, payload: payload, to: envelope.targetPeerNodeID)
        state.withLockedValue { $0.sent += 1 }
    }

    func sendBlobData(_ data: Data, targetPeerNodeID: UUID?) throws {
        guard isActive else { throw TransportError.notStarted }
        try host.send(.blob, context: contextID, payload: data, to: targetPeerNodeID)
        state.withLockedValue { $0.sent += 1 }
    }

    func sendBlobDataViaBroadcast(_ data: Data) throws {
        try sendBlobData(data, targetPeerNodeID: nil)
    }

    func sendRealtimeDataViaBroadcast(_ data: Data) throws {
        guard isActive else { throw TransportError.notStarted }
        try host.sendDatagram(context: contextID, payload: data)
    }

    // MARK: - State reads

    func currentRoute() -> KeepTalkingTransportRoute {
        host.hasDirectMember(in: contextID) ? .p2p : .sfu
    }

    func broadcastState() -> BroadcastChannelState {
        if !host.connectedMemberNodes(of: contextID).isEmpty { return .ready }
        return host.hubChannelState()
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let (sent, received) = state.withLockedValue { ($0.sent, $0.received) }
        let isOpen = broadcastState() == .ready
        return KeepTalkingRuntimeStats(
            sent: sent,
            received: received,
            outboundLabel: "iroh",
            outboundState: isOpen ? 1 : 0,
            inboundLabel: "iroh",
            inboundState: isOpen ? 1 : 0,
            retainedChannels: host.connectedMemberNodes(of: contextID).count,
            route: currentRoute().rawValue
        )
    }

    /// Pings every connected member; pongs advance `received`, which is what
    /// `KeepTalkingClient.probeTransport()` watches.
    func sendLivenessProbe() {
        _ = try? host.send(.ping, context: contextID, payload: Data(), to: nil)
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
        onBroadcastReady?()
        reportState()
    }

    func hubStateChanged() {
        reportState()
    }

    func peerLinkUp(_ node: UUID) {
        guard isActive else { return }
        observe(node)
        // A new member is reachable: let the outbox drain to it.
        onBroadcastReady?()
        reportState()
    }

    func peerLinkDown(_ node: UUID) {
        debug("link to \(node.uuidString.prefix(8)) down")
        reportState()
    }

    func memberLeft(_ node: UUID) {
        debug("member \(node.uuidString.prefix(8)) left")
        reportState()
    }

    func routeMayHaveChanged() {
        reportState()
    }

    func peerHeard(_ node: UUID) {
        guard isActive else { return }
        state.withLockedValue { $0.received += 1 }
        observe(node)
    }

    func deliver(_ kind: KeepTalkingIrohTransportHost.FrameKind, payload: Data, from node: UUID) {
        guard isActive else { return }
        state.withLockedValue { $0.received += 1 }
        observe(node)
        switch kind {
            case .blob:
                onBlobData?(payload)
            case .envelope:
                deliverEnvelope(payload, from: node)
            case .ping, .pong:
                break
        }
    }

    func deliverRealtime(_ payload: Data, from node: UUID) {
        guard isActive else { return }
        onRealtimeData?(payload)
    }

    private func deliverEnvelope(_ payload: Data, from node: UUID) {
        let envelope: (any KeepTalkingEnvelope)?
        do {
            envelope = try KeepTalkingPacketTransportCrypto.inboundEnvelope(
                from: payload,
                contextSecretProvider: contextSecretProvider
            )
        } catch {
            debug("undecodable envelope from \(node.uuidString.prefix(8)): \(error.localizedDescription)")
            return
        }
        guard let envelope else { return }
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
    /// client the way `ContextTransport` does — a connect callback plus the
    /// presence envelope its node handlers turn into discovery.
    private func observe(_ node: UUID) {
        guard node != nodeID, let liveness = state.withLockedValue({ $0.liveness }) else { return }
        let observation = liveness.observePresence(from: node, echoCooldown: 1)
        guard observation.isNewConnection else { return }
        debug("peer \(node.uuidString.prefix(8)) reachable")
        onPeerConnect?(node)
        onEnvelope?(KeepTalkingP2PPresencePayload(node: node))
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
