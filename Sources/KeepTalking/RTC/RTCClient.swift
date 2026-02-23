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

private struct LegacyKeepTalkingMessage: Codable {
    let from: String
    let text: String
}

final class KeepTalkingRTCClient: NSObject, @unchecked Sendable {
    private enum Target {
        static let publisher = 0
        static let subscriber = 1
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

        let rtcConfig = LKRTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.iceServers = []
        rtcConfig.continualGatheringPolicy = .gatherContinually

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "DtlsSrtpKeyAgreement": kLKRTCMediaConstraintsValueTrue
            ]
        )

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

        let localOffer = try await createOffer(on: publisher)
        debug(
            "local offer type=\(localOffer.type) sdpBytes=\(localOffer.sdp.utf8.count)"
        )
        try await setLocalDescription(localOffer, on: publisher)

        let answerPayload = try await signal.join(
            session: config.session,
            uid: config.node.uuidString,
            offer: localOffer
        )
        debug(
            "join answer type=\(answerPayload.type) sdpBytes=\(answerPayload.sdp.utf8.count)"
        )
        try await setRemoteDescription(answerPayload, on: publisher)
        flushPendingCandidates(for: Target.publisher)

        guard await waitForOutboundChannelOpen(timeoutSeconds: 8) else {
            throw RTCError.dataChannelNotOpen(config.channel)
        }
    }

    func stop() {
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        outboundChannel?.close()
        inboundChatChannel?.close()
        for peer in peerPool.values {
            peer.close()
        }
        peerPool.removeAll()
        outboundChannel = nil
        inboundChatChannel = nil
        retainedChannels.removeAll()
        pendingCandidates.removeAll()
        signal.close()
    }

    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws {
        guard let sendChannel = preferredSendChannel() else {
            throw RTCError.dataChannelCreateFailed(config.channel)
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
            retainedChannels: retainedChannels.count
        )
    }

    private func preferredSendChannel() -> LKRTCDataChannel? {
        if let inboundChatChannel, inboundChatChannel.readyState == .open {
            return inboundChatChannel
        }
        return outboundChannel
    }

    private func retainChannel(_ channel: LKRTCDataChannel) {
        retainedChannels[ObjectIdentifier(channel)] = channel
    }

    private func createOffer(on peer: LKRTCPeerConnection) async throws
        -> SessionDescriptionPayload
    {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [
                kLKRTCMediaConstraintsOfferToReceiveAudio:
                    kLKRTCMediaConstraintsValueFalse,
                kLKRTCMediaConstraintsOfferToReceiveVideo:
                    kLKRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { offer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let offer {
                    continuation.resume(returning: Self.toPayload(offer))
                } else {
                    continuation.resume(throwing: RTCError.missingSdp)
                }
            }
        }
    }

    private func createAnswer(on peer: LKRTCPeerConnection) async throws
        -> SessionDescriptionPayload
    {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [
                kLKRTCMediaConstraintsOfferToReceiveAudio:
                    kLKRTCMediaConstraintsValueFalse,
                kLKRTCMediaConstraintsOfferToReceiveVideo:
                    kLKRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            peer.answer(for: constraints) { answer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let answer {
                    continuation.resume(returning: Self.toPayload(answer))
                } else {
                    continuation.resume(throwing: RTCError.missingSdp)
                }
            }
        }
    }

    private func setLocalDescription(
        _ payload: SessionDescriptionPayload,
        on peer: LKRTCPeerConnection
    ) async throws {
        let type = try Self.sdpType(from: payload.type)
        let description = LKRTCSessionDescription(type: type, sdp: payload.sdp)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemoteDescription(
        _ payload: SessionDescriptionPayload,
        on peer: LKRTCPeerConnection
    ) async throws {
        let type = try Self.sdpType(from: payload.type)
        let description = LKRTCSessionDescription(type: type, sdp: payload.sdp)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
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
                try await setRemoteDescription(payload, on: subscriber)
                flushPendingCandidates(for: Target.subscriber)

                let answer = try await createAnswer(on: subscriber)
                debug(
                    "local answer generated type=\(answer.type) sdpBytes=\(answer.sdp.utf8.count)"
                )
                try await setLocalDescription(answer, on: subscriber)
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

        if peer.remoteDescription != nil {
            peer.add(candidate) { _ in }
            debug(
                "applied trickle target=\(target) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
            )
        } else {
            pendingCandidates[target, default: []].append(candidate)
            debug(
                "buffered trickle target=\(target) pending=\(pendingCandidates[target, default: []].count)"
            )
        }
    }

    private func flushPendingCandidates(for target: Int) {
        guard let peer = peer(for: target) else {
            debug("flush skipped target=\(target): peer missing")
            return
        }

        let pending = pendingCandidates[target, default: []]
        if !pending.isEmpty {
            debug("flush pending target=\(target) count=\(pending.count)")
        }
        for candidate in pending {
            peer.add(candidate) { _ in }
        }
        pendingCandidates[target] = []
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
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if let outboundChannel, outboundChannel.readyState == .open {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        debug("timeout waiting for outbound channel open")
        return false
    }

    private static func sdpType(from raw: String) throws -> LKRTCSdpType {
        switch raw.lowercased() {
        case "offer":
            return .offer
        case "answer":
            return .answer
        case "pranswer":
            return .prAnswer
        case "rollback":
            return .rollback
        default:
            throw RTCError.invalidSdpType(raw)
        }
    }

    private static func toPayload(_ description: LKRTCSessionDescription)
        -> SessionDescriptionPayload
    {
        let type: String
        switch description.type {
        case .offer:
            type = "offer"
        case .answer:
            type = "answer"
        case .prAnswer:
            type = "pranswer"
        case .rollback:
            type = "rollback"
        @unknown default:
            type = "offer"
        }
        return SessionDescriptionPayload(type: type, sdp: description.sdp)
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

        guard dataChannel.label == config.channel else {
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
                onMessage?(message)
                    debug("delivered chat sender=\(message.sender)")

            default:
                onEnvelope?(envelope)
                debug("delivered envelope \(envelope)")
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
