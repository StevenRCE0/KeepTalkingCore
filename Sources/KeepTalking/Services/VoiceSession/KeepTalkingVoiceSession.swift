import Foundation

/// Group voice over the context's room. **N-peer from the start.**
///
/// ### Call presence (envelopes)
///
/// - `KeepTalkingVoiceCallStartedPayload` — broadcast on `start()`, on every
///   heartbeat, and when a new participant is first seen. Doubles as "I'm in
///   the call" and "did you know I was here?".
/// - `KeepTalkingVoiceCallEndedPayload` — broadcast on `stop()`.
///
/// Context presence is intentionally **ignored** for joining: it says a peer
/// is in the chat, not that they're in the call. A participant joins on a
/// `started`, or on its first audio.
///
/// ### Audio (datagrams)
///
/// Frames are lossy datagrams on the room: the shared transport fans them out
/// through the SFU or sends them to every member a network link reaches —
/// never over Bluetooth, which can't carry a call. Each datagram is sealed
/// with the call's key (the context secret and the shared session id), and
/// the seal covers who sent it and whom it's for, so the transport, the SFU
/// and members outside the call see neither. Frames are opaque `Data`; a
/// multimodal agent can hook `onInboundFrame` and `broadcast(_:)` to get the
/// same seam.
public final class KeepTalkingVoiceSession: @unchecked Sendable {
    public enum PeerState: Sendable, Equatable {
        /// In the call; no audio heard from it lately.
        case joined
        /// Its audio is arriving.
        case receiving
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

    public let localNodeID: UUID
    public private(set) var isRunning: Bool = false

    public var peers: [Peer] {
        let now = Date()
        return lock.withLock {
            peerEntries.values.map { Peer(nodeID: $0.nodeID, state: $0.state(now: now)) }
        }
    }

    private let config: KeepTalkingConfig
    private let sendEnvelope: @Sendable (any KeepTalkingEnvelope) throws -> Void
    private let sendDatagram: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var peerEntries: [UUID: PeerEntry] = [:]
    /// Peers last reported as `receiving`, so a change is reported once.
    private var reportedReceiving: Set<UUID> = []
    /// When non-nil, every datagram is AES-GCM sealed with a key derived from
    /// this secret and the session id; datagrams that don't open are dropped.
    private let frameSecret: Data?
    private var outboundFrameCounter: UInt64 = 0

    /// Heartbeat interval — re-broadcasts `voice.started` and checks
    /// peer freshness. Voice is real-time, so we run much tighter than
    /// the context's 13 s presence heartbeat.
    private static let heartbeatIntervalSeconds: TimeInterval = 2
    /// A peer that hasn't echoed `voice.started` within this many ticks
    /// is evicted. 3 ticks × 2 s = 6 s of silence before cleanup.
    private static let peerStaleTicksThreshold: Int = 3
    /// A peer whose audio stopped this long ago reads `joined` again.
    private static let receivingWindow: TimeInterval = 3

    private var heartbeatTask: Task<Void, Never>?

    private struct PeerEntry {
        let nodeID: UUID
        /// Ticks since the last `voice.started` from this peer. Reset to 0
        /// on every inbound `started`; incremented each heartbeat tick.
        var ticksSinceLastSeen = 0
        var lastAudioAt: Date?

        func state(now: Date) -> PeerState {
            guard let lastAudioAt, now.timeIntervalSince(lastAudioAt) < receivingWindow else { return .joined }
            return .receiving
        }
    }

    public init(
        config: KeepTalkingConfig,
        sendEnvelope: @escaping @Sendable (any KeepTalkingEnvelope) throws -> Void,
        sendDatagram: @escaping @Sendable (Data) throws -> Void,
        frameSecret: Data? = nil
    ) {
        self.config = config
        self.sendEnvelope = sendEnvelope
        self.sendDatagram = sendDatagram
        self.localNodeID = config.node
        self.frameSecret = frameSecret
    }

    // MARK: - Shared session id

    /// The shared voice-session id every participant converges on — the key for
    /// the federated transcript (in-memory call record + lines) and for the
    /// audio seal. Each node mints a candidate and converges to the global
    /// minimum by adopting any lower id it sees on a peer's `started`. Settles
    /// within the opening `started` exchange, well before the first
    /// (endpointed) transcript line.
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
        emitLog("starting voice session context=\(config.contextID.uuidString.prefix(8))")
        broadcastStarted()
        startHeartbeat()
    }

    public func stop() {
        let wasRunning = isRunning
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if isRunning {
            broadcastEnded()
        }
        lock.withLock {
            peerEntries.removeAll()
            reportedReceiving.removeAll()
        }
        isRunning = false
        emitPeersChanged()
        emitLog("stopped")
        // Let the client drop its `activeVoiceSession` so it no longer believes
        // it's in the call (otherwise it keeps re-asserting presence on peers'
        // leaves and nothing ever seals). Only on a real running → stopped edge.
        if wasRunning { onStopped?() }
    }

    // MARK: - Audio out

    /// Sends a frame to everyone in the call.
    public func broadcast(_ payload: Data) {
        guard lock.withLock({ !peerEntries.isEmpty }) else { return }
        sendFrame(payload, to: nil)
    }

    /// Addresses one participant. The datagram still reaches the whole room;
    /// only `nodeID` opens it as meant for it. The agent integration uses
    /// this to whisper to a single listener.
    public func send(_ payload: Data, to nodeID: UUID) {
        guard lock.withLock({ peerEntries[nodeID] != nil }) else { return }
        sendFrame(payload, to: nodeID)
    }

    private func sendFrame(_ payload: Data, to target: UUID?) {
        let frame = Frame(sender: localNodeID, target: target, payload: payload)
        guard let sealed = sealFrame(frame.encoded) else { return }
        try? sendDatagram(sealed)
    }

    // MARK: - Audio in

    /// Handles a datagram from the room. Returns `false` when it isn't a
    /// frame of this call, so other realtime data can share the room.
    @discardableResult
    func receiveDatagram(_ datagram: Data) -> Bool {
        guard isRunning, let opened = openFrame(datagram), let frame = Frame(decoding: opened) else { return false }
        guard frame.sender != localNodeID else { return true }
        guard frame.target == nil || frame.target == localNodeID else { return true }
        // Audio from someone we haven't seen announce: their `started` was
        // lost or is still on its way. Their audio is proof enough.
        if lock.withLock({ peerEntries[frame.sender] == nil }) {
            handlePeerStarted(nodeID: frame.sender)
        }
        let startedReceiving = lock.withLock { () -> Bool in
            peerEntries[frame.sender]?.lastAudioAt = Date()
            return reportedReceiving.insert(frame.sender).inserted
        }
        if startedReceiving { emitPeersChanged() }
        onInboundFrame?(frame.payload, frame.sender)
        return true
    }

    // MARK: - Envelope outbound

    private func broadcastStarted() {
        let payload = KeepTalkingVoiceCallStartedPayload(
            from: localNodeID,
            contextID: config.contextID,
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

    // MARK: - Envelope inbound

    public func receiveVoiceEnvelope(_ envelope: any KeepTalkingEnvelope) {
        guard isRunning else { return }
        if let envelopeContext = envelope.transportContextID, envelopeContext != config.contextID {
            return
        }
        switch envelope {
            case let started as KeepTalkingVoiceCallStartedPayload:
                if let peerSession = started.sessionID {
                    adoptSessionIDIfLower(peerSession)
                }
                handlePeerStarted(nodeID: started.from)
            case let ended as KeepTalkingVoiceCallEndedPayload:
                handlePeerEnded(nodeID: ended.from)
            default:
                break
        }
    }

    // MARK: - Participants

    private func handlePeerStarted(nodeID: UUID) {
        guard nodeID != localNodeID else { return }
        let isNew = lock.withLock { () -> Bool in
            // Any voice.started — echo or not — proves the peer is alive.
            if peerEntries[nodeID] != nil {
                peerEntries[nodeID]?.ticksSinceLastSeen = 0
                return false
            }
            peerEntries[nodeID] = PeerEntry(nodeID: nodeID)
            return true
        }
        guard isNew else { return }
        emitLog("← voice.started from=\(nodeID.uuidString.prefix(8)) (new)")
        emitPeersChanged()
        // Re-announce so a peer who joined *after* our initial broadcast
        // learns we're here.
        broadcastStarted()
    }

    private func handlePeerEnded(nodeID: UUID) {
        let removed = lock.withLock { () -> Bool in
            reportedReceiving.remove(nodeID)
            return peerEntries.removeValue(forKey: nodeID) != nil
        }
        guard removed else { return }
        emitLog("← voice.ended from=\(nodeID.uuidString.prefix(8))")
        emitPeersChanged()
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
        // 1. Re-broadcast voice.started — retries the initial announce if it
        //    was lost, and keeps peers' freshness counters alive.
        broadcastStarted()

        // 2. Age every peer: evict the silent ones, and notice audio that
        //    stopped.
        let now = Date()
        let (stale, audioStopped) = lock.withLock { () -> ([UUID], Bool) in
            for nodeID in peerEntries.keys { peerEntries[nodeID]?.ticksSinceLastSeen += 1 }
            let stale = peerEntries.values.filter { $0.ticksSinceLastSeen >= Self.peerStaleTicksThreshold }.map(
                \.nodeID)
            let receiving = Set(peerEntries.values.filter { $0.state(now: now) == .receiving }.map(\.nodeID))
            defer { reportedReceiving = receiving }
            return (stale, !reportedReceiving.isSubset(of: receiving))
        }
        for nodeID in stale {
            emitLog(
                "peer \(nodeID.uuidString.prefix(8)) stale (\(Self.peerStaleTicksThreshold) missed ticks) — evicting")
            handlePeerEnded(nodeID: nodeID)
        }
        if audioStopped, stale.isEmpty { emitPeersChanged() }
    }

    // MARK: - Helpers

    private func emitLog(_ message: String) {
        onLog?(message)
    }

    private func emitPeersChanged() {
        guard let handler = onPeersChanged else { return }
        handler(peers)
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

    /// Seals with the call's key when a `frameSecret` is configured, else
    /// passes through. Nil drops the frame on the unlikely seal failure.
    private func sealFrame(_ plaintext: Data) -> Data? {
        guard let secret = frameSecret else { return plaintext }
        do {
            return try KeepTalkingFrameTransportCrypto.sealVoiceFrame(
                secret: secret, sessionID: sessionID, nonce12: nextFrameNonce(), plaintext: plaintext)
        } catch {
            emitLog("[voice/crypto] seal failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Opens an inbound datagram. Nil when it isn't sealed with this call's
    /// key. If no secret is configured, passes through.
    private func openFrame(_ data: Data) -> Data? {
        guard let secret = frameSecret else { return data }
        return try? KeepTalkingFrameTransportCrypto.openVoiceFrame(secret: secret, sessionID: sessionID, data: data)
    }
}

extension KeepTalkingVoiceSession {
    /// The sealed part of a voice datagram:
    /// `magic(4) ‖ sender(16) ‖ target(16, zeros = everyone) ‖ payload`.
    struct Frame: Equatable {
        static let magic: [UInt8] = [0x4B, 0x54, 0x56, 0x02]
        static let headerLength = 4 + 16 + 16
        private static let everyone = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

        let sender: UUID
        let target: UUID?
        let payload: Data

        init(sender: UUID, target: UUID?, payload: Data) {
            self.sender = sender
            self.target = target
            self.payload = payload
        }

        init?(decoding data: Data) {
            guard data.count >= Self.headerLength, Array(data.prefix(4)) == Self.magic else { return nil }
            let start = data.startIndex
            sender = UUID(rfc4122Bytes: Data(data[start + 4..<start + 20]))
            let target = UUID(rfc4122Bytes: Data(data[start + 20..<start + 36]))
            self.target = target == Self.everyone ? nil : target
            payload = Data(data[(start + Self.headerLength)...])
        }

        var encoded: Data {
            var data = Data(capacity: Self.headerLength + payload.count)
            data.append(contentsOf: Self.magic)
            data.append(sender.rfc4122Bytes)
            data.append((target ?? Self.everyone).rfc4122Bytes)
            data.append(payload)
            return data
        }
    }
}
