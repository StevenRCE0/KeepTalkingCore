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
    private enum ChannelLabel {
        static let signaling = "keep-talking.signaling"
    }

    var onMessage: (@Sendable (KeepTalkingContextMessage) -> Void)?
    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onLog: (@Sendable (String) -> Void)? {
        didSet {
            signal.onLog = onLog
        }
    }

    private let config: KeepTalkingConfig
    private let signal: IonJsonRpcSignal
    private let peerFactory = LKRTCPeerConnectionFactory()

    private var peerPool: [Int: LKRTCPeerConnection] = [:]
    private var outboundChannel: LKRTCDataChannel?
    private var inboundChatChannel: LKRTCDataChannel?
    private var outboundSignalingChannel: LKRTCDataChannel?
    private var inboundSignalingChannel: LKRTCDataChannel?
    private var retainedChannels: [ObjectIdentifier: LKRTCDataChannel] = [:]
    private var pendingCandidates: [Int: [LKRTCIceCandidate]] = [:]
    private var sentMessageCount = 0
    private var recvMessageCount = 0

    init(config: KeepTalkingConfig) {
        self.config = config
        signal = IonJsonRpcSignal(url: config.signalURL)
        super.init()
    }

    private func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [rtc] \(message)")
    }

    func start() async throws {
        debug(
            "starting session=\(config.session) id=\(config.node.uuidString) channel=\(config.channel)"
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
                forLabel: ChannelLabel.signaling,
                configuration: signalingChannelConfig
            )
        else {
            throw RTCError.dataChannelCreateFailed(ChannelLabel.signaling)
        }
        signalingChannel.delegate = self
        outboundSignalingChannel = signalingChannel
        retainChannel(signalingChannel)
        debug("created signaling channel label=\(signalingChannel.label)")

        let chatChannelConfig = LKRTCDataChannelConfiguration()
        chatChannelConfig.isOrdered = true
        guard
            let chatChannel = publisher.dataChannel(
                forLabel: config.channel,
                configuration: chatChannelConfig
            )
        else {
            throw RTCError.dataChannelCreateFailed(config.channel)
        }

        chatChannel.delegate = self
        outboundChannel = chatChannel
        retainChannel(chatChannel)
        debug("created outbound data channel label=\(chatChannel.label)")

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
            session: config.session,
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

        guard await waitForOutboundChannelOpen(timeoutSeconds: 8) else {
            throw RTCError.dataChannelNotOpen(config.channel)
        }
    }

    func stop() {
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        outboundChannel?.close()
        inboundChatChannel?.close()
        outboundSignalingChannel?.close()
        inboundSignalingChannel?.close()
        for peer in peerPool.values {
            peer.close()
        }
        peerPool.removeAll()
        outboundChannel = nil
        inboundChatChannel = nil
        outboundSignalingChannel = nil
        inboundSignalingChannel = nil
        retainedChannels.removeAll()
        pendingCandidates.removeAll()
        signal.close()
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        let useSignalingChannel: Bool
        switch envelope {
        case .p2pSignal, .p2pPresence:
            useSignalingChannel = true
        default:
            useSignalingChannel = false
        }

        let sendChannel: LKRTCDataChannel?
        if useSignalingChannel {
            sendChannel = preferredSignalingChannel()
        } else {
            sendChannel = preferredSendChannel()
        }
        guard let sendChannel else {
            throw RTCError.dataChannelCreateFailed(
                useSignalingChannel ? ChannelLabel.signaling : config.channel
            )
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
            outboundLabel: outboundChannel?.label,
            outboundState: outboundChannel?.readyState.rawValue,
            inboundLabel: inboundChatChannel?.label,
            inboundState: inboundChatChannel?.readyState.rawValue,
            retainedChannels: retainedChannels.count,
            route: "sfu"
        )
    }

    private func preferredSendChannel() -> LKRTCDataChannel? {
        if let inboundChatChannel, inboundChatChannel.readyState == .open {
            return inboundChatChannel
        }
        return outboundChannel
    }

    private func preferredSignalingChannel() -> LKRTCDataChannel? {
        if let inboundSignalingChannel, inboundSignalingChannel.readyState == .open
        {
            return inboundSignalingChannel
        }
        return outboundSignalingChannel
    }

    private func retainChannel(_ channel: LKRTCDataChannel) {
        retainedChannels[ObjectIdentifier(channel)] = channel
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

    private func waitForOutboundChannelOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let opened = await RTCShared.waitForOpenDataChannel(
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            self?.outboundChannel
        }
        if !opened {
            debug("timeout waiting for outbound channel open")
        }
        return opened
    }

}

extension KeepTalkingRTCClient: LKRTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("signaling state target=\(target) state=\(stateChanged.rawValue)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug(
            "ice connection state target=\(target) state=\(newState.rawValue)"
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("ice gathering state target=\(target) state=\(newState.rawValue)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
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

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("removed candidates target=\(target) count=\(candidates.count)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        let target = target(for: peerConnection) ?? -1
        debug("should negotiate target=\(target)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd stream: LKRTCMediaStream
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("stream added target=\(target) streamId=\(stream.streamId)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove stream: LKRTCMediaStream
    ) {
        let target = target(for: peerConnection) ?? -1
        debug("stream removed target=\(target) streamId=\(stream.streamId)")
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        let target = target(for: peerConnection) ?? -1
        dataChannel.delegate = self
        retainChannel(dataChannel)
        debug(
            "inbound data channel opened label=\(dataChannel.label) target=\(target)"
        )
        if dataChannel.label == config.channel {
            inboundChatChannel = dataChannel
            debug("bound inbound chat channel label=\(dataChannel.label)")
        } else if dataChannel.label == ChannelLabel.signaling {
            inboundSignalingChannel = dataChannel
            debug("bound inbound signaling channel label=\(dataChannel.label)")
        }
    }
}

extension KeepTalkingRTCClient: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
    }

    func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        debug(
            "recv dc label=\(dataChannel.label) bytes=\(buffer.data.count) binary=\(buffer.isBinary)"
        )

        guard
            dataChannel.label == config.channel
                || dataChannel.label == ChannelLabel.signaling
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
            switch envelope {
            case .message(let message):
                if dataChannel.label == config.channel {
                    onMessage?(message)
                    debug("delivered chat sender=\(message.sender)")
                } else {
                    debug("ignored message envelope on signaling channel")
                }

            default:
                onEnvelope?(envelope)
                debug("delivered envelope label=\(dataChannel.label) \(envelope)")
            }
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
}
