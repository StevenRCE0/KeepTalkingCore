import Foundation
import LiveKitWebRTC

enum RTCError: LocalizedError {
    case peerConnectionCreateFailed
    case invalidSdpType(String)
    case missingSdp
    case dataChannelCreateFailed(String)
    case dataChannelNotOpen(String)

    var errorDescription: String? {
        switch self {
            case .peerConnectionCreateFailed:
                return "Failed to create LKRTCPeerConnection."
            case .invalidSdpType(let type):
                return "Invalid SDP type '\(type)'."
            case .missingSdp:
                return "Missing SDP."
            case .dataChannelCreateFailed(let label):
                return "Failed to create data channel '\(label)'."
            case .dataChannelNotOpen(let label):
                return "Data channel '\(label)' is not open yet."
        }
    }
}

final class KeepTalkingRTCClient: NSObject, KeepTalkingTransportClient,
    @unchecked Sendable
{
    private enum Target {
        static let publisher = 0
        static let subscriber = 1
    }
    private enum EnvelopeRoute {
        case chat
        case actionCall
        case signaling
    }

    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onLog: (@Sendable (String) -> Void)? {
        didSet {
            signal.onLog = onLog
        }
    }

    private let config: KeepTalkingConfig
    private let signal: IonJsonRpcSignal
    private let peerFactory = LKRTCPeerConnectionFactory()

    private var peerPool: [Int: LKRTCPeerConnection] = [:]
    private var outboundChatChannel: LKRTCDataChannel?
    private var outboundActionCallChannel: LKRTCDataChannel?
    private var inboundChatChannel: LKRTCDataChannel?
    private var inboundActionCallChannel: LKRTCDataChannel?
    private var outboundSignalingChannel: LKRTCDataChannel?
    private var inboundSignalingChannel: LKRTCDataChannel?
    private var retainedChannels: [ObjectIdentifier: LKRTCDataChannel] = [:]
    private var pendingCandidates: [Int: [LKRTCIceCandidate]] = [:]
    private var sentMessageCount = 0
    private var recvMessageCount = 0
    private var notifiedConnectedPeers = Set<UUID>()

    init(config: KeepTalkingConfig) {
        self.config = config
        signal = IonJsonRpcSignal(url: config.signalURL)
        super.init()
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [rtc] \(message)")
    }

    func start() async throws {
        notifiedConnectedPeers.removeAll()
        debug(
            "starting session=\(config.scopedSessionID) id=\(config.node.uuidString) context=\(config.contextID.uuidString.lowercased()) chat=\(config.chatChannelLabel) action=\(config.actionCallChannelLabel)"
        )
        try await signal.connect()

        let rtcConfig = RTCShared.makeRTCConfiguration(
            iceServerURLs: config.p2pStunServers
        )
        let constraints = RTCShared.makePeerConnectionConstraints()

        guard
            let publisher = peerFactory.peerConnection(
                with: rtcConfig,
                constraints: constraints,
                delegate: self
            ),
            let subscriber = peerFactory.peerConnection(
                with: rtcConfig,
                constraints: constraints,
                delegate: self
            )
        else {
            throw RTCError.peerConnectionCreateFailed
        }

        peerPool[Target.publisher] = publisher
        peerPool[Target.subscriber] = subscriber
        debug("peer pool created targets=\(peerPool.keys.sorted())")

        signal.onOffer = { [weak self] offer in
            self?.acceptRemoteOffer(offer)
        }
        signal.onTrickle = { [weak self] trickle in
            self?.acceptRemoteTrickle(trickle)
        }

        let apiChannelConfig = LKRTCDataChannelConfiguration()
        let apiChannel = publisher.dataChannel(
            forLabel: "ion-sfu",
            configuration: apiChannelConfig
        )
        apiChannel?.delegate = self
        if let apiChannel {
            retainChannel(apiChannel)
        }

        let signalingChannelConfig = LKRTCDataChannelConfiguration()
        signalingChannelConfig.isOrdered = true
        guard
            let signalingChannel = publisher.dataChannel(
                forLabel: config.signalingChannelLabel,
                configuration: signalingChannelConfig
            )
        else {
            throw RTCError.dataChannelCreateFailed(config.signalingChannelLabel)
        }
        signalingChannel.delegate = self
        outboundSignalingChannel = signalingChannel
        retainChannel(signalingChannel)
        debug("created signaling channel label=\(signalingChannel.label)")

        let chatChannelConfig = LKRTCDataChannelConfiguration()
        chatChannelConfig.isOrdered = true
        guard
            let chatChannel = publisher.dataChannel(
                forLabel: config.chatChannelLabel,
                configuration: chatChannelConfig
            )
        else {
            throw RTCError.dataChannelCreateFailed(config.chatChannelLabel)
        }

        chatChannel.delegate = self
        outboundChatChannel = chatChannel
        retainChannel(chatChannel)
        debug("created outbound chat channel label=\(chatChannel.label)")

        let actionCallChannelConfig = LKRTCDataChannelConfiguration()
        actionCallChannelConfig.isOrdered = true
        guard
            let actionCallChannel = publisher.dataChannel(
                forLabel: config.actionCallChannelLabel,
                configuration: actionCallChannelConfig
            )
        else {
            throw RTCError.dataChannelCreateFailed(
                config.actionCallChannelLabel
            )
        }

        actionCallChannel.delegate = self
        outboundActionCallChannel = actionCallChannel
        retainChannel(actionCallChannel)
        debug(
            "created outbound action channel label=\(actionCallChannel.label)"
        )

        let localOffer = try await RTCShared.createOffer(
            on: publisher,
            missingSdpError: RTCError.missingSdp
        )
        debug(
            "local offer type=\(localOffer.type) sdpBytes=\(localOffer.sdp.utf8.count)"
        )
        try await RTCShared.setLocalDescription(
            localOffer,
            on: publisher,
            invalidSdpTypeError: RTCError.invalidSdpType
        )

        let answerPayload = try await signal.join(
            session: config.scopedSessionID,
            uid: config.node.uuidString,
            offer: localOffer
        )
        debug(
            "join answer type=\(answerPayload.type) sdpBytes=\(answerPayload.sdp.utf8.count)"
        )
        try await RTCShared.setRemoteDescription(
            answerPayload,
            on: publisher,
            invalidSdpTypeError: RTCError.invalidSdpType
        )
        flushPendingCandidates(for: Target.publisher)

        guard await waitForRequiredChannelsOpen(timeoutSeconds: 8) else {
            throw RTCError.dataChannelNotOpen(config.chatChannelLabel)
        }
    }

    func stop() {
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        outboundChatChannel?.close()
        outboundActionCallChannel?.close()
        inboundChatChannel?.close()
        inboundActionCallChannel?.close()
        outboundSignalingChannel?.close()
        inboundSignalingChannel?.close()
        for peer in peerPool.values {
            peer.close()
        }
        peerPool.removeAll()
        outboundChatChannel = nil
        outboundActionCallChannel = nil
        inboundChatChannel = nil
        inboundActionCallChannel = nil
        outboundSignalingChannel = nil
        inboundSignalingChannel = nil
        retainedChannels.removeAll()
        pendingCandidates.removeAll()
        notifiedConnectedPeers.removeAll()
        signal.close()
    }

    func requestP2PTrial() {
        debug(
            "ignoring manual p2p trial: sfu transport has no direct p2p upgrade path"
        )
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        let route = route(for: envelope)

        let sendChannel: LKRTCDataChannel?
        switch route {
            case .signaling:
                sendChannel = preferredSignalingChannel()
            case .chat:
                sendChannel = preferredChatChannel()
            case .actionCall:
                sendChannel = preferredActionCallChannel()
        }

        guard let sendChannel else {
            throw RTCError.dataChannelCreateFailed(routeLabel(for: route))
        }

        guard sendChannel.readyState == .open else {
            throw RTCError.dataChannelNotOpen(sendChannel.label)
        }

        let payload = try JSONEncoder().encode(envelope)
        let packet = LKRTCDataBuffer(data: payload, isBinary: false)
        debug(
            "send envelope kind=\(envelope) bytes=\(payload.count) label=\(sendChannel.label) channelState=\(sendChannel.readyState.rawValue)"
        )
        if !sendChannel.sendData(packet) {
            throw RTCError.dataChannelNotOpen(sendChannel.label)
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
            retainedChannels: retainedChannels.count,
            route: "sfu"
        )
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

    private func preferredSignalingChannel() -> LKRTCDataChannel? {
        if let inboundSignalingChannel,
            inboundSignalingChannel.readyState == .open
        {
            return inboundSignalingChannel
        }
        return outboundSignalingChannel
    }

    private func retainChannel(_ channel: LKRTCDataChannel) {
        retainedChannels[ObjectIdentifier(channel)] = channel
    }

    private func route(for envelope: KeepTalkingP2PEnvelope) -> EnvelopeRoute {
        switch envelope {
            case .message, .node, .nodeStatus, .encryptedNodeStatus, .context:
                return .chat
            case .p2pSignal, .p2pPresence:
                return .signaling
            case .actionCallRequest,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedActionCallResult,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult:
                return .actionCall
        }
    }

    private func routeLabel(for route: EnvelopeRoute) -> String {
        switch route {
            case .chat:
                return config.chatChannelLabel
            case .actionCall:
                return config.actionCallChannelLabel
            case .signaling:
                return config.signalingChannelLabel
        }
    }

    private func acceptRemoteOffer(_ payload: SessionDescriptionPayload) {
        guard let subscriber = peer(for: Target.subscriber) else {
            debug("drop remote offer: subscriber missing")
            return
        }
        debug(
            "remote offer received type=\(payload.type) sdpBytes=\(payload.sdp.utf8.count)"
        )

        Task { [weak self, subscriber] in
            guard let self else { return }
            do {
                try await RTCShared.setRemoteDescription(
                    payload,
                    on: subscriber,
                    invalidSdpTypeError: RTCError.invalidSdpType
                )
                flushPendingCandidates(for: Target.subscriber)

                let answer = try await RTCShared.createAnswer(
                    on: subscriber,
                    missingSdpError: RTCError.missingSdp
                )
                debug(
                    "local answer generated type=\(answer.type) sdpBytes=\(answer.sdp.utf8.count)"
                )
                try await RTCShared.setLocalDescription(
                    answer,
                    on: subscriber,
                    invalidSdpTypeError: RTCError.invalidSdpType
                )
                signal.answer(answer)
                debug("answer sent")
            } catch {
                debug(
                    "failed to answer remote offer error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func acceptRemoteTrickle(_ trickle: TricklePayload) {
        let target = trickle.target
        guard let peer = peer(for: target) else {
            debug("drop trickle target=\(target): peer missing")
            return
        }

        let candidate = LKRTCIceCandidate(
            sdp: trickle.candidate.candidate,
            sdpMLineIndex: trickle.candidate.sdpMLineIndex ?? 0,
            sdpMid: trickle.candidate.sdpMid
        )

        var buffer = pendingCandidates[target, default: []]
        let applied = RTCShared.applyOrBufferCandidate(
            candidate,
            on: peer,
            buffer: &buffer
        )
        pendingCandidates[target] = buffer

        if applied {
            debug(
                "applied trickle target=\(target) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
            )
        } else {
            debug("buffered trickle target=\(target) pending=\(buffer.count)")
        }
    }

    private func flushPendingCandidates(for target: Int) {
        guard let peer = peer(for: target) else {
            debug("flush skipped target=\(target): peer missing")
            return
        }

        var buffer = pendingCandidates[target, default: []]
        let count = RTCShared.flushBufferedCandidates(on: peer, buffer: &buffer)
        pendingCandidates[target] = buffer
        if count > 0 {
            debug("flush pending target=\(target) count=\(count)")
        }
    }

    private func peer(for target: Int) -> LKRTCPeerConnection? {
        peerPool[target]
    }

    private func target(for peer: LKRTCPeerConnection) -> Int? {
        for (target, pooledPeer) in peerPool where pooledPeer === peer {
            return target
        }
        return nil
    }

    private func waitForRequiredChannelsOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let chatOpened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.outboundChatChannel
        }
        if !chatOpened {
            debug("timeout waiting for outbound chat channel open")
            return false
        }

        let actionOpened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.outboundActionCallChannel
        }
        if !actionOpened {
            debug("timeout waiting for outbound action channel open")
            return false
        }
        return true
    }

    func handlePeerConnectionSignalingStateChange(
        _ peerConnection: LKRTCPeerConnection,
        stateChanged: LKRTCSignalingState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("signaling state target=\(target) state=\(stateChanged.rawValue)")
    }

    func handlePeerConnectionIceConnectionStateChange(
        _ peerConnection: LKRTCPeerConnection,
        newState: LKRTCIceConnectionState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug(
            "ice connection state target=\(target) state=\(newState.rawValue)"
        )
    }

    func handlePeerConnectionIceGatheringStateChange(
        _ peerConnection: LKRTCPeerConnection,
        newState: LKRTCIceGatheringState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("ice gathering state target=\(target) state=\(newState.rawValue)")
    }

    func handlePeerConnectionDidGenerateCandidate(
        _ peerConnection: LKRTCPeerConnection,
        candidate: LKRTCIceCandidate
    ) {
        guard let target = target(for: peerConnection) else {
            return
        }

        let payload = TricklePayload(
            target: target,
            candidate: IceCandidatePayload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex,
                usernameFragment: nil
            )
        )
        debug(
            "local trickle target=\(target) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
        )
        signal.trickle(payload)
    }

    func handlePeerConnectionDidRemoveCandidates(
        _ peerConnection: LKRTCPeerConnection,
        candidates: [LKRTCIceCandidate]
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("removed candidates target=\(target) count=\(candidates.count)")
    }

    func handlePeerConnectionShouldNegotiate(
        _ peerConnection: LKRTCPeerConnection
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("should negotiate target=\(target)")
    }

    func handlePeerConnectionDidAddStream(
        _ peerConnection: LKRTCPeerConnection,
        stream: LKRTCMediaStream
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("stream added target=\(target) streamId=\(stream.streamId)")
    }

    func handlePeerConnectionDidRemoveStream(
        _ peerConnection: LKRTCPeerConnection,
        stream: LKRTCMediaStream
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("stream removed target=\(target) streamId=\(stream.streamId)")
    }

    func handlePeerConnectionDidOpenDataChannel(
        _ peerConnection: LKRTCPeerConnection,
        dataChannel: LKRTCDataChannel
    ) {
        let target = target(for: peerConnection) ?? -1
        dataChannel.delegate = self
        retainChannel(dataChannel)
        debug(
            "inbound data channel opened label=\(dataChannel.label) target=\(target)"
        )
        if dataChannel.label == config.chatChannelLabel {
            inboundChatChannel = dataChannel
            debug("bound inbound chat channel label=\(dataChannel.label)")
        } else if dataChannel.label == config.actionCallChannelLabel {
            inboundActionCallChannel = dataChannel
            debug("bound inbound action channel label=\(dataChannel.label)")
        } else if dataChannel.label == config.signalingChannelLabel {
            inboundSignalingChannel = dataChannel
            debug("bound inbound signaling channel label=\(dataChannel.label)")
        }
    }

    func handleDataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
    }

    func handleDataChannelDidReceiveMessage(
        _ dataChannel: LKRTCDataChannel,
        buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        debug(
            "recv dc label=\(dataChannel.label) bytes=\(buffer.data.count) binary=\(buffer.isBinary)"
        )

        guard
            dataChannel.label == config.chatChannelLabel
                || dataChannel.label == config.actionCallChannelLabel
                || dataChannel.label == config.signalingChannelLabel
        else {
            if let text = String(data: buffer.data, encoding: .utf8) {
                debug(
                    "ignored non-chat label=\(dataChannel.label) text=\(text)"
                )
            } else {
                debug(
                    "ignored non-chat label=\(dataChannel.label) non-utf8-bytes=\(buffer.data.count)"
                )
            }
            return
        }

        if let envelope = try? JSONDecoder().decode(
            KeepTalkingP2PEnvelope.self,
            from: buffer.data
        ) {
            reportConnectedPeers(from: envelope)
            if case .message = envelope,
                dataChannel.label != config.chatChannelLabel
            {
                debug(
                    "ignored message envelope on non-chat channel label=\(dataChannel.label)"
                )
                return
            }

            onEnvelope?(envelope)
            debug(
                "delivered envelope label=\(dataChannel.label) \(envelope)"
            )
            return
        }

        if let text = String(data: buffer.data, encoding: .utf8) {
            debug("chat decode failed; raw utf8=\(text)")
            onRawMessage?(text)
        } else {
            debug("chat decode failed; non-utf8 bytes=\(buffer.data.count)")
            onRawMessage?("<\(buffer.data.count) bytes>")
        }
    }

    private func reportConnectedPeers(from envelope: KeepTalkingP2PEnvelope) {
        switch envelope {
            case .message(let message):
                if case .node(let nodeID) = message.sender {
                    reportPeerConnected(nodeID)
                }
            case .context(let context):
                for message in context.messages {
                    if case .node(let nodeID) = message.sender {
                        reportPeerConnected(nodeID)
                    }
                }
            case .node(let node):
                if let nodeID = node.id {
                    reportPeerConnected(nodeID)
                }
            case .nodeStatus(let status):
                if let nodeID = status.node.id {
                    reportPeerConnected(nodeID)
                }
            case .encryptedNodeStatus(let envelope):
                reportPeerConnected(envelope.senderNodeID)
                reportPeerConnected(envelope.recipientNodeID)
            case .actionCallRequest(let request):
                reportPeerConnected(request.callerNodeID)
                reportPeerConnected(request.targetNodeID)
            case .actionCallResult(let result):
                reportPeerConnected(result.callerNodeID)
                reportPeerConnected(result.targetNodeID)
            case .encryptedActionCallRequest(let envelope):
                reportPeerConnected(envelope.senderNodeID)
                reportPeerConnected(envelope.recipientNodeID)
            case .encryptedActionCallResult(let envelope):
                reportPeerConnected(envelope.senderNodeID)
                reportPeerConnected(envelope.recipientNodeID)
            case .actionCatalogRequest(let request):
                reportPeerConnected(request.callerNodeID)
                reportPeerConnected(request.targetNodeID)
            case .actionCatalogResult(let result):
                reportPeerConnected(result.callerNodeID)
                reportPeerConnected(result.targetNodeID)
            case .encryptedActionCatalogRequest(let envelope):
                reportPeerConnected(envelope.senderNodeID)
                reportPeerConnected(envelope.recipientNodeID)
            case .encryptedActionCatalogResult(let envelope):
                reportPeerConnected(envelope.senderNodeID)
                reportPeerConnected(envelope.recipientNodeID)
            case .p2pSignal(let signal):
                reportPeerConnected(signal.from)
            case .p2pPresence(let presence):
                reportPeerConnected(presence.node)
        }
    }

    private func reportPeerConnected(_ nodeID: UUID) {
        guard nodeID != config.node else { return }
        let inserted = notifiedConnectedPeers.insert(nodeID).inserted
        guard inserted else { return }
        debug("peer reachable node=\(nodeID.uuidString.lowercased())")
        onPeerConnect?(nodeID)
    }
}
