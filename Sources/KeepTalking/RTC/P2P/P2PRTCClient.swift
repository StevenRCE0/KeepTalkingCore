import Foundation
import LiveKitWebRTC

enum P2PError: LocalizedError {
    case peerConnectionCreateFailed
    case noRemotePeerFound
    case missingSDP
    case invalidSdpType(String)
    case dataChannelCreateFailed(String)
    case dataChannelNotOpen(String)
    case handshakeTimeout
    case signalingInP2P

    var errorDescription: String? {
        switch self {
            case .peerConnectionCreateFailed:
                return "Failed to create P2P peer connection."
            case .noRemotePeerFound:
                return
                    "No remote peer available for direct P2P. Ensure each client uses a unique --node UUID."
            case .missingSDP:
                return "Missing SDP in signaling payload."
            case .invalidSdpType(let raw):
                return "Invalid SDP type '\(raw)'."
            case .dataChannelCreateFailed(let label):
                return "Failed to create data channel '\(label)'."
            case .dataChannelNotOpen(let label):
                return "Data channel '\(label)' is not open yet."
            case .handshakeTimeout:
                return "P2P handshake timed out."
            case .signalingInP2P:
                return "Cannot perform this operation while in P2P mode."
        }
    }
}

final class KeepTalkingP2PRTCClient: NSObject, KeepTalkingTransportClient,
    @unchecked Sendable
{
    private static let requiredChannels: [KeepTalkingEnvelopeChannel] = [
        .chat, .blob, .actionCall,
    ]

    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onTransportDegraded: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let localNodeID: UUID
    private let sendSignal: @Sendable (_ to: UUID, _ data: KeepTalkingP2PSignalData) -> Void
    private let announcePresence: @Sendable () -> Void
    private let peersSnapshot: @Sendable () -> [UUID]
    private let peerFactory = LKRTCPeerConnectionFactory()

    private var peerConnection: LKRTCPeerConnection?
    private var channels = RTCChannelSet()
    private var pendingRemoteCandidates: [LKRTCIceCandidate] = []
    private var pendingSignals: [(UUID, KeepTalkingP2PSignalData)] = []
    private var remotePeerID: UUID?
    private var sentMessageCount = 0
    private var recvMessageCount = 0
    private var isStopping = false
    private var didReportDegrade = false
    private var notifiedConnectedPeers = Set<UUID>()

    init(
        config: KeepTalkingConfig,
        localNodeID: UUID,
        sendSignal:
            @escaping @Sendable (_ to: UUID, _ data: KeepTalkingP2PSignalData)
            -> Void,
        announcePresence: @escaping @Sendable () -> Void,
        peersSnapshot: @escaping @Sendable () -> [UUID]
    ) {
        self.config = config
        self.localNodeID = localNodeID
        self.sendSignal = sendSignal
        self.announcePresence = announcePresence
        self.peersSnapshot = peersSnapshot
        super.init()
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [p2p] \(message)")
    }

    // MARK: - Lifecycle

    func start() async throws {
        isStopping = false
        didReportDegrade = false
        notifiedConnectedPeers.removeAll()
        debug(
            "starting localPeer=\(localNodeID.uuidString.lowercased()) timeout=\(config.p2pAttemptTimeoutSeconds)s"
        )
        announcePresence()
        try createPeerConnection()
        try createDataChannels()

        let signalsToFlush = pendingSignals
        pendingSignals.removeAll()
        for (from, data) in signalsToFlush {
            handleSignal(from: from, data: data)
        }

        let targetPeerID = try await waitForTargetPeer(
            timeoutSeconds: config.p2pAttemptTimeoutSeconds
        )
        remotePeerID = targetPeerID

        let isOfferer =
            localNodeID.uuidString.lowercased()
            < targetPeerID.uuidString.lowercased()
        debug(
            "selected remotePeer=\(targetPeerID.uuidString.lowercased()) offerer=\(isOfferer)"
        )

        if isOfferer {
            try await sendOffer(to: targetPeerID)
        }

        guard
            await waitForRequiredChannelsOpen(
                timeoutSeconds: config.p2pAttemptTimeoutSeconds
            )
        else {
            throw P2PError.handshakeTimeout
        }
        if let remotePeerID {
            reportPeerConnected(remotePeerID)
        }
    }

    func stop() {
        isStopping = true
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        channels.clearDelegates()
        peerConnection?.delegate = nil
        channels.closeAll()
        peerConnection?.close()

        defer {
            pendingRemoteCandidates.removeAll()
            notifiedConnectedPeers.removeAll()
        }

        channels.removeAll()
        peerConnection = nil
        remotePeerID = nil
        pendingSignals.removeAll()
    }

    // MARK: - Transport protocol

    func requestP2PTrial() {
        debug("ignoring manual p2p trial: already using direct p2p transport")
    }

    func preferReliableRoute(reason: String) {
        debug("reliable route requested reason=\(reason)")
    }

    func currentRoute() -> KeepTalkingTransportRoute {
        .p2p
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        let kind = envelope.channel
        guard kind != .signaling else {
            throw P2PError.signalingInP2P
        }

        guard let dataChannel = channels.preferred(for: kind) else {
            reportTransportDegraded("send failed: channel missing")
            throw P2PError.dataChannelCreateFailed(config.label(for: kind))
        }

        guard dataChannel.readyState == .open else {
            reportTransportDegraded(
                "send failed: channel not open state=\(dataChannel.readyState.rawValue)"
            )
            throw P2PError.dataChannelNotOpen(dataChannel.label)
        }

        let payload = try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: localNodeID,
                contextSecretProvider: contextSecretProvider
            )
        let packet = LKRTCDataBuffer(data: payload, isBinary: false)
        if !dataChannel.sendData(packet) {
            reportTransportDegraded("sendData returned false")
            throw P2PError.dataChannelNotOpen(dataChannel.label)
        }
        sentMessageCount += 1
    }

    private static let maxBufferedAmount: UInt64 = 128 * 1024

    func sendBlobData(
        _ data: Data,
        via route: KeepTalkingTransportRoute?
    ) throws {
        guard let dataChannel = channels.preferred(for: .blob) else {
            let summary = channels.stateSummary(for: Self.requiredChannels)
            debug(
                "blob send failed: no open blob channel \(summary)"
            )
            reportTransportDegraded("blob send failed: channel missing")
            throw P2PError.dataChannelNotOpen(config.blobChannelLabel)
        }

        let packet = LKRTCDataBuffer(data: data, isBinary: true)
        if !dataChannel.sendData(packet) {
            reportTransportDegraded("blob sendData returned false")
            throw P2PError.dataChannelNotOpen(dataChannel.label)
        }
        sentMessageCount += 1
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let outChat = channels.preferred(for: .chat)
        return KeepTalkingRuntimeStats(
            sent: sentMessageCount,
            received: recvMessageCount,
            outboundLabel: outChat?.label,
            outboundState: outChat?.readyState.rawValue,
            inboundLabel: nil,
            inboundState: nil,
            retainedChannels: channels.channelCount,
            route: "p2p"
        )
    }

    /// Indicates whether all required inbound/outbound data channels are currently open.
    func isReady() -> Bool {
        Self.requiredChannels.allSatisfy { channels.isOpen(for: $0) }
    }

    // MARK: - P2P signaling

    func receivePresence(from node: UUID) {
        guard node != localNodeID else { return }
        _ = node
    }

    func receiveSignal(_ payload: KeepTalkingP2PSignalPayload) {
        guard payload.to == localNodeID else { return }
        handleSignal(from: payload.from, data: payload.data)
    }

    // MARK: - WebRTC setup

    private func createPeerConnection() throws {
        let rtcConfig = RTCShared.makeRTCConfiguration(
            iceServerURLs: config.p2pStunServers
        )
        let constraints = RTCShared.makePeerConnectionConstraints()

        guard
            let peerConnection = peerFactory.peerConnection(
                with: rtcConfig,
                constraints: constraints,
                delegate: self
            )
        else {
            throw P2PError.peerConnectionCreateFailed
        }

        self.peerConnection = peerConnection
    }

    private func createDataChannels() throws {
        guard let peerConnection else {
            throw P2PError.peerConnectionCreateFailed
        }

        let channelDefs: [(KeepTalkingEnvelopeChannel, String, Int32)] = [
            (.chat, config.chatChannelLabel, 10),
            (.blob, config.blobChannelLabel, 20),
            (.actionCall, config.actionCallChannelLabel, 30),
        ]

        for (kind, label, id) in channelDefs {
            let channelConfig = LKRTCDataChannelConfiguration()
            channelConfig.isOrdered = true
            channelConfig.isNegotiated = true
            channelConfig.channelId = id
            guard
                let channel = peerConnection.dataChannel(
                    forLabel: label,
                    configuration: channelConfig
                )
            else {
                throw P2PError.dataChannelCreateFailed(label)
            }
            channel.delegate = self
            // When using pre-negotiated channels, the same LKRTCDataChannel instance 
            // handles both sending and receiving immediately upon connection.
            channels.setOutbound(channel, for: kind)
            debug("created negotiated data channel kind=\(kind) label=\(label) id=\(id)")
        }
    }

    private func sendOffer(to peerID: UUID) async throws {
        guard let peerConnection else {
            throw P2PError.peerConnectionCreateFailed
        }

        let offer = try await RTCShared.createOffer(
            on: peerConnection,
            missingSdpError: P2PError.missingSDP
        )
        try await RTCShared.setLocalDescription(
            offer,
            on: peerConnection,
            invalidSdpTypeError: P2PError.invalidSdpType
        )
        sendSignal(peerID, Self.signalData(kind: "offer", description: offer))
        debug("offer sent peer=\(peerID.uuidString.lowercased())")
    }

    // MARK: - Peer discovery

    private func waitForTargetPeer(timeoutSeconds: TimeInterval) async throws
        -> UUID
    {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var duplicateNodeWarningLogged = false
        while Date() < deadline {
            if let remotePeerID {
                return remotePeerID
            }

            let peers = peersSnapshot().filter { $0 != localNodeID }

            if let preferred = config.p2pPreferredRemoteID,
                let preferredID = UUID(uuidString: preferred),
                peers.contains(preferredID)
            {
                return preferredID
            }

            if let first = peers.sorted(by: {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }).first {
                return first
            }

            if !duplicateNodeWarningLogged {
                let discovered = Set(peersSnapshot())
                if discovered.count == 1, discovered.contains(localNodeID) {
                    debug(
                        "no remote peer discovered yet; only local node id=\(localNodeID.uuidString.lowercased()) is visible"
                    )
                    duplicateNodeWarningLogged = true
                }
            }

            announcePresence()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let discovered = Set(peersSnapshot())
        let discoveredIDs =
            discovered
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        debug("target selection timed out discovered=[\(discoveredIDs)]")
        throw P2PError.noRemotePeerFound
    }

    // MARK: - Channel readiness

    private func waitForRequiredChannelsOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if isReady() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let states = channels.stateSummary(for: Self.requiredChannels)
        debug("timeout waiting for required channel set open \(states)")
        reportTransportDegraded(
            "handshake timeout waiting for required channel set"
        )
        return false
    }

    // MARK: - Degradation

    private func reportTransportDegraded(_ reason: String) {
        guard !isStopping else { return }
        guard !didReportDegrade else { return }
        didReportDegrade = true
        debug("transport degraded reason=\(reason)")
        onTransportDegraded?(reason)
    }

    private func reportPeerConnected(_ nodeID: UUID) {
        guard nodeID != localNodeID else { return }
        let inserted = notifiedConnectedPeers.insert(nodeID).inserted
        guard inserted else { return }
        debug("peer reachable node=\(nodeID.uuidString.lowercased())")
        onPeerConnect?(nodeID)
    }

    // MARK: - Signaling handler

    private func handleSignal(from: UUID, data: KeepTalkingP2PSignalData) {
        if let configuredRemote = remotePeerID, configuredRemote != from {
            debug(
                "ignoring signal from unexpected peer \(from.uuidString.lowercased())"
            )
            return
        }

        remotePeerID = from
        guard let peerConnection else {
            debug("buffering signal without peer connection yet kind=\(data.kind)")
            pendingSignals.append((from, data))
            return
        }

        switch data.kind {
            case "offer":
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let payload = SessionDescriptionPayload(
                            type: data.type ?? "offer",
                            sdp: try sdp(from: data)
                        )
                        try await RTCShared.setRemoteDescription(
                            payload,
                            on: peerConnection,
                            invalidSdpTypeError: P2PError.invalidSdpType
                        )
                        flushPendingRemoteCandidates()
                        let answer = try await RTCShared.createAnswer(
                            on: peerConnection,
                            missingSdpError: P2PError.missingSDP
                        )
                        try await RTCShared.setLocalDescription(
                            answer,
                            on: peerConnection,
                            invalidSdpTypeError: P2PError.invalidSdpType
                        )
                        sendSignal(
                            from,
                            Self.signalData(kind: "answer", description: answer)
                        )
                        debug("answer sent peer=\(from.uuidString.lowercased())")
                    } catch {
                        debug(
                            "failed processing offer error=\(error.localizedDescription)"
                        )
                    }
                }
            case "answer":
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let payload = SessionDescriptionPayload(
                            type: data.type ?? "answer",
                            sdp: try sdp(from: data)
                        )
                        try await RTCShared.setRemoteDescription(
                            payload,
                            on: peerConnection,
                            invalidSdpTypeError: P2PError.invalidSdpType
                        )
                        flushPendingRemoteCandidates()
                        debug("answer applied")
                    } catch {
                        debug(
                            "failed processing answer error=\(error.localizedDescription)"
                        )
                    }
                }
            case "ice":
                guard let candidateString = data.candidate else {
                    debug("ice signal missing candidate")
                    return
                }
                let candidate = LKRTCIceCandidate(
                    sdp: candidateString,
                    sdpMLineIndex: data.sdpMLineIndex ?? 0,
                    sdpMid: data.sdpMid
                )
                let applied = RTCShared.applyOrBufferCandidate(
                    candidate,
                    on: peerConnection,
                    buffer: &pendingRemoteCandidates
                )
                if applied {
                    debug("applied remote candidate")
                } else {
                    debug(
                        "buffered remote candidate count=\(pendingRemoteCandidates.count)"
                    )
                }
            default:
                debug("unhandled signal kind=\(data.kind)")
        }
    }

    private func flushPendingRemoteCandidates() {
        guard let peerConnection else { return }
        _ = RTCShared.flushBufferedCandidates(
            on: peerConnection,
            buffer: &pendingRemoteCandidates
        )
    }

    private func sdp(from data: KeepTalkingP2PSignalData) throws -> String {
        guard let sdp = data.sdp else {
            throw P2PError.missingSDP
        }
        return sdp
    }

    private static func signalData(
        kind: String,
        description: SessionDescriptionPayload
    ) -> KeepTalkingP2PSignalData {
        KeepTalkingP2PSignalData(
            kind: kind,
            type: description.type,
            sdp: description.sdp,
            candidate: nil,
            sdpMid: nil,
            sdpMLineIndex: nil
        )
    }

    private static func signalData(candidate: LKRTCIceCandidate)
        -> KeepTalkingP2PSignalData
    {
        KeepTalkingP2PSignalData(
            kind: "ice",
            type: nil,
            sdp: nil,
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
    }

    // MARK: - Peer connection delegate handlers

    func handlePeerConnectionSignalingStateChange(
        _ peerConnection: LKRTCPeerConnection,
        stateChanged: LKRTCSignalingState
    ) {
        debug("signaling state=\(stateChanged.rawValue)")
    }

    func handlePeerConnectionIceConnectionStateChange(
        _ peerConnection: LKRTCPeerConnection,
        newState: LKRTCIceConnectionState
    ) {
        debug("ice connection state=\(newState.rawValue)")
        switch newState {
            case .failed:
                reportTransportDegraded("ice failed")
            case .closed:
                reportTransportDegraded("ice closed")
            default:
                break
        }
    }

    func handlePeerConnectionIceGatheringStateChange(
        _ peerConnection: LKRTCPeerConnection,
        newState: LKRTCIceGatheringState
    ) {
        debug("ice gathering state=\(newState.rawValue)")
    }

    func handlePeerConnectionDidGenerateCandidate(
        _ peerConnection: LKRTCPeerConnection,
        candidate: LKRTCIceCandidate
    ) {
        guard let remotePeerID else {
            return
        }
        sendSignal(remotePeerID, Self.signalData(candidate: candidate))
    }

    func handlePeerConnectionDidRemoveCandidates(
        _ peerConnection: LKRTCPeerConnection,
        candidates: [LKRTCIceCandidate]
    ) {
        debug("removed candidates count=\(candidates.count)")
    }

    func handlePeerConnectionShouldNegotiate(
        _ peerConnection: LKRTCPeerConnection
    ) {
        debug("should negotiate")
    }

    func handlePeerConnectionDidAddStream(
        _ peerConnection: LKRTCPeerConnection,
        stream: LKRTCMediaStream
    ) {}

    func handlePeerConnectionDidRemoveStream(
        _ peerConnection: LKRTCPeerConnection,
        stream: LKRTCMediaStream
    ) {}

    func handlePeerConnectionDidOpenDataChannel(
        _ peerConnection: LKRTCPeerConnection,
        dataChannel: LKRTCDataChannel
    ) {
        dataChannel.delegate = self
        if let kind = channelKind(for: dataChannel.label) {
            channels.setInbound(dataChannel, for: kind)
            debug("bound inbound channel kind=\(kind) label=\(dataChannel.label)")
        }
    }

    // MARK: - Data channel delegate handlers

    func handleDataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
        guard isKnownChannel(dataChannel.label) else { return }
        switch dataChannel.readyState {
            case .closing, .closed:
                channels.removeChannel(dataChannel)
                reportTransportDegraded(
                    "data channel \(dataChannel.readyState == .closing ? "closing" : "closed")"
                )
            default:
                break
        }
    }

    func handleDataChannelDidReceiveMessage(
        _ dataChannel: LKRTCDataChannel,
        buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        guard isKnownChannel(dataChannel.label) else { return }

        do {
            if let envelope = try KeepTalkingPacketTransportCrypto
                .inboundEnvelope(
                    from: buffer.data,
                    contextSecretProvider: contextSecretProvider
                )
            {
                let expectedLabel = config.label(for: envelope.channel)
                guard dataChannel.label == expectedLabel else {
                    debug(
                        "ignored envelope on unexpected channel label=\(dataChannel.label) expected=\(expectedLabel)"
                    )
                    return
                }
                onEnvelope?(envelope)
                return
            }
        } catch {
            if dataChannel.label != config.blobChannelLabel {
                debug(
                    "envelope decode failed; encrypted envelope error=\(error.localizedDescription)"
                )
            }
        }

        if dataChannel.label == config.blobChannelLabel {
            onBlobData?(buffer.data)
            return
        }

        if let text = String(data: buffer.data, encoding: .utf8) {
            onRawMessage?(text)
        } else {
            onRawMessage?("<\(buffer.data.count) bytes>")
        }
    }

    // MARK: - Channel label helpers

    private func channelKind(for label: String) -> KeepTalkingEnvelopeChannel? {
        if label == config.chatChannelLabel { return .chat }
        if label == config.blobChannelLabel { return .blob }
        if label == config.actionCallChannelLabel { return .actionCall }
        return nil
    }

    private func isKnownChannel(_ label: String) -> Bool {
        channelKind(for: label) != nil
    }
}
