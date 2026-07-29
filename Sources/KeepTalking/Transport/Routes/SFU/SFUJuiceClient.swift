import Crypto
import Foundation
import KeepTalkingSFUClient
import KeepTalkingSFUProtocol

struct KeepTalkingSFUInboundEnvelope: Sendable {
    let bytes: Data
    let context: UUID?
    let sender: Data
    let channel: SFUChannel

    init(_ inbound: SFUClient.InboundEnvelope, bytes: Data) {
        self.bytes = bytes
        self.context = inbound.context
        self.sender = inbound.sender
        self.channel = inbound.channel
    }
}

/// `KeepTalkingTransportClient` over the Swift `KeepTalkingSFU` server.
/// Carries opaque, encrypted KT envelopes through `SFUClient`.
///
/// Phase-1 semantics:
///   * Single context membership = `config.contextID`.
///   * All outbound envelopes are broadcast to that context. Unicast can
///     be added once we wire the trust graph's node UUID → Ed25519 pubkey
///     lookup (right now the SFU peer-ID and KT node ID don't share a
///     namespace, so the cheapest correct path is "broadcast and let the
///     envelope's targetPeerNodeID filter at the destination").
///   * Inbound envelopes go through the same `KeepTalkingPacketTransport
///     Crypto.inboundEnvelope` path the existing routes use.
///   * Blob data is JSON-wrapped into the same opaque envelope stream;
///     a future iteration can use a separate context tag.
final class KeepTalkingSFUJuiceClient: KeepTalkingTransportClient, @unchecked Sendable {
    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onBroadcastReady: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onTransportDegraded: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let sfuHost: String
    private let sfuPort: UInt16
    private let signingKey: Curve25519.Signing.PrivateKey
    private let client: SFUClient
    private let contextJoinTimeout: Duration
    private let stopBeforeStartIsTerminal: Bool

    /// 32-byte Ed25519 public key registered with the SFU; surfaced so
    /// the public `KeepTalkingSFUJuiceSession` wrapper can expose it.
    var signingPublicKey: Data {
        signingKey.publicKey.rawRepresentation
    }

    /// Presence event forwarded by the SFU. Internal because the wire-
    /// type `SFUClient.PresenceEvent` is from a different module — the
    /// public `KeepTalkingSFUJuiceSession.PresenceEvent` mirrors it.
    enum PresenceEvent {
        case snapshot(context: UUID, peers: [Data])
        case joined(context: UUID, pubkey: Data)
        case left(context: UUID, pubkey: Data)
    }

    /// Set by the public session wrapper to receive presence events. The
    /// trampoline avoids leaking `SFUClient.PresenceEvent` through the
    /// SDK's public surface.
    var presenceForwarder: ((PresenceEvent) -> Void)?

    /// Channel-aware inbound forwarder. The protocol-level `onEnvelope`
    /// flattens to "decoded envelope or opaque bytes" and drops the
    /// sender/channel metadata; this forwarder surfaces those so the
    /// session can dispatch (e.g. route p2pSignal channel frames into
    /// the libjuice agent).
    var rawInboundForwarder: ((KeepTalkingSFUInboundEnvelope) -> Void)?

    /// Direct unicast: routes opaque bytes to a specific peer pubkey on
    /// a specific channel. Used by the session's
    /// `route(rawBytes:to:channel:)` so the lab can do ICE-over-SFU
    /// without going through the envelope-crypto path.
    func routeRawBytes(_ data: Data, to peer: Data, channel: SFUChannel) {
        client.route(envelope: data, to: peer, channel: channel)
    }

    /// Broadcast opaque bytes on a specific channel. Companion to
    /// `routeRawBytes`.
    func broadcastRawBytes(_ data: Data, channel: SFUChannel) {
        client.broadcast(envelope: data, context: config.contextID, channel: channel)
    }

    /// Asks the SFU for the current peer roster on the configured
    /// context. Response arrives asynchronously via `presenceForwarder`.
    func requestPeerRoster() {
        client.listPeers(context: config.contextID)
    }

    // MARK: - SFU relay

    /// Fires when a remote peer opens an SFU-mediated relay to us. The
    /// session-layer wrapper uses this to plumb a relay into a pending
    /// `KeepTalkingDirectChannel` for the originating peer.
    var onRelayOpen: ((_ relayID: Data, _ peer: Data, _ context: UUID) -> Void)?
    var onRelayData: ((_ relayID: Data, _ payload: Data) -> Void)?
    var onRelayClose: ((_ relayID: Data, _ reason: UInt8) -> Void)?

    @discardableResult
    func openRelay(to peer: Data) -> Data {
        client.openRelay(to: peer, context: config.contextID)
    }

    func sendRelayData(_ payload: Data, on relayID: Data) {
        client.sendRelayData(payload, on: relayID)
    }

    func closeRelay(_ relayID: Data, reason: UInt8 = SFURelayCloseReason.normal) {
        client.closeRelay(relayID, reason: reason)
    }

    private let stateQueue = DispatchQueue(label: "kt.transport.sfu-juice.state")
    private var sentCount = 0
    private var recvCount = 0
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var contextJoinTimeoutTask: Task<Void, Never>?
    private var startAttempt: UInt64 = 0
    private var activeStartAttempt: UInt64?
    private var readyStartAttempt: UInt64?
    private var clientOperationAttempt: UInt64?
    private var closeAfterClientOperation = false
    private var isContextReady = false
    private var isStopped = true
    private var hasStartedAttempt = false
    private var cancelledBeforeFirstStart = false

    init(
        config: KeepTalkingConfig,
        sfuHost: String,
        sfuPort: UInt16,
        signingKey: Curve25519.Signing.PrivateKey = .init(),
        contextJoinTimeout: Duration = .seconds(10),
        stopBeforeStartIsTerminal: Bool = false
    ) {
        self.config = config
        self.sfuHost = sfuHost
        self.sfuPort = sfuPort
        self.signingKey = signingKey
        self.contextJoinTimeout = contextJoinTimeout
        self.stopBeforeStartIsTerminal = stopBeforeStartIsTerminal
        self.client = SFUClient(
            configuration: .init(host: sfuHost, port: Int(sfuPort)),
            signingKey: signingKey
        )
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [sfu-juice] \(message)")
    }

    // MARK: - Lifecycle

    func start() throws -> Task<Void, Error> {
        let attempt = try reserveStartAttempt()
        return Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await self.start(reservedAttempt: attempt)
                try Task.checkCancellation()
            } onCancel: {
                self.failStart(
                    CancellationError(),
                    attempt: attempt,
                    closeConnection: true
                )
            }
        }
    }

    func reserveStartAttempt() throws -> UInt64 {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            throw CancellationError()
        }
        return try stateQueue.sync {
            if cancelledBeforeFirstStart { throw CancellationError() }
            guard activeStartAttempt == nil,
                clientOperationAttempt == nil,
                !isContextReady
            else {
                throw SFUJuiceError.startInProgress
            }
            hasStartedAttempt = true
            startAttempt &+= 1
            activeStartAttempt = startAttempt
            readyStartAttempt = nil
            closeAfterClientOperation = false
            isContextReady = false
            isStopped = false
            return startAttempt
        }
    }

    func start(reservedAttempt attempt: UInt64) async throws {
        guard stateQueue.sync(execute: { activeStartAttempt == attempt && !isStopped }) else {
            throw CancellationError()
        }
        debug("starting host=\(sfuHost):\(sfuPort) context=\(config.contextID.uuidString.lowercased())")

        client.onLog = { [weak self] msg in self?.debug(msg) }
        client.onState = { [weak self] state in
            self?.handleClientState(state)
        }
        client.onEnvelope = { [weak self] inbound in
            self?.handleInbound(inbound)
        }
        client.onRelayOpen = { [weak self] relayID, peer, ctx in
            self?.onRelayOpen?(relayID, peer, ctx)
        }
        client.onRelayData = { [weak self] relayID, payload in
            self?.onRelayData?(relayID, payload)
        }
        client.onRelayClose = { [weak self] relayID, reason in
            self?.onRelayClose?(relayID, reason)
        }
        client.onPresence = { [weak self] presence in self?.handlePresence(presence) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let shouldStart = stateQueue.sync {
                guard activeStartAttempt == attempt,
                    readyContinuation == nil,
                    clientOperationAttempt == nil,
                    !isStopped
                else { return false }
                readyContinuation = cont
                clientOperationAttempt = attempt
                return true
            }
            if shouldStart {
                scheduleContextJoinTimeout(attempt: attempt)
                client.connect()
                let shouldJoin = stateQueue.sync {
                    activeStartAttempt == attempt
                        && clientOperationAttempt == attempt
                        && !isStopped
                }
                if shouldJoin { client.join(context: config.contextID) }
                let shouldClose = stateQueue.sync {
                    guard clientOperationAttempt == attempt else { return false }
                    clientOperationAttempt = nil
                    let shouldClose =
                        closeAfterClientOperation
                        || isStopped
                        || (activeStartAttempt != attempt
                            && readyStartAttempt != attempt)
                    closeAfterClientOperation = false
                    return shouldClose
                }
                if shouldClose { client.close() }
            } else {
                cont.resume(throwing: CancellationError())
            }
        }
    }

    func stop() {
        let result = stateQueue.sync {
            () -> (
                continuation: CheckedContinuation<Void, Error>?,
                timeout: Task<Void, Never>?,
                counts: (Int, Int),
                shouldClose: Bool,
                didTransition: Bool
            ) in
            if stopBeforeStartIsTerminal, !hasStartedAttempt {
                cancelledBeforeFirstStart = true
            }
            let didTransition =
                !isStopped
                || activeStartAttempt != nil
                || readyContinuation != nil
                || clientOperationAttempt != nil
                || isContextReady
            let continuation = readyContinuation
            readyContinuation = nil
            let timeout = contextJoinTimeoutTask
            contextJoinTimeoutTask = nil
            activeStartAttempt = nil
            readyStartAttempt = nil
            isContextReady = false
            let shouldClose = !isStopped && clientOperationAttempt == nil
            if clientOperationAttempt != nil { closeAfterClientOperation = true }
            isStopped = true
            return (
                continuation,
                timeout,
                (sentCount, recvCount),
                shouldClose,
                didTransition
            )
        }
        result.timeout?.cancel()
        if result.didTransition {
            debug("stopping sent=\(result.counts.0) recv=\(result.counts.1)")
        }
        if result.shouldClose { client.close() }
        result.continuation?.resume(throwing: CancellationError())
    }

    // MARK: - Transport protocol

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        let payload =
            try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: config.node,
                contextSecretProvider: contextSecretProvider
            )
        client.broadcast(
            envelope: payload,
            context: config.contextID,
            channel: envelope.channel.sfuChannel
        )
        stateQueue.sync { sentCount += 1 }
    }

    func sendBlobData(_ data: Data, targetPeerNodeID: UUID?) throws {
        // Blob data is opaque to the SFU, but it must stay on the blob
        // channel so receivers dispatch it as media/blob bytes instead
        // of chat envelope traffic.
        client.broadcast(envelope: data, context: config.contextID, channel: .blob)
        stateQueue.sync { sentCount += 1 }
    }

    func sendRealtimeDataViaBroadcast(_ data: Data) throws {
        client.broadcast(envelope: data, context: config.contextID, channel: .realtime)
        stateQueue.sync { sentCount += 1 }
    }

    func currentRoute() -> KeepTalkingTransportRoute { .sfu }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let counts = stateQueue.sync { (sentCount, recvCount) }
        return KeepTalkingRuntimeStats(
            sent: counts.0,
            received: counts.1,
            outboundLabel: "sfu-juice/broadcast",
            outboundState: clientStateForStats(),
            inboundLabel: "sfu-juice/broadcast",
            inboundState: clientStateForStats(),
            retainedChannels: 1,
            route: "sfu-juice"
        )
    }

    func broadcastState() -> BroadcastChannelState {
        switch client.state {
            case .ready:
                return stateQueue.sync { isContextReady } ? .ready : .connecting
            case .connecting, .authenticating, .idle: return .connecting
            case .closed, .failed: return .failed
        }
    }

    func sendLivenessProbe() {
        // Roster request round-trips through the SFU server itself, so it
        // works even with no other peers present. The reply lands on the
        // counted inbound path observed by `probeTransport()`.
        requestPeerRoster()
    }

    func requestP2PTrial() {
        // No-op: this route never upgrades; if KT wants P2P, the SDK
        // should swap in the libjuice-based P2P client instead.
    }

    func preferReliableRoute(reason: String) {
        // No-op: SFU is the reliable route.
    }

    // MARK: - Internal

    private func clientStateForStats() -> Int {
        switch client.state {
            case .ready: return stateQueue.sync { isContextReady } ? 1 : 0
            case .connecting, .authenticating, .idle: return 0
            case .closed, .failed: return -1
        }
    }

    private func handleClientState(_ state: SFUClient.State) {
        debug("client state=\(state)")
        switch state {
            case .ready:
                debug("authenticated; awaiting context membership")
            case .failed(let reason):
                failStart(
                    SFUJuiceError.connectFailed(reason),
                    closeConnection: true
                )
                onTransportDegraded?(reason)
            case .closed:
                let closed = stateQueue.sync {
                    () -> (
                        continuation: CheckedContinuation<Void, Error>?,
                        timeout: Task<Void, Never>?,
                        wasReady: Bool
                    ) in
                    let result = (
                        continuation: readyContinuation,
                        timeout: contextJoinTimeoutTask,
                        wasReady: isContextReady
                    )
                    readyContinuation = nil
                    contextJoinTimeoutTask = nil
                    activeStartAttempt = nil
                    readyStartAttempt = nil
                    isContextReady = false
                    isStopped = true
                    return result
                }
                closed.timeout?.cancel()
                closed.continuation?.resume(
                    throwing: SFUJuiceError.connectFailed("connection closed")
                )
                if closed.wasReady {
                    onTransportDegraded?("SFU connection closed")
                }
            case .idle, .connecting, .authenticating:
                break
        }
    }

    private func handlePresence(_ presence: SFUClient.PresenceEvent) {
        stateQueue.sync { recvCount += 1 }

        let mapped: PresenceEvent
        switch presence {
            case .snapshot(let context, let peers):
                mapped = .snapshot(context: context, peers: peers)
            case .joined(let context, let pubkey):
                mapped = .joined(context: context, pubkey: pubkey)
            case .left(let context, let pubkey):
                mapped = .left(context: context, pubkey: pubkey)
        }
        if Self.confirmsContextMembership(
            mapped,
            contextID: config.contextID,
            publicKey: signingPublicKey
        ) {
            completeContextJoin()
        } else if Self.rejectsContextMembership(
            mapped,
            contextID: config.contextID,
            publicKey: signingPublicKey
        ) {
            let membershipWasReady = stateQueue.sync {
                defer {
                    isContextReady = false
                    readyStartAttempt = nil
                }
                return isContextReady
            }
            if membershipWasReady {
                onTransportDegraded?("SFU roster no longer contains this peer")
            }
        }
        presenceForwarder?(mapped)
    }

    static func confirmsContextMembership(
        _ presence: PresenceEvent,
        contextID: UUID,
        publicKey: Data
    ) -> Bool {
        guard case .snapshot(let context, let peers) = presence else { return false }
        return context == contextID && peers.contains(publicKey)
    }

    static func rejectsContextMembership(
        _ presence: PresenceEvent,
        contextID: UUID,
        publicKey: Data
    ) -> Bool {
        guard case .snapshot(let context, let peers) = presence else { return false }
        return context == contextID && !peers.contains(publicKey)
    }

    private func completeContextJoin() {
        let completion = stateQueue.sync {
            () -> (CheckedContinuation<Void, Error>, Task<Void, Never>?)? in
            guard activeStartAttempt != nil,
                let continuation = readyContinuation,
                !isStopped
            else {
                return nil
            }
            let attempt = activeStartAttempt
            readyContinuation = nil
            activeStartAttempt = nil
            readyStartAttempt = attempt
            isContextReady = true
            let timeout = contextJoinTimeoutTask
            contextJoinTimeoutTask = nil
            return (continuation, timeout)
        }
        guard let completion else { return }
        completion.1?.cancel()
        completion.0.resume()
        onBroadcastReady?()
    }

    @discardableResult
    private func failStart(
        _ error: Error,
        attempt: UInt64? = nil,
        closeConnection: Bool = false
    ) -> Bool {
        let completion = stateQueue.sync {
            () -> (
                continuation: CheckedContinuation<Void, Error>?,
                timeout: Task<Void, Never>?,
                shouldClose: Bool
            )? in
            if let attempt,
                activeStartAttempt != attempt,
                readyStartAttempt != attempt
            {
                return nil
            }
            guard
                activeStartAttempt != nil
                    || readyStartAttempt != nil
                    || readyContinuation != nil
            else {
                isContextReady = false
                return nil
            }
            let continuation = readyContinuation
            let timeout = contextJoinTimeoutTask
            readyContinuation = nil
            contextJoinTimeoutTask = nil
            activeStartAttempt = nil
            readyStartAttempt = nil
            isContextReady = false
            var shouldClose = false
            if closeConnection {
                shouldClose = !isStopped && clientOperationAttempt == nil
                if clientOperationAttempt != nil { closeAfterClientOperation = true }
                isStopped = true
            }
            return (continuation, timeout, shouldClose)
        }
        guard let completion else { return false }
        completion.timeout?.cancel()
        if completion.shouldClose { client.close() }
        completion.continuation?.resume(throwing: error)
        return true
    }

    private func scheduleContextJoinTimeout(attempt: UInt64) {
        let timeout = contextJoinTimeout
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self else { return }
            self.failStart(
                SFUJuiceError.contextJoinTimedOut,
                attempt: attempt,
                closeConnection: true
            )
        }
        let retained = stateQueue.sync {
            guard activeStartAttempt == attempt else { return false }
            contextJoinTimeoutTask = task
            return true
        }
        if !retained { task.cancel() }
    }

    private func handleInbound(_ inbound: SFUClient.InboundEnvelope) {
        // Envelopes are never fragmented: an oversized one is rejected at send
        // time by `PacketTransportCrypto.assertFits`, so whatever arrives here
        // is one whole envelope.
        let logicalInbound = KeepTalkingSFUInboundEnvelope(
            inbound, bytes: inbound.bytes)
        rawInboundForwarder?(logicalInbound)
        handleInboundEnvelope(logicalInbound)
    }

    private func handleInboundEnvelope(_ inbound: KeepTalkingSFUInboundEnvelope) {
        stateQueue.sync { recvCount += 1 }
        if inbound.channel == .realtime {
            onRealtimeData?(inbound.bytes)
            return
        }
        do {
            if let envelope =
                try KeepTalkingPacketTransportCrypto
                .inboundEnvelope(
                    from: inbound.bytes,
                    contextSecretProvider: contextSecretProvider
                )
            {
                onEnvelope?(envelope)
                return
            }
        } catch {
            debug("envelope decode failed: \(error.localizedDescription)")
        }
        // Fall back to passing the bytes through the blob handler so
        // the caller can decide what to do.
        onBlobData?(inbound.bytes)
    }
}

enum SFUJuiceError: LocalizedError {
    case connectFailed(String)
    case contextJoinTimedOut
    case startInProgress

    var errorDescription: String? {
        switch self {
            case .connectFailed(let reason):
                return "KeepTalkingSFU connect failed: \(reason)"
            case .contextJoinTimedOut:
                return "KeepTalkingSFU context join timed out."
            case .startInProgress:
                return "KeepTalkingSFU is already starting."
        }
    }
}

extension KeepTalkingEnvelopeChannel {
    fileprivate var sfuChannel: SFUChannel {
        switch self {
            case .chat: return .chat
            case .blob: return .blob
            case .actionCall: return .actionCall
            case .signaling: return .signaling
        }
    }
}
