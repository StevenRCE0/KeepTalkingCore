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

    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onLog: (@Sendable (String) -> Void)? {
        didSet {
            signal.onLog = onLog
        }
    }
    /// Fires when a required data channel (chat/blob/actionCall) closes
    /// unexpectedly.  The Hybrid client uses this to know SFU health.
    var onTransportDegraded: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let config: KeepTalkingConfig
    private let signal: IonJsonRpcSignal
    private let peerFactory = LKRTCPeerConnectionFactory()
    private let stateQueue = DispatchQueue(label: "KeepTalking.rtc.state")

    private var peerPool: [Int: LKRTCPeerConnection] = [:]
    private var channels = RTCChannelSet()
    /// Keeps strong references to all channels so WebRTC doesn't deallocate them.
    private var retainedChannels: [ObjectIdentifier: LKRTCDataChannel] = [:]
    private var pendingCandidates: [Int: [LKRTCIceCandidate]] = [:]
    private var sentMessageCount = 0
    private var recvMessageCount = 0
    private var notifiedConnectedPeers = Set<UUID>()
    private var didReportDegrade = false

    private func reportTransportDegraded(_ reason: String) {
        guard !didReportDegrade else { return }
        didReportDegrade = true
        onTransportDegraded?(reason)
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateQueue.sync(execute: body)
    }

    init(config: KeepTalkingConfig) {
        self.config = config
        signal = IonJsonRpcSignal(url: config.signalURL)
        super.init()
    }

    func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [rtc] \(message)")
    }

    // MARK: - Lifecycle

    func start() async throws {
        notifiedConnectedPeers.removeAll()
        didReportDegrade = false
        RTCShared.configureForDataOnlyTransport()
        debug(
            "starting session=\(config.scopedSessionID) id=\(config.node.uuidString) context=\(config.contextID.uuidString.lowercased()) chat=\(config.chatChannelLabel) blob=\(config.blobChannelLabel) action=\(config.actionCallChannelLabel)"
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

        let targets = withState { () -> [Int] in
            peerPool[Target.publisher] = publisher
            peerPool[Target.subscriber] = subscriber
            return peerPool.keys.sorted()
        }
        debug("peer pool created targets=\(targets)")

        signal.onOffer = { [weak self] offer in
            self?.acceptRemoteOffer(offer)
        }
        signal.onTrickle = { [weak self] trickle in
            self?.acceptRemoteTrickle(trickle)
        }

        // ion-sfu API channel (retained but not routed)
        let apiChannelConfig = LKRTCDataChannelConfiguration()
        let apiChannel = publisher.dataChannel(
            forLabel: "ion-sfu",
            configuration: apiChannelConfig
        )
        apiChannel?.delegate = self
        if let apiChannel {
            retainChannel(apiChannel)
        }

        // Create outbound channels for each kind
        let channelDefs: [(KeepTalkingEnvelopeChannel, String)] = [
            (.signaling, config.signalingChannelLabel),
            (.chat, config.chatChannelLabel),
            (.blob, config.blobChannelLabel),
            (.actionCall, config.actionCallChannelLabel),
        ]

        for (kind, label) in channelDefs {
            let channelConfig = LKRTCDataChannelConfiguration()
            channelConfig.isOrdered = true
            guard
                let channel = publisher.dataChannel(
                    forLabel: label,
                    configuration: channelConfig
                )
            else {
                throw RTCError.dataChannelCreateFailed(label)
            }
            channel.delegate = self
            channels.setOutbound(channel, for: kind)
            retainChannel(channel)
            debug("created outbound channel kind=\(kind) label=\(label)")
        }

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
        channels.closeAll()
        let peers = withState { Array(peerPool.values) }
        for peer in peers {
            peer.close()
        }
        withState {
            peerPool.removeAll()
        }
        channels.removeAll()
        withState {
            retainedChannels.removeAll()
            pendingCandidates.removeAll()
            notifiedConnectedPeers.removeAll()
        }
        signal.close()
    }

    // MARK: - Transport protocol

    func requestP2PTrial() {
        debug(
            "ignoring manual p2p trial: sfu transport has no direct p2p upgrade path"
        )
    }

    func preferReliableRoute(reason: String) {
        debug("already on reliable route reason=\(reason)")
    }

    func currentRoute() -> KeepTalkingTransportRoute {
        .sfu
    }

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        let kind = envelope.channel
        guard let sendChannel = channels.preferred(for: kind) else {
            throw RTCError.dataChannelCreateFailed(config.label(for: kind))
        }

        guard sendChannel.readyState == .open else {
            throw RTCError.dataChannelNotOpen(sendChannel.label)
        }

        let payload =
            try KeepTalkingPacketTransportCrypto
            .outboundPayload(
                for: envelope,
                localNodeID: config.node,
                contextSecretProvider: contextSecretProvider
            )
        let packet = LKRTCDataBuffer(data: payload, isBinary: false)
        debug(
            "send envelope kind=\(envelope) bytes=\(payload.count) label=\(sendChannel.label) channelState=\(sendChannel.readyState.rawValue)"
        )
        if !sendChannel.sendData(packet) {
            throw RTCError.dataChannelNotOpen(sendChannel.label)
        }
        sentMessageCount += 1
    }

    /// Maximum bytes allowed in the SCTP send buffer before we wait for it
    /// to drain.  Keeping this well below the WebRTC default (16 MB) avoids
    /// the data channel being force-closed by the SCTP layer.
    private static let maxBufferedAmount: UInt64 = 128 * 1024

    func sendBlobData(
        _ data: Data,
        targetPeerNodeID: UUID?
    ) throws {
        guard let sendChannel = channels.preferred(for: .blob) else {
            let summary = channels.stateSummary(for: [.blob])
            debug(
                "blob send failed: no open blob channel \(summary)"
            )
            throw RTCError.dataChannelNotOpen(config.blobChannelLabel)
        }

        let packet = LKRTCDataBuffer(data: data, isBinary: true)
        if !sendChannel.sendData(packet) {
            debug(
                "blob sendData returned false label=\(sendChannel.label) bufferedAmount=\(sendChannel.bufferedAmount)"
            )
            throw RTCError.dataChannelNotOpen(sendChannel.label)
        }
        sentMessageCount += 1
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        let retainedChannelCount = withState { retainedChannels.count }
        let outChat = channels.preferred(for: .chat)
        return KeepTalkingRuntimeStats(
            sent: sentMessageCount,
            received: recvMessageCount,
            outboundLabel: outChat?.label,
            outboundState: outChat?.readyState.rawValue,
            inboundLabel: nil,
            inboundState: nil,
            retainedChannels: retainedChannelCount,
            route: "sfu"
        )
    }

    // MARK: - Internals

    private func retainChannel(_ channel: LKRTCDataChannel) {
        withState {
            retainedChannels[ObjectIdentifier(channel)] = channel
        }
    }

    private func channelKind(for label: String) -> KeepTalkingEnvelopeChannel? {
        if label == config.chatChannelLabel { return .chat }
        if label == config.blobChannelLabel { return .blob }
        if label == config.actionCallChannelLabel { return .actionCall }
        if label == config.signalingChannelLabel { return .signaling }
        return nil
    }

    private func isKnownChannel(_ label: String) -> Bool {
        channelKind(for: label) != nil
    }

    // MARK: - SDP / ICE

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

        var buffer = withState {
            pendingCandidates[target] ?? []
        }
        let applied = RTCShared.applyOrBufferCandidate(
            candidate,
            on: peer,
            buffer: &buffer
        )
        withState {
            pendingCandidates[target] = buffer
        }

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

        var buffer = withState {
            pendingCandidates[target] ?? []
        }
        let count = RTCShared.flushBufferedCandidates(on: peer, buffer: &buffer)
        withState {
            pendingCandidates[target] = buffer
        }
        if count > 0 {
            debug("flush pending target=\(target) count=\(count)")
        }
    }

    private func peer(for target: Int) -> LKRTCPeerConnection? {
        withState {
            peerPool[target]
        }
    }

    private func target(for peer: LKRTCPeerConnection) -> Int? {
        withState {
            for (target, pooledPeer) in peerPool where pooledPeer === peer {
                return target
            }
            return nil
        }
    }

    private func waitForRequiredChannelsOpen(timeoutSeconds: TimeInterval) async
        -> Bool
    {
        let kinds: [KeepTalkingEnvelopeChannel] = [.chat, .actionCall, .blob]
        for kind in kinds {
            let opened = await RTCShared.waitForOpenDataChannel(
                timeoutSeconds: timeoutSeconds
            ) { [weak self] in
                self?.channels.preferred(for: kind)
            }
            if !opened {
                debug("timeout waiting for outbound \(kind) channel open")
                return false
            }
        }
        return true
    }

    // MARK: - Peer connection delegate handlers

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
        switch newState {
            case .failed:
                reportTransportDegraded("ice failed target=\(target)")
            case .closed:
                reportTransportDegraded("ice closed target=\(target)")
            default:
                break
        }
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
        if let kind = channelKind(for: dataChannel.label) {
            channels.setInbound(dataChannel, for: kind)
            debug("bound inbound channel kind=\(kind) label=\(dataChannel.label)")
        }
    }

    // MARK: - Data channel delegate handlers

    /// Required channel kinds — if any of these close, the transport is degraded.
    private static let requiredChannels: [KeepTalkingEnvelopeChannel] = [
        .chat, .blob, .actionCall,
    ]

    func handleDataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debug(
            "channel state label=\(dataChannel.label) state=\(dataChannel.readyState.rawValue)"
        )
        switch dataChannel.readyState {
            case .closing:
                channels.removeChannel(dataChannel)
            case .closed:
                channels.removeChannel(dataChannel)
                if let kind = channelKind(for: dataChannel.label),
                    Self.requiredChannels.contains(kind)
                {
                    debug(
                        "required channel lost kind=\(kind) label=\(dataChannel.label)"
                    )
                    reportTransportDegraded(
                        "required channel closed: \(dataChannel.label)"
                    )
                }
            default:
                break
        }
    }

    func handleDataChannelDidReceiveMessage(
        _ dataChannel: LKRTCDataChannel,
        buffer: LKRTCDataBuffer
    ) {
        recvMessageCount += 1
        debug(
            "recv dc label=\(dataChannel.label) bytes=\(buffer.data.count) binary=\(buffer.isBinary)"
        )
        guard isKnownChannel(dataChannel.label) else {
            if let text = String(data: buffer.data, encoding: .utf8) {
                debug(
                    "ignored unexpected label=\(dataChannel.label) text=\(text)"
                )
            } else {
                debug(
                    "ignored unexpected label=\(dataChannel.label) non-utf8-bytes=\(buffer.data.count)"
                )
            }
            return
        }

        do {
            if let envelope =
                try KeepTalkingPacketTransportCrypto
                .inboundEnvelope(
                    from: buffer.data,
                    contextSecretProvider: contextSecretProvider
                )
            {
                reportConnectedPeers(from: envelope)
                let expectedLabel = config.label(for: envelope.channel)
                guard dataChannel.label == expectedLabel else {
                    debug(
                        "ignored envelope on unexpected channel label=\(dataChannel.label) expected=\(expectedLabel)"
                    )
                    return
                }

                onEnvelope?(envelope)
                debug(
                    "delivered envelope label=\(dataChannel.label) \(envelope)"
                )
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
            debug(
                "recv blob bytes=\(buffer.data.count) label=\(dataChannel.label) channelState=\(dataChannel.readyState.rawValue)"
            )
            onBlobData?(buffer.data)
            return
        }

        if let text = String(data: buffer.data, encoding: .utf8) {
            debug("envelope decode failed; raw utf8=\(text)")
            onRawMessage?(text)
        } else {
            debug("envelope decode failed; non-utf8 bytes=\(buffer.data.count)")
            onRawMessage?("<\(buffer.data.count) bytes>")
        }
    }

    // MARK: - Peer tracking

    private func reportConnectedPeers(from envelope: any KeepTalkingEnvelope) {
        for nodeID in envelope.participantNodeIDs {
            reportPeerConnected(nodeID)
        }
    }

    private func reportPeerConnected(_ nodeID: UUID) {
        guard nodeID != config.node else { return }
        let inserted = withState {
            notifiedConnectedPeers.insert(nodeID).inserted
        }
        guard inserted else { return }
        debug("peer reachable node=\(nodeID.uuidString.lowercased())")
        onPeerConnect?(nodeID)
    }
}
