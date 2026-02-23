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
        }
    }
}

final class KeepTalkingP2PRTCClient: NSObject, KeepTalkingTransportClient,
    @unchecked Sendable
{
    var onMessage: (@Sendable (KeepTalkingContextMessage) -> Void)?
    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onTransportDegraded: (@Sendable (String) -> Void)?

    private let config: KeepTalkingConfig
    private let localNodeID: UUID
    private let sendSignal:
        @Sendable (_ to: UUID, _ data: KeepTalkingP2PSignalData) -> Void
    private let announcePresence: @Sendable () -> Void
    private let peersSnapshot: @Sendable () -> [UUID]
    private let peerFactory = LKRTCPeerConnectionFactory()

    private var peerConnection: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var pendingRemoteCandidates: [LKRTCIceCandidate] = []
    private var remotePeerID: UUID?
    private var sentMessageCount = 0
    private var recvMessageCount = 0
    private var isStopping = false
    private var didReportDegrade = false

    init(
        config: KeepTalkingConfig,
        localNodeID: UUID,
        sendSignal: @escaping @Sendable (_ to: UUID, _ data: KeepTalkingP2PSignalData) -> Void,
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

    private func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [p2p] \(message)")
    }

    func start() async throws {
        isStopping = false
        didReportDegrade = false
        debug(
            "starting localPeer=\(localNodeID.uuidString.lowercased()) timeout=\(config.p2pAttemptTimeoutSeconds)s"
        )
        announcePresence()
        try createPeerConnection()

        let targetPeerID = try await waitForTargetPeer(
            timeoutSeconds: config.p2pAttemptTimeoutSeconds
        )
        remotePeerID = targetPeerID

        let isOfferer = localNodeID.uuidString.lowercased()
            < targetPeerID.uuidString.lowercased()
        debug("selected remotePeer=\(targetPeerID.uuidString.lowercased()) offerer=\(isOfferer)")

        if isOfferer {
            try createOutboundDataChannel()
            try await sendOffer(to: targetPeerID)
        }

        guard await waitForDataChannelOpen(timeoutSeconds: config.p2pAttemptTimeoutSeconds)
        else {
            throw P2PError.handshakeTimeout
        }
    }

    func stop() {
        isStopping = true
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        dataChannel?.close()
        peerConnection?.close()
        pendingRemoteCandidates.removeAll()
        peerConnection = nil
        dataChannel = nil
        remotePeerID = nil
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        guard let dataChannel else {
            reportTransportDegraded("send failed: channel missing")
            throw P2PError.dataChannelCreateFailed(config.channel)
        }

        guard dataChannel.readyState == .open else {
            reportTransportDegraded(
                "send failed: channel not open state=\(dataChannel.readyState.rawValue)"
            )
            throw P2PError.dataChannelNotOpen(dataChannel.label)
        }

        let payload = try JSONEncoder().encode(envelope)
        let packet = LKRTCDataBuffer(data: payload, isBinary: false)
        if !dataChannel.sendData(packet) {
            reportTransportDegraded("sendData returned false")
            throw P2PError.dataChannelNotOpen(dataChannel.label)
        }
        sentMessageCount += 1
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        KeepTalkingRuntimeStats(
            sent: sentMessageCount,
            received: recvMessageCount,
            outboundLabel: dataChannel?.label,
            outboundState: dataChannel?.readyState.rawValue,
            inboundLabel: dataChannel?.label,
            inboundState: dataChannel?.readyState.rawValue,
            retainedChannels: dataChannel == nil ? 0 : 1,
            route: "p2p"
        )
    }

    func receivePresence(from node: UUID) {
        guard node != localNodeID else { return }
        _ = node
    }

    func receiveSignal(_ payload: KeepTalkingP2PSignalPayload) {
        guard payload.to == localNodeID else { return }
        handleSignal(from: payload.from, data: payload.data)
    }

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

    private func createOutboundDataChannel() throws {
        guard let peerConnection else {
            throw P2PError.peerConnectionCreateFailed
        }

        let channelConfig = LKRTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        guard
            let dataChannel = peerConnection.dataChannel(
                forLabel: config.channel,
                configuration: channelConfig
            )
        else {
            throw P2PError.dataChannelCreateFailed(config.channel)
        }

        dataChannel.delegate = self
        self.dataChannel = dataChannel
        debug("created outbound data channel label=\(dataChannel.label)")
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
        let discoveredIDs = discovered
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        debug("target selection timed out discovered=[\(discoveredIDs)]")
        throw P2PError.noRemotePeerFound
    }

    private func waitForDataChannelOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let opened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.dataChannel
        }
        if !opened {
            debug("timeout waiting for data channel open")
            reportTransportDegraded("handshake timeout waiting for channel open")
        }
        return opened
    }

    private func reportTransportDegraded(_ reason: String) {
        guard !isStopping else { return }
        guard !didReportDegrade else { return }
        didReportDegrade = true
        debug("transport degraded reason=\(reason)")
        onTransportDegraded?(reason)
    }

    private func handleSignal(from: UUID, data: KeepTalkingP2PSignalData) {
        if let configuredRemote = remotePeerID, configuredRemote != from {
            debug("ignoring signal from unexpected peer \(from.uuidString.lowercased())")
            return
        }

        remotePeerID = from
        guard let peerConnection else {
            debug("ignoring signal without peer connection")
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
                    sendSignal(from, Self.signalData(kind: "answer", description: answer))
                    debug("answer sent peer=\(from.uuidString.lowercased())")
                } catch {
                    debug("failed processing offer error=\(error.localizedDescription)")
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
                    debug("failed processing answer error=\(error.localizedDescription)")
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
                debug("buffered remote candidate count=\(pendingRemoteCandidates.count)")
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
}

extension KeepTalkingP2PRTCClient: LKRTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        debug("signaling state=\(stateChanged.rawValue)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
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

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        debug("ice gathering state=\(newState.rawValue)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        guard let remotePeerID else {
            return
        }
        sendSignal(remotePeerID, Self.signalData(candidate: candidate))
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {
        debug("removed candidates count=\(candidates.count)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        debug("should negotiate")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd stream: LKRTCMediaStream
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove stream: LKRTCMediaStream
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        dataChannel.delegate = self
        if dataChannel.label == config.channel {
            self.dataChannel = dataChannel
            debug("bound inbound data channel label=\(dataChannel.label)")
        }
    }
}

extension KeepTalkingP2PRTCClient: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
        guard dataChannel.label == config.channel else {
            return
        }
        switch dataChannel.readyState {
        case .closing:
            reportTransportDegraded("data channel closing")
        case .closed:
            reportTransportDegraded("data channel closed")
        default:
            break
        }
    }

    func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        guard dataChannel.label == config.channel else {
            return
        }

        if let envelope = try? JSONDecoder().decode(
            KeepTalkingP2PEnvelope.self,
            from: buffer.data
        ) {
            switch envelope {
            case .message(let message):
                onMessage?(message)
            default:
                onEnvelope?(envelope)
            }
            return
        }

        if let text = String(data: buffer.data, encoding: .utf8) {
            onRawMessage?(text)
        } else {
            onRawMessage?("<\(buffer.data.count) bytes>")
        }
    }
}
