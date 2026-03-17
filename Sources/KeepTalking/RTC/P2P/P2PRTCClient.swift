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
    private enum EnvelopeRoute {
        case chat
        case actionCall
    }

    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onTransportDegraded: (@Sendable (String) -> Void)?

    private let config: KeepTalkingConfig
    private let localNodeID: UUID
    private let sendSignal: @Sendable (_ to: UUID, _ data: KeepTalkingP2PSignalData) -> Void
    private let announcePresence: @Sendable () -> Void
    private let peersSnapshot: @Sendable () -> [UUID]
    private let peerFactory = LKRTCPeerConnectionFactory()

    private var peerConnection: LKRTCPeerConnection?
    private var outboundChatChannel: LKRTCDataChannel?
    private var outboundActionCallChannel: LKRTCDataChannel?
    private var inboundChatChannel: LKRTCDataChannel?
    private var inboundActionCallChannel: LKRTCDataChannel?
    private var pendingRemoteCandidates: [LKRTCIceCandidate] = []
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

    func start() async throws {
        isStopping = false
        didReportDegrade = false
        notifiedConnectedPeers.removeAll()
        debug(
            "starting localPeer=\(localNodeID.uuidString.lowercased()) timeout=\(config.p2pAttemptTimeoutSeconds)s"
        )
        announcePresence()
        try createPeerConnection()

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
            try createOutboundDataChannels()
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
        outboundChatChannel?.close()
        outboundActionCallChannel?.close()
        inboundChatChannel?.close()
        inboundActionCallChannel?.close()
        peerConnection?.close()

        defer {
            pendingRemoteCandidates.removeAll()
            notifiedConnectedPeers.removeAll()
        }

        peerConnection = nil
        outboundChatChannel = nil
        outboundActionCallChannel = nil
        inboundChatChannel = nil
        inboundActionCallChannel = nil
        remotePeerID = nil
    }

    func requestP2PTrial() {
        debug("ignoring manual p2p trial: already using direct p2p transport")
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        let route = try route(for: envelope)
        let dataChannel: LKRTCDataChannel?
        switch route {
            case .chat:
                dataChannel = preferredChatChannel()
            case .actionCall:
                dataChannel = preferredActionCallChannel()
        }

        guard let dataChannel else {
            reportTransportDegraded("send failed: channel missing")
            throw P2PError.dataChannelCreateFailed(routeLabel(for: route))
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
            outboundLabel: outboundChatChannel?.label,
            outboundState: outboundChatChannel?.readyState.rawValue,
            inboundLabel: inboundChatChannel?.label,
            inboundState: inboundChatChannel?.readyState.rawValue,
            retainedChannels: [
                outboundChatChannel, outboundActionCallChannel,
                inboundChatChannel, inboundActionCallChannel,
            ].compactMap { $0 }.count,
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

    private func createOutboundDataChannels() throws {
        guard let peerConnection else {
            throw P2PError.peerConnectionCreateFailed
        }

        let chatChannelConfig = LKRTCDataChannelConfiguration()
        chatChannelConfig.isOrdered = true
        guard
            let chatChannel = peerConnection.dataChannel(
                forLabel: config.chatChannelLabel,
                configuration: chatChannelConfig
            )
        else {
            throw P2PError.dataChannelCreateFailed(config.chatChannelLabel)
        }
        chatChannel.delegate = self
        outboundChatChannel = chatChannel
        debug("created outbound chat channel label=\(chatChannel.label)")

        let actionChannelConfig = LKRTCDataChannelConfiguration()
        actionChannelConfig.isOrdered = true
        guard
            let actionChannel = peerConnection.dataChannel(
                forLabel: config.actionCallChannelLabel,
                configuration: actionChannelConfig
            )
        else {
            throw P2PError.dataChannelCreateFailed(
                config.actionCallChannelLabel
            )
        }
        actionChannel.delegate = self
        outboundActionCallChannel = actionChannel
        debug("created outbound action channel label=\(actionChannel.label)")
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
        let discoveredIDs =
            discovered
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        debug("target selection timed out discovered=[\(discoveredIDs)]")
        throw P2PError.noRemotePeerFound
    }

    private func waitForRequiredChannelsOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let chatOpened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.preferredChatChannel()
        }
        if !chatOpened {
            debug("timeout waiting for chat channel open")
            reportTransportDegraded(
                "handshake timeout waiting for chat channel"
            )
            return false
        }

        let actionOpened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.preferredActionCallChannel()
        }
        if !actionOpened {
            debug("timeout waiting for action channel open")
            reportTransportDegraded(
                "handshake timeout waiting for action channel"
            )
            return false
        }
        return true
    }

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

    private func preferredChatChannel() -> LKRTCDataChannel? {
        if let inboundChatChannel, inboundChatChannel.readyState == .open {
            return inboundChatChannel
        }
        return outboundChatChannel
    }

    private func preferredActionCallChannel() -> LKRTCDataChannel? {
        if let inboundActionCallChannel,
            inboundActionCallChannel.readyState == .open
        {
            return inboundActionCallChannel
        }
        return outboundActionCallChannel
    }

    private func route(for envelope: KeepTalkingP2PEnvelope) throws
        -> EnvelopeRoute
    {
        switch envelope.channel {
            case .chat:
                return .chat
            case .actionCall:
                return .actionCall
            case .signaling:
                throw P2PError.signalingInP2P
        }
    }

    private func routeLabel(for route: EnvelopeRoute) -> String {
        switch route {
            case .chat:
                return config.chatChannelLabel
            case .actionCall:
                return config.actionCallChannelLabel
        }
    }

    private func handleSignal(from: UUID, data: KeepTalkingP2PSignalData) {
        if let configuredRemote = remotePeerID, configuredRemote != from {
            debug(
                "ignoring signal from unexpected peer \(from.uuidString.lowercased())"
            )
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
        if dataChannel.label == config.chatChannelLabel {
            self.inboundChatChannel = dataChannel
            debug("bound inbound chat channel label=\(dataChannel.label)")
        } else if dataChannel.label == config.actionCallChannelLabel {
            self.inboundActionCallChannel = dataChannel
            debug("bound inbound action channel label=\(dataChannel.label)")
        }
    }

    func handleDataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
        guard
            dataChannel.label == config.chatChannelLabel
                || dataChannel.label == config.actionCallChannelLabel
        else {
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

    func handleDataChannelDidReceiveMessage(
        _ dataChannel: LKRTCDataChannel,
        buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        guard
            dataChannel.label == config.chatChannelLabel
                || dataChannel.label == config.actionCallChannelLabel
        else {
            return
        }

        if let envelope = try? JSONDecoder().decode(
            KeepTalkingP2PEnvelope.self,
            from: buffer.data
        ) {
            if case .message = envelope,
                dataChannel.label != config.chatChannelLabel
            {
                debug(
                    "ignored message envelope on non-chat channel label=\(dataChannel.label)"
                )
                return
            }
            onEnvelope?(envelope)
            return
        }

        if let text = String(data: buffer.data, encoding: .utf8) {
            onRawMessage?(text)
        } else {
            onRawMessage?("<\(buffer.data.count) bytes>")
        }
    }
}
