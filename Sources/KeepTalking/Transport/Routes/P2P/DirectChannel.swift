import Foundation

/// Per-peer direct channel backed by libjuice-assisted HTTP/2 over TCP.
///
/// Signaling rides the reliable broadcast backbone. libjuice proves the
/// peer path, then KT envelopes move as encrypted packet-transport
/// payloads over a direct HTTP/2 stream.
final class KeepTalkingDirectChannel: KeepTalkingPeerTransportChannel, @unchecked Sendable {
    let route: KeepTalkingTransportRoute = .p2p
    let peerNodeID: UUID

    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerAlive: (@Sendable (UUID) -> Void)?
    var onSignalOutput: (@Sendable (KeepTalkingP2PSignalPayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let localNodeID: UUID
    private var session: KeepTalkingJuiceP2PSession?
    private var dataChannel: KeepTalkingBlobHTTP2Channel?
    private var stateMachine = DirectChannelStateMachine()
    private let stateQueue = DispatchQueue(label: "kt.direct.juice.state")
    private var backoffTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pendingRemoteSDP: String?
    private var pendingRemoteDataPort: UInt16?
    private var pendingRemoteDataHost: String?
    private var localDataHost: String?
    private var remoteDataHost: String?

    var state: DirectChannelState {
        stateQueue.sync { stateMachine.state }
    }

    var isReady: Bool {
        stateQueue.sync { stateMachine.state == .ready }
    }

    init(
        peerNodeID: UUID,
        config: KeepTalkingConfig,
        localNodeID: UUID,
        peersSnapshot: @escaping @Sendable () -> [UUID]
    ) {
        self.peerNodeID = peerNodeID
        self.config = config
        self.localNodeID = localNodeID
        _ = peersSnapshot
    }

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        guard isReady, let dataChannel else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        let payload = try KeepTalkingPacketTransportCrypto.outboundPayload(
            for: sequenced.envelope,
            localNodeID: localNodeID,
            contextSecretProvider: contextSecretProvider
        )
        try dataChannel.send(payload)
    }

    func sendBlobData(_ data: Data) throws {
        guard isReady, let dataChannel else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }
        try dataChannel.send(data)
    }

    func receiveSignal(_ signal: KeepTalkingP2PSignalPayload) {
        guard signal.to == localNodeID, signal.from == peerNodeID else { return }
        if signal.data.kind == "h2-port", let raw = signal.data.candidate {
            let parsed = Self.parseDataPortSignal(raw)
            if let port = parsed.port {
                receiveRemoteDataPort(port, host: parsed.host)
            }
            return
        }
        guard signal.data.kind == "juice-sdp", let sdp = signal.data.sdp else { return }

        let current = stateQueue.sync { stateMachine.state }
        if current == .idle || current == .abandoned {
            stateQueue.sync { pendingRemoteSDP = sdp }
            attemptUpgrade()
        } else if let session {
            session.applyRemoteSDP(sdp)
        } else {
            stateQueue.sync { pendingRemoteSDP = sdp }
        }
    }

    func attemptUpgrade() {
        applyEvent(.upgradeRequested)
    }

    func teardown() {
        applyEvent(.teardownRequested)
    }

    func requestRetrial() {
        applyEvent(.retryRequested)
    }

    private func applyEvent(_ event: DirectChannelEvent) {
        let effect = stateQueue.sync { stateMachine.handle(event) }
        onStateChange?()

        switch effect {
            case .beginHandshake:
                startHandshake()
            case .scheduleBackoff(let seconds):
                scheduleBackoff(seconds: seconds)
            case .cleanup:
                cleanup()
            case .none:
                break
        }
    }

    private func startHandshake() {
        let remoteSDP = stateQueue.sync { pendingRemoteSDP }
        cleanup()

        do {
            let next = try KeepTalkingJuiceP2PSession()
            bind(next)
            stateQueue.sync { session = next }
            scheduleHandshakeTimeout()
            if let remoteSDP {
                next.applyRemoteSDP(remoteSDP)
            }
            next.start()
        } catch {
            debug("juice init failed error=\(error.localizedDescription)")
            applyEvent(.iceFailed)
        }
    }

    private func bind(_ next: KeepTalkingJuiceP2PSession) {
        next.onState = { [weak self] state in
            guard let self else { return }
            switch state {
                case .connected:
                    self.handleICEConnected(next)
                case .failed:
                    self.applyEvent(.iceFailed)
                case .closed:
                    self.applyEvent(.iceDisconnected)
                default:
                    break
            }
        }
        next.onLocalSDPReady = { [weak self] sdp in
            guard let self else { return }
            self.onSignalOutput?(
                KeepTalkingP2PSignalPayload(
                    from: self.localNodeID,
                    to: self.peerNodeID,
                    data: KeepTalkingP2PSignalData(
                        kind: "juice-sdp",
                        type: "sdp",
                        sdp: sdp,
                        candidate: nil,
                        sdpMid: nil,
                        sdpMLineIndex: nil
                    )
                )
            )
        }
        next.onMessage = nil
        next.onLog = { [weak self] message in
            self?.debug(message)
        }
    }

    private func handleICEConnected(_ session: KeepTalkingJuiceP2PSession) {
        guard let pair = session.selectedAddresses(),
            let (localHost, _) = Self.parseAddress(pair.local),
            let (remoteHost, _) = Self.parseAddress(pair.remote)
        else {
            debug("ice connected without selected addresses")
            applyEvent(.iceFailed)
            return
        }
        debug("ice connected local=\(pair.local) remote=\(pair.remote)")
        stateQueue.sync {
            localDataHost = localHost
            remoteDataHost = remoteHost
        }
        if isListenerSide {
            startDataChannel(.listener)
        } else if let port = stateQueue.sync(execute: { pendingRemoteDataPort }) {
            let host = stateQueue.sync { pendingRemoteDataHost ?? remoteHost }
            startDataChannel(.initiator(host: host, port: port))
        } else {
            debug("waiting for peer data port")
        }
    }

    private var isListenerSide: Bool {
        localNodeID.uuidString < peerNodeID.uuidString
    }

    private func receiveRemoteDataPort(_ port: UInt16, host: String?) {
        stateQueue.sync {
            pendingRemoteDataPort = port
            pendingRemoteDataHost = host
        }
        debug("received peer data endpoint=\(host.map { "\($0):" } ?? "")\(port)")
        guard !isListenerSide,
            let targetHost = stateQueue.sync(execute: { host ?? remoteDataHost }),
            stateQueue.sync(execute: { dataChannel == nil })
        else { return }
        startDataChannel(.initiator(host: targetHost, port: port))
    }

    private func startDataChannel(_ role: KeepTalkingBlobHTTP2Channel.Role) {
        guard stateQueue.sync(execute: { dataChannel == nil }) else { return }
        let channel = KeepTalkingBlobHTTP2Channel(role: role)
        channel.onLog = { [weak self] message in
            self?.debug("[h2] \(message)")
        }
        channel.onState = { [weak self] state in
            self?.handleDataChannelState(state)
        }
        channel.onMessage = { [weak self] data in
            self?.handleIncoming(data)
        }
        stateQueue.sync { dataChannel = channel }
        channel.start()
    }

    private func handleDataChannelState(_ state: KeepTalkingBlobHTTP2Channel.State) {
        switch state {
            case .ready(let port?):
                sendDataPort(port)
            case .connected:
                handshakeTimeoutTask?.cancel()
                handshakeTimeoutTask = nil
                closeICESession()
                applyEvent(.iceConnected)
                onPeerAlive?(peerNodeID)
            case .failed(let reason):
                debug("data channel failed reason=\(reason)")
                applyEvent(.iceFailed)
            case .closed:
                applyEvent(.iceDisconnected)
            default:
                break
        }
    }

    private func sendDataPort(_ port: UInt16) {
        let host = stateQueue.sync { localDataHost }
        onSignalOutput?(
            KeepTalkingP2PSignalPayload(
                from: localNodeID,
                to: peerNodeID,
                data: KeepTalkingP2PSignalData(
                    kind: "h2-port",
                    type: "port",
                    sdp: nil,
                    candidate: host.map { "\(port)|\($0)" } ?? String(port),
                    sdpMid: nil,
                    sdpMLineIndex: nil
                )
            )
        )
    }

    private func handleIncoming(_ data: Data) {
        do {
            if let envelope = try KeepTalkingPacketTransportCrypto.inboundEnvelope(
                from: data,
                contextSecretProvider: contextSecretProvider
            ) {
                onReceive?(
                    KeepTalkingSequencedEnvelope(
                        senderNode: peerNodeID,
                        sequence: 0,
                        envelope: envelope
                    )
                )
                return
            }
        } catch {
            debug("decode failed error=\(error.localizedDescription)")
        }
        onBlobData?(data)
    }

    private func scheduleHandshakeTimeout() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { [weak self, config] in
            try? await Task.sleep(for: .seconds(config.p2pAttemptTimeoutSeconds))
            guard let self, !Task.isCancelled else { return }
            if self.state == .negotiating {
                self.debug("handshake timeout after \(config.p2pAttemptTimeoutSeconds)s")
                self.applyEvent(.handshakeTimeout)
            }
        }
    }

    private func scheduleBackoff(seconds: TimeInterval) {
        backoffTask?.cancel()
        debug("backing off for \(seconds)s")
        backoffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.applyEvent(.backoffExpired)
        }
    }

    private func cleanup() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        backoffTask?.cancel()
        backoffTask = nil

        let oldDataChannel = stateQueue.sync { () -> KeepTalkingBlobHTTP2Channel? in
            let value = dataChannel
            dataChannel = nil
            return value
        }
        oldDataChannel?.onState = nil
        oldDataChannel?.onMessage = nil
        oldDataChannel?.onLog = nil
        oldDataChannel?.close()

        let old = stateQueue.sync { () -> KeepTalkingJuiceP2PSession? in
            let value = session
            session = nil
            pendingRemoteSDP = nil
            pendingRemoteDataPort = nil
            pendingRemoteDataHost = nil
            localDataHost = nil
            remoteDataHost = nil
            return value
        }
        old?.onState = nil
        old?.onLocalSDPReady = nil
        old?.onMessage = nil
        old?.onLog = nil
        old?.close()
    }

    private func closeICESession() {
        let old = stateQueue.sync { () -> KeepTalkingJuiceP2PSession? in
            let value = session
            session = nil
            pendingRemoteSDP = nil
            return value
        }
        old?.onState = nil
        old?.onLocalSDPReady = nil
        old?.onMessage = nil
        old?.onLog = nil
        old?.close()
    }

    private func debug(_ message: String) {
        onLog?("[direct-h2:\(peerNodeID.uuidString.prefix(8))] \(message)")
    }

    private static func parseAddress(_ value: String) -> (host: String, port: UInt16)? {
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<end])
            let after = value.index(after: end)
            guard after < value.endIndex, value[after] == ":" else { return nil }
            guard let port = UInt16(value[value.index(after: after)...]) else { return nil }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":"),
            let port = UInt16(value[value.index(after: colon)...])
        else { return nil }
        return (String(value[..<colon]), port)
    }

    private static func parseDataPortSignal(_ value: String) -> (port: UInt16?, host: String?) {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        let port = UInt16(parts.first ?? "")
        let host = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (port, host.isEmpty ? nil : host)
    }
}
