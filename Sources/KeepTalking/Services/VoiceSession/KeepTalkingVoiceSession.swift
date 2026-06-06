import Foundation

/// Group voice transport. **N-peer from the start.**
///
/// The session owns:
///   - the existing context transport for envelope I/O
///   - one `KeepTalkingJuiceP2PSession` per remote peer (in `.p2p`)
///   - a peer map keyed by node UUID
///
/// ### Passive handshake (envelope-driven)
///
/// Connection establishment is driven by **voice-call envelopes**, not
/// by raw SFU presence:
///
/// - `KeepTalkingVoiceCallStartedPayload` — broadcast on `start()` and
///   re-broadcast when a new peer is first observed. Doubles as "I'm
///   in the call" and "did you know I was here?"
/// - `KeepTalkingVoiceCallEndedPayload` — broadcast on `stop()`.
/// - `KeepTalkingVoiceCallSignalPayload` — directed; carries SDP.
///   Replaces the raw `.p2pSignal` channel used before.
///
/// Context presence is intentionally **ignored** for attach — it tells
/// us a peer is in the chat context, not that they intend to be on a
/// call. We only attach on receipt of a `started` envelope.
///
/// ### Audio
///
/// Audio still rides as raw frames — `broadcast(_:)` on `.p2p` goes
/// through libjuice datagrams, on `.sfu` through the SFU `.realtime`
/// channel. Frames are opaque `Data`; a future multimodal agent can
/// hook `onInboundFrame` and `broadcast(_:)` to get the same seam.
public final class KeepTalkingVoiceSession: @unchecked Sendable {
    /// User-selected transport strategy. See `EffectiveTransport` for
    /// the concrete leg after `.auto` resolves.
    public enum TransportMode: String, Sendable, CaseIterable {
        case p2p
        case sfu
        case auto
    }

    public enum EffectiveTransport: String, Sendable, Equatable {
        case p2p
        case sfu
    }

    public enum PeerState: Sendable, Equatable {
        case discovering
        case iceGathering
        case iceConnected(local: String, remote: String)
        case sfuRelay
        case failed(String)
    }

    public struct Peer: Sendable, Equatable {
        public let nodeID: UUID
        public let state: PeerState
    }

    public typealias LogHandler = @Sendable (String) -> Void
    public typealias FrameHandler = @Sendable (Data, _ from: UUID) -> Void
    public typealias PeersChangedHandler = @Sendable ([Peer]) -> Void
    public typealias StoppedHandler = @Sendable () -> Void

    public var onLog: LogHandler?
    public var onInboundFrame: FrameHandler?
    public var onPeersChanged: PeersChangedHandler?
    /// Fires once when the session transitions running → stopped. The client wires
    /// this to drop its `activeVoiceSession` reference so "are we in a call?" stays
    /// accurate after teardown.
    public var onStopped: StoppedHandler?

    public private(set) var mode: TransportMode
    public let maxP2PMeshSize: Int
    public private(set) var effectiveTransport: EffectiveTransport
    public private(set) var autoStickySFU: Bool = false
    public let localNodeID: UUID
    public private(set) var isRunning: Bool = false

    public var peers: [Peer] {
        lock.withLock {
            peerEntries.values.map {
                Peer(nodeID: $0.nodeID, state: $0.state)
            }
        }
    }

    private let config: KeepTalkingConfig
    private let sendEnvelope: @Sendable (any KeepTalkingEnvelope) throws -> Void
    private let sendBlobData: @Sendable (Data, UUID?) throws -> Void
    private let lock = NSLock()
    private var peerEntries: [UUID: PeerEntry] = [:]
    /// When non-nil, all outbound audio frames are AES-GCM sealed with this
    /// secret and inbound frames are expected to be sealed likewise. Frames
    /// that fail decryption are silently dropped.
    private let frameSecret: Data?
    private var outboundFrameCounter: UInt64 = 0

    /// Heartbeat interval — re-broadcasts `voice.started` and checks
    /// peer freshness. Voice is real-time, so we run much tighter than
    /// the transport's 13 s chat presence wave.
    private static let heartbeatIntervalSeconds: TimeInterval = 2
    /// A peer that hasn't echoed `voice.started` within this many ticks
    /// is evicted. 3 ticks × 2 s = 6 s of silence before cleanup.
    private static let peerStaleTicksThreshold: Int = 3

    private var heartbeatTask: Task<Void, Never>?

    private final class PeerEntry {
        let nodeID: UUID
        var state: KeepTalkingVoiceSession.PeerState
        var ice: KeepTalkingJuiceP2PSession?
        var iceLocalSDPSent: Bool = false
        var iceDidConnect: Bool = false
        /// Ticks since the last `voice.started` from this peer. Reset to
        /// 0 on every inbound `started`; incremented each heartbeat tick.
        var ticksSinceLastSeen: Int = 0
        init(nodeID: UUID, state: KeepTalkingVoiceSession.PeerState) {
            self.nodeID = nodeID
            self.state = state
        }
    }

    public init(
        config: KeepTalkingConfig,
        sendEnvelope: @escaping @Sendable (any KeepTalkingEnvelope) throws -> Void,
        sendBlobData: @escaping @Sendable (Data, UUID?) throws -> Void,
        mode: TransportMode = .auto,
        maxP2PMeshSize: Int = 4,
        frameSecret: Data? = nil
    ) {
        self.config = config
        self.sendEnvelope = sendEnvelope
        self.sendBlobData = sendBlobData
        self.mode = mode
        self.maxP2PMeshSize = max(1, maxP2PMeshSize)
        self.effectiveTransport = (mode == .sfu) ? .sfu : .p2p
        self.localNodeID = config.node
        self.frameSecret = frameSecret
    }

    // MARK: - Shared session id

    /// The shared voice-session id every participant converges on — the key for
    /// the federated transcript (in-memory call record + lines). Each node mints a
    /// candidate and converges to the global minimum by adopting any lower id it
    /// sees on a peer's `started`. Settles within the opening `started` exchange,
    /// well before the first (endpointed) transcript line.
    private var _sessionID = UUID()
    public var sessionID: UUID { lock.withLock { _sessionID } }

    /// Adopt `candidate` if it's lower than ours, and re-announce so peers
    /// converge. Lowering-only ⇒ terminates at the global minimum.
    private func adoptSessionIDIfLower(_ candidate: UUID) {
        let changed: Bool = lock.withLock {
            guard candidate.uuidString < _sessionID.uuidString else { return false }
            _sessionID = candidate
            return true
        }
        guard changed else { return }
        emitLog("adopted lower sessionID=\(candidate.uuidString.prefix(8))")
        broadcastStarted()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        emitLog("starting context voice session context=\(config.contextID.uuidString.prefix(8))")
        broadcastStarted()
        startHeartbeat()
    }

    public func stop() {
        let wasRunning = isRunning
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Send the goodbye *before* we tear down the SFU socket —
        // otherwise the envelope never makes it out and peers will hold
        // a stale entry until their own timeouts/SFU-presence fire.
        if isRunning {
            broadcastEnded()
        }
        let snapshot = lock.withLock { () -> [PeerEntry] in
            let entries = Array(peerEntries.values)
            peerEntries.removeAll()
            return entries
        }
        for entry in snapshot {
            entry.ice?.onState = nil
            entry.ice?.onMessage = nil
            entry.ice?.onLog = nil
            entry.ice?.close()
        }
        isRunning = false
        autoStickySFU = false
        effectiveTransport = (mode == .sfu) ? .sfu : .p2p
        emitPeersChanged()
        emitLog("stopped")
        // Let the client drop its `activeVoiceSession` so it no longer believes
        // it's in the call (otherwise it keeps re-asserting presence on peers'
        // leaves and nothing ever seals). Only on a real running → stopped edge.
        if wasRunning { onStopped?() }
    }

    public func setMode(_ newMode: TransportMode) {
        guard newMode != mode else { return }
        mode = newMode
        if !isRunning {
            effectiveTransport = (newMode == .sfu) ? .sfu : .p2p
            autoStickySFU = false
        }
        emitLog("mode -> \(newMode.rawValue) (effective on next start)")
    }

    // MARK: - Broadcast

    public func broadcast(_ payload: Data) {
        let transport = effectiveTransport
        let snapshot = lock.withLock { Array(peerEntries.values) }
        let wire = sealFrame(payload)
        switch transport {
            case .p2p:
                for entry in snapshot {
                    guard entry.iceDidConnect, let ice = entry.ice else { continue }
                    do { try ice.send(wire) } catch {}
                }
            case .sfu:
                guard !snapshot.isEmpty else { return }
                try? sendBlobData(Self.encodeSFUFrame(wire, from: localNodeID, to: nil), nil)
        }
    }

    /// Address one participant explicitly. The agent integration uses
    /// this when it wants to whisper to a single listener.
    public func send(_ payload: Data, to nodeID: UUID) {
        let entry = lock.withLock { peerEntries[nodeID] }
        guard let entry else { return }
        let wire = sealFrame(payload)
        switch effectiveTransport {
            case .p2p:
                try? entry.ice?.send(wire)
            case .sfu:
                try? sendBlobData(Self.encodeSFUFrame(wire, from: localNodeID, to: nodeID), nodeID)
        }
    }

    /// Handles an inbound voice frame carried on the shared SFU
    /// `.realtime` channel. Returns `false` for non-voice realtime data
    /// so future realtime frame types can share the same transport.
    @discardableResult
    func receiveRelayedFrame(_ data: Data) -> Bool {
        guard let frame = Self.decodeSFUFrame(data) else { return false }
        guard frame.target == nil || frame.target == localNodeID else { return true }
        guard frame.sender != localNodeID else { return true }
        if lock.withLock({ peerEntries[frame.sender] == nil }) {
            handlePeerStarted(nodeID: frame.sender, remoteTransport: .sfu)
        }
        guard let plaintext = openFrame(frame.payload) else { return true }
        onInboundFrame?(plaintext, frame.sender)
        return true
    }

    // MARK: - Envelope outbound

    private func broadcastStarted() {
        let payload = KeepTalkingVoiceCallStartedPayload(
            from: localNodeID,
            contextID: config.contextID,
            effectiveTransport: effectiveTransport.rawValue,
            sessionID: sessionID
        )
        do {
            try sendEnvelope(payload)
            emitLog("→ voice.started")
        } catch {
            emitLog("send voice.started failed: \(error.localizedDescription)")
        }
    }

    private func broadcastEnded() {
        let payload = KeepTalkingVoiceCallEndedPayload(
            from: localNodeID,
            contextID: config.contextID,
            sessionID: sessionID
        )
        try? sendEnvelope(payload)
        emitLog("→ voice.ended session=\(sessionID.uuidString.prefix(8))")
    }

    private func sendSignal(sdp: String, to nodeID: UUID) {
        let payload = KeepTalkingVoiceCallSignalPayload(
            from: localNodeID,
            to: nodeID,
            contextID: config.contextID,
            sdp: sdp,
            sessionID: sessionID
        )
        do {
            try sendEnvelope(payload)
            emitLog("→ voice.signal to=\(nodeID.uuidString.prefix(8)) sdp=\(sdp.utf8.count)B")
        } catch {
            emitLog("send voice.signal failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Envelope inbound

    public func receiveVoiceEnvelope(_ envelope: any KeepTalkingEnvelope) {
        guard isRunning else { return }
        handleVoiceEnvelope(envelope)
    }

    private func handleVoiceEnvelope(_ envelope: any KeepTalkingEnvelope) {
        // Filter to our own context. The SFU shouldn't deliver others,
        // but a bug there would silently route foreign callers to us.
        if let envelopeContext = envelope.transportContextID,
            envelopeContext != config.contextID
        {
            return
        }
        switch envelope {
            case let started as KeepTalkingVoiceCallStartedPayload:
                if let peerSession = started.sessionID {
                    adoptSessionIDIfLower(peerSession)
                }
                handlePeerStarted(
                    nodeID: started.from,
                    remoteTransport: EffectiveTransport(rawValue: started.effectiveTransport ?? "")
                )
            case let ended as KeepTalkingVoiceCallEndedPayload:
                handlePeerEnded(nodeID: ended.from)
            case let signal as KeepTalkingVoiceCallSignalPayload where signal.to == localNodeID:
                handlePeerSignal(
                    nodeID: signal.from,
                    sdp: signal.sdp
                )
            default:
                break
        }
    }

    // MARK: - Per-peer state machine

    private enum StartedDisposition {
        case fresh  // brand-new peer, or a dead one we just replaced
        case kept  // live/in-flight connection — `started` is an echo
    }

    private func handlePeerStarted(nodeID: UUID, remoteTransport: EffectiveTransport? = nil) {
        guard nodeID != localNodeID else { return }
        evaluateAutoMeshCap(forIncomingNodeID: nodeID)
        // SFU wins. If the remote announced it's relaying through the SFU
        // while we're still trying P2P, ICE between us can never complete:
        // the SFU side drops our SDP signals (it only relays). Converge the
        // whole session to SFU so the pairing can't half-open with one side
        // "live" on the relay and the other stuck "waiting for peer". The
        // decision is symmetric — the SFU side stays put, the P2P side moves
        // — so both independently arrive at SFU.
        if remoteTransport == .sfu, effectiveTransport == .p2p {
            convergeToSFU(reason: "peer \(nodeID.uuidString.prefix(8)) is on SFU relay")
        }
        // A peer that dropped without a clean `voiceCallEnded` leaves a
        // stale entry behind (failed ICE, or `.iceConnected` whose agent
        // has since closed). Treat a `started` on top of such an entry as
        // a re-join: tear the dead ICE down and rebuild, rather than
        // no-op'ing and stranding the peer forever.
        var staleICE: KeepTalkingJuiceP2PSession?
        let disposition: StartedDisposition = lock.withLock {
            if let existing = peerEntries[nodeID] {
                // Any voice.started — echo or not — proves the peer is
                // alive. Reset its freshness counter so the heartbeat
                // eviction clock restarts.
                existing.ticksSinceLastSeen = 0
                guard isReplaceable(existing) else { return .kept }
                staleICE = existing.ice
                existing.ice = nil
                existing.iceDidConnect = false
                existing.iceLocalSDPSent = false
                existing.state = effectiveTransport == .sfu ? .sfuRelay : .discovering
                return .fresh
            }
            let initial: PeerState = effectiveTransport == .sfu ? .sfuRelay : .discovering
            peerEntries[nodeID] = PeerEntry(nodeID: nodeID, state: initial)
            return .fresh
        }
        if let staleICE {
            staleICE.onState = nil
            staleICE.onMessage = nil
            staleICE.onLog = nil
            staleICE.close()
        }
        emitPeersChanged()
        emitLog("← voice.started from=\(nodeID.uuidString.prefix(8)) (\(disposition == .fresh ? "fresh" : "kept"))")
        guard disposition == .fresh else { return }
        // Re-announce so a peer who joined *after* our initial broadcast
        // learns we're here.
        broadcastStarted()
        switch effectiveTransport {
            case .p2p:
                if Self.localIsOfferer(localNodeID: localNodeID, peerNodeID: nodeID) {
                    startICE(for: nodeID, applyingRemoteFirst: nil)
                }
            // Answerer waits for the offer to arrive as a voice.signal.
            case .sfu:
                emitLog("peer \(nodeID.uuidString.prefix(8)) attached (sfu relay)")
        }
    }

    /// Whether a `started` from an already-known peer should rebuild the
    /// connection. Live and mid-handshake entries are left alone (the
    /// `started` is just the re-announce a peer fires when a third party
    /// joins); only dead ones are replaced.
    ///
    /// Stale SFU peers (where `voice.ended` was lost) are cleaned up by
    /// the transport's liveness system (`handlePeerOffline`), which
    /// removes the entry entirely — so by the time a rejoining peer's
    /// `voice.started` arrives, there's no entry to gate. This method
    /// only handles the echo-vs-dead distinction for entries that still
    /// exist.
    ///
    /// Must be called under `lock`.
    private func isReplaceable(_ entry: PeerEntry) -> Bool {
        switch entry.state {
            case .failed:
                return true
            case .sfuRelay:
                // SFU relay is stateless — no ICE to rebuild. If the
                // peer is here and not `.failed`, the relay works.
                return false
            case .iceConnected:
                return !entry.iceDidConnect
            case .discovering:
                return entry.ice == nil
            case .iceGathering:
                return false
        }
    }

    private func handlePeerEnded(nodeID: UUID) {
        let entry = lock.withLock { () -> PeerEntry? in
            peerEntries.removeValue(forKey: nodeID)
        }
        guard let entry else { return }
        entry.ice?.onState = nil
        entry.ice?.onMessage = nil
        entry.ice?.onLog = nil
        entry.ice?.close()
        emitLog("← voice.ended from=\(nodeID.uuidString.prefix(8))")
        emitPeersChanged()
    }

    private func handlePeerSignal(nodeID: UUID, sdp: String) {
        // SDP can arrive before a Started envelope from this peer in
        // theory — treat as implicit Started so we don't drop the SDP.
        if lock.withLock({ peerEntries[nodeID] == nil }) {
            handlePeerStarted(nodeID: nodeID)
        }
        guard effectiveTransport == .p2p else { return }
        // Drop a dead agent first: an offer that arrives ahead of the
        // re-`started` from a rejoining peer must rebuild, not apply SDP
        // to a closed session.
        var staleICE: KeepTalkingJuiceP2PSession?
        let existingICE = lock.withLock { () -> KeepTalkingJuiceP2PSession? in
            guard let entry = peerEntries[nodeID] else { return nil }
            if entry.ice != nil, isReplaceable(entry) {
                staleICE = entry.ice
                entry.ice = nil
                entry.iceDidConnect = false
                entry.iceLocalSDPSent = false
                entry.state = .discovering
                return nil
            }
            return entry.ice
        }
        if let staleICE {
            staleICE.onState = nil
            staleICE.onMessage = nil
            staleICE.onLog = nil
            staleICE.close()
            emitPeersChanged()
        }
        if existingICE == nil {
            // First SDP from this peer = offer. We're the answerer.
            startICE(for: nodeID, applyingRemoteFirst: sdp)
        } else {
            existingICE?.applyRemoteSDP(sdp)
        }
        emitLog("← voice.signal from=\(nodeID.uuidString.prefix(8)) sdp=\(sdp.utf8.count)B")
    }

    // MARK: - Auto mesh cap

    private func evaluateAutoMeshCap(forIncomingNodeID nodeID: UUID) {
        guard mode == .auto, !autoStickySFU else { return }
        let shouldUpgrade = lock.withLock { () -> Bool in
            let alreadyPresent = peerEntries[nodeID] != nil
            let projected = peerEntries.count + (alreadyPresent ? 0 : 1)
            return projected > maxP2PMeshSize
        }
        guard shouldUpgrade else { return }
        upgradeAutoToSFU(reason: "peer count would exceed maxP2PMeshSize=\(maxP2PMeshSize)")
    }

    private func upgradeAutoToSFU(reason: String) {
        let migrated = migrateToSFU()
        emitLog("auto: upgraded to SFU (\(reason)); \(migrated) peer\(migrated == 1 ? "" : "s") migrated")
        emitPeersChanged()
    }

    /// Forced convergence to SFU triggered by a transport-mode mismatch
    /// with a peer (see `handlePeerStarted`). Distinct from the auto-mesh
    /// upgrade: it can fire even when `mode` is explicitly `.p2p`, because
    /// a working relayed call beats a half-open P2P one. Sets the same
    /// sticky flag so we don't bounce back to P2P, and re-announces our
    /// new transport so a late-joining peer sees it.
    private func convergeToSFU(reason: String) {
        let migrated = migrateToSFU()
        emitLog("converged to SFU (\(reason)); \(migrated) peer\(migrated == 1 ? "" : "s") migrated")
        emitPeersChanged()
        // Re-announce so the now-current `effectiveTransport=sfu` reaches
        // peers; otherwise a third P2P peer joining later would also try
        // (and fail) ICE against us.
        broadcastStarted()
    }

    /// Shared teardown for both the auto-mesh upgrade and forced
    /// convergence: flips the session to SFU, marks every peer as a relay,
    /// and closes any live ICE agents. Returns the migrated peer count.
    private func migrateToSFU() -> Int {
        let entries = lock.withLock { () -> [PeerEntry] in
            autoStickySFU = true
            effectiveTransport = .sfu
            let snapshot = Array(peerEntries.values)
            for entry in snapshot {
                entry.iceDidConnect = false
                entry.iceLocalSDPSent = false
                entry.state = .sfuRelay
            }
            return snapshot
        }
        for entry in entries {
            if let ice = entry.ice {
                ice.onState = nil
                ice.onMessage = nil
                ice.onLog = nil
                ice.close()
                entry.ice = nil
            }
        }
        return entries.count
    }

    private static func localIsOfferer(localNodeID: UUID, peerNodeID: UUID) -> Bool {
        localNodeID.uuidString < peerNodeID.uuidString
    }

    // MARK: - ICE per peer

    private func startICE(for peerNodeID: UUID, applyingRemoteFirst remoteSDP: String?) {
        let entry = lock.withLock { peerEntries[peerNodeID] }
        guard let entry, entry.ice == nil else { return }
        do {
            let agent = try KeepTalkingJuiceP2PSession()
            let captured = peerNodeID
            agent.onLog = { [weak self] msg in
                self?.emitLog("[ice \(captured.uuidString.prefix(8))] \(msg)")
            }
            agent.onState = { [weak self] state in
                self?.handleICEState(state, for: captured)
            }
            agent.onMessage = { [weak self] data in
                guard let self, let plaintext = self.openFrame(data) else { return }
                self.onInboundFrame?(plaintext, captured)
            }
            agent.onLocalSDPReady = { [weak self] _ in
                self?.attemptSendLocalSDP(for: captured)
            }
            lock.withLock {
                entry.ice = agent
                entry.state = .iceGathering
            }
            emitPeersChanged()
            if let remoteSDP {
                agent.applyRemoteSDP(remoteSDP)
            }
            agent.start()
        } catch {
            lock.withLock {
                entry.state = .failed("ice init: \(error.localizedDescription)")
            }
            emitPeersChanged()
            emitLog("[ice \(peerNodeID.uuidString.prefix(8))] init failed: \(error.localizedDescription)")
        }
    }

    private func handleICEState(_ state: KeepTalkingJuiceP2PSession.State, for peerNodeID: UUID) {
        attemptSendLocalSDP(for: peerNodeID)
        switch state {
            case .connected:
                handleICEConnected(for: peerNodeID)
            case .failed(let reason):
                handleICEFailed(reason, for: peerNodeID)
            case .closed:
                lock.withLock {
                    peerEntries[peerNodeID]?.iceDidConnect = false
                }
            default:
                break
        }
    }

    private func handleICEFailed(_ reason: String, for peerNodeID: UUID) {
        if mode == .auto, effectiveTransport == .p2p {
            convergeToSFU(reason: "p2p failed for \(peerNodeID.uuidString.prefix(8)): \(reason)")
            return
        }
        lock.withLock {
            peerEntries[peerNodeID]?.state = .failed(reason)
        }
        emitPeersChanged()
    }

    private func handleICEConnected(for peerNodeID: UUID) {
        let (entry, pair): (PeerEntry?, (local: String, remote: String)?) = lock.withLock {
            let entry = peerEntries[peerNodeID]
            return (entry, entry?.ice?.selectedAddresses())
        }
        guard let entry, let pair else { return }
        lock.withLock {
            entry.iceDidConnect = true
            entry.state = .iceConnected(local: pair.local, remote: pair.remote)
        }
        emitPeersChanged()
        emitLog("[ice \(peerNodeID.uuidString.prefix(8))] connected local=\(pair.local) remote=\(pair.remote)")
    }

    private func attemptSendLocalSDP(for peerNodeID: UUID) {
        let sdp: String? = lock.withLock {
            guard let entry = peerEntries[peerNodeID],
                let ice = entry.ice,
                !entry.iceLocalSDPSent,
                !ice.localSDP.isEmpty
            else { return nil }
            entry.iceLocalSDPSent = true
            return ice.localSDP
        }
        guard let sdp else { return }
        sendSignal(sdp: sdp, to: peerNodeID)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
                guard let self, self.isRunning, !Task.isCancelled else { break }
                self.heartbeatTick()
            }
        }
    }

    /// Exposed as internal for `@testable` — the real heartbeat loop
    /// calls this on its timer. Tests can drive it synchronously.
    func heartbeatTick() {
        // 1. Re-broadcast voice.started — retries the initial announce
        //    if it was lost, and keeps peers' freshness counters alive.
        broadcastStarted()

        // 2. Age every peer and collect the stale ones.
        var staleNodeIDs: [UUID] = []
        lock.withLock {
            for (nodeID, entry) in peerEntries {
                entry.ticksSinceLastSeen += 1
                if entry.ticksSinceLastSeen >= Self.peerStaleTicksThreshold {
                    staleNodeIDs.append(nodeID)
                }
            }
        }
        guard !staleNodeIDs.isEmpty else { return }

        // 3. A peer going silent on P2P usually means the *path* broke, not
        //    that the peer left: its `voice.started` echoes ride the shared
        //    context transport, which can starve them for several seconds
        //    while it renegotiates (e.g. an SFU→P2P route flip — see the
        //    flap in rtout.txt that evicted a perfectly live peer). Before
        //    dropping a peer that may still be reachable, make the same
        //    "SFU wins" move an ICE failure already makes (`handleICEFailed`):
        //    converge to the relay and give every peer a fresh liveness
        //    window to check in over SFU. `convergeToSFU` is session-wide and
        //    sticky, so this fires at most once; a peer that's still silent
        //    after the relay window is evicted by the `.sfu` branch below on
        //    a later tick.
        if mode == .auto, effectiveTransport == .p2p {
            let names = staleNodeIDs.map { $0.uuidString.prefix(8) }.joined(separator: ",")
            convergeToSFU(reason: "p2p peer(s) stale [\(names)] — relaying instead of dropping")
            lock.withLock {
                for entry in peerEntries.values {
                    entry.ticksSinceLastSeen = 0
                }
            }
            return
        }

        // 4. Already relaying, or the user pinned a transport: a stale peer
        //    is genuinely gone. Evict.
        for nodeID in staleNodeIDs {
            emitLog(
                "peer \(nodeID.uuidString.prefix(8)) stale (\(Self.peerStaleTicksThreshold) missed ticks) — evicting")
            handlePeerEnded(nodeID: nodeID)
        }
    }

    // MARK: - Helpers

    private func emitLog(_ message: String) {
        onLog?(message)
    }

    private func emitPeersChanged() {
        guard let handler = onPeersChanged else { return }
        let snapshot = peers
        handler(snapshot)
    }

    // MARK: - Frame crypto

    /// Builds a 12-byte nonce: first 4 bytes of our node UUID (per-sender
    /// domain separation) + 8-byte big-endian monotonic counter.
    private func nextFrameNonce() -> Data {
        let counter: UInt64 = lock.withLock {
            outboundFrameCounter &+= 1
            return outboundFrameCounter
        }
        var nonce = Data(count: 12)
        let u = localNodeID.uuid
        nonce[0] = u.0
        nonce[1] = u.1
        nonce[2] = u.2
        nonce[3] = u.3
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { nonce.replaceSubrange(4..<12, with: $0) }
        return nonce
    }

    /// Encrypts `payload` if a `frameSecret` is configured, otherwise passes
    /// it through. Drops the frame (returns nil-equivalent via logging) on
    /// the extremely unlikely encryption failure path.
    private func sealFrame(_ payload: Data) -> Data {
        guard let secret = frameSecret else { return payload }
        let nonce = nextFrameNonce()
        let sid = sessionID
        do {
            return try KeepTalkingFrameTransportCrypto.sealVoiceFrame(
                secret: secret, sessionID: sid, nonce12: nonce, plaintext: payload)
        } catch {
            emitLog("[voice/crypto] seal failed: \(error.localizedDescription)")
            return payload
        }
    }

    /// Decrypts an inbound frame. Returns `nil` to drop the frame on
    /// authentication failure. If no secret is configured, passes through.
    private func openFrame(_ data: Data) -> Data? {
        guard let secret = frameSecret else { return data }
        let sid = sessionID
        do {
            return try KeepTalkingFrameTransportCrypto.openVoiceFrame(secret: secret, sessionID: sid, data: data)
        } catch {
            emitLog("[voice/crypto] open failed — dropping frame")
            return nil
        }
    }

}

extension KeepTalkingVoiceSession {
    private struct SFUFrame {
        let sender: UUID
        let target: UUID?
        let payload: Data
    }

    private static let sfuFrameMagic: [UInt8] = [0x4B, 0x54, 0x56, 0x01]
    private static let nilTarget = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let sfuFrameHeaderSize = 4 + 16 + 16

    private static func encodeSFUFrame(_ payload: Data, from sender: UUID, to target: UUID?) -> Data {
        var data = Data()
        data.reserveCapacity(sfuFrameHeaderSize + payload.count)
        data.append(contentsOf: sfuFrameMagic)
        data.append(uuidBytes(sender))
        data.append(uuidBytes(target ?? nilTarget))
        data.append(payload)
        return data
    }

    private static func decodeSFUFrame(_ data: Data) -> SFUFrame? {
        guard data.count >= sfuFrameHeaderSize else { return nil }
        guard Array(data.prefix(sfuFrameMagic.count)) == sfuFrameMagic else { return nil }
        let sender = uuid(from: data, offset: 4)
        let rawTarget = uuid(from: data, offset: 20)
        let payload = data.subdata(in: data.startIndex + sfuFrameHeaderSize..<data.endIndex)
        return SFUFrame(
            sender: sender,
            target: rawTarget == nilTarget ? nil : rawTarget,
            payload: payload
        )
    }

    private static func uuidBytes(_ id: UUID) -> Data {
        var uuid = id.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func uuid(from data: Data, offset: Int) -> UUID {
        var uuid: uuid_t = (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0
        )
        withUnsafeMutableBytes(of: &uuid) { buffer in
            data.copyBytes(
                to: buffer.bindMemory(to: UInt8.self),
                from: data.startIndex + offset..<data.startIndex + offset + 16
            )
        }
        return UUID(uuid: uuid)
    }
}
