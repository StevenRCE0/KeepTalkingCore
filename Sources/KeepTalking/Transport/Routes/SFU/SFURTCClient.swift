import Foundation
@preconcurrency import LiveKitWebRTC

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
    /// The ion-sfu API channel created by the server on the subscriber peer.
    /// Stored separately because it is not part of RTCChannelSet.
    private var ionSFUAPIChannel: LKRTCDataChannel?

    /// Cached ICE connection states keyed by `Target.publisher`/`Target.subscriber`.
    /// Reading `LKRTCPeerConnection.iceConnectionState` directly dispatches
    /// synchronously to WebRTC's signaling thread; under reconnect storms that
    /// thread is busy and the getter blocks the caller. `runtimeStats()` is
    /// invoked from MainActor (via `transportStatus(for:)` in the UI), so a
    /// blocking read there freezes the UI. We update the cache from the
    /// delegate callback (`peerConnection didChange newState:`) and only the
    /// cache is read at stats time.
    private var cachedIceConnectionStates: [Int: LKRTCIceConnectionState] = [:]

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
            "starting session=\(config.scopedSessionID) id=\(config.node.uuidString) context=\(config.contextID.uuidString.lowercased()) chat=\(config.chatChannelLabel) blob=\(config.blobChannelLabel) action=\(config.actionCallChannelLabel) iceServers=\(config.sfuIceServers)"
        )
        try await signal.connect()

        let rtcConfig = RTCShared.makeRTCConfiguration(
            iceServerURLs: config.sfuIceServers,
            iceTransportPolicy: .all
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
        let answerEmbedded = answerPayload.sdp.components(separatedBy: "a=candidate:").count - 1
        debug(
            "join answer type=\(answerPayload.type) sdpBytes=\(answerPayload.sdp.utf8.count) embeddedCandidates=\(answerEmbedded)"
        )
        try await RTCShared.setRemoteDescription(
            answerPayload,
            on: publisher,
            invalidSdpTypeError: RTCError.invalidSdpType
        )
        // Flush immediately so ICE checks can start against the server's candidates
        // without waiting on the API channel poll below.
        flushPendingCandidates(for: Target.publisher)

        // Wait for the ion-sfu API channel that the server opens on the subscriber side.
        // This signals the server has processed the join and is ready to relay.
        let apiOpened = await RTCShared.waitForOpenDataChannel(timeoutSeconds: 10) { [weak self] in
            self?.ionSFUAPIChannel
        }
        if !apiOpened {
            debug("timeout waiting for ion-sfu api channel - checking health anyway")
        } else {
            debug("ion-sfu api channel confirmed open")
        }

        guard await waitForRequiredChannelsOpen(timeoutSeconds: 15) else {
            throw RTCError.dataChannelNotOpen(config.chatChannelLabel)
        }
    }

    func stop() {
        debug("stopping sent=\(sentMessageCount) recv=\(recvMessageCount)")
        ionSFUAPIChannel = nil
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
            cachedIceConnectionStates.removeAll()
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
        // Read the cached ICE state instead of `peer.iceConnectionState` —
        // the latter blocks on WebRTC's signaling thread (see
        // `cachedIceConnectionStates` doc).
        let pubIce = withState { cachedIceConnectionStates[Target.publisher] }
        let subIce = withState { cachedIceConnectionStates[Target.subscriber] }
        return KeepTalkingRuntimeStats(
            sent: sentMessageCount,
            received: recvMessageCount,
            outboundLabel: outChat?.label,
            outboundState: outChat?.readyState.rawValue,
            inboundLabel: nil,
            inboundState: nil,
            retainedChannels: retainedChannelCount,
            route: "sfu",
            publisherIceState: pubIce.map(iceStateName),
            subscriberIceState: subIce.map(iceStateName)
        )
    }

    private func iceStateName(_ state: LKRTCIceConnectionState) -> String {
        switch state {
            case .new: return "new"
            case .checking: return "checking"
            case .connected: return "connected"
            case .completed: return "completed"
            case .failed: return "failed"
            case .disconnected: return "disconnected"
            case .closed: return "closed"
            default: return "unknown(\(state.rawValue))"
        }
    }

    /// Extracts "typ <candidateType> proto <protocol>" from a raw SDP candidate string.
    /// SDP format: "candidate:<foundation> <component> <protocol> <priority> <address> <port> typ <type> ..."
    private static func parseCandidateType(from sdp: String) -> String {
        let parts = sdp.split(separator: " ")
        var result = ""
        for (i, part) in parts.enumerated() {
            if part == "typ", i + 1 < parts.count {
                result += "typ=\(parts[i + 1])"
            }
            if part == "relayProtocol", i + 1 < parts.count {
                result += " relay=\(parts[i + 1])"
            }
        }
        // protocol is the 3rd token (index 2)
        if parts.count > 2 {
            result = "proto=\(parts[2]) \(result)"
        }
        return result.isEmpty ? sdp : result.trimmingCharacters(in: .whitespaces)
    }

    func isReady() -> Bool {
        Self.requiredChannels.allSatisfy { channels.isOpen(for: $0) }
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
        let offerEmbedded = payload.sdp.components(separatedBy: "a=candidate:").count - 1
        debug(
            "remote offer received type=\(payload.type) sdpBytes=\(payload.sdp.utf8.count) embeddedCandidates=\(offerEmbedded)"
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

    func target(for peer: LKRTCPeerConnection) -> Int? {
        withState {
            for (target, pooledPeer) in peerPool where pooledPeer === peer {
                return target
            }
            return nil
        }
    }

    /// Collect and log ICE candidates + selected pair from both peer connections.
    /// Fire-and-forget: callbacks may arrive after this method returns.
    /// Use `snapshotICE()` when you need to await completion.
    func dumpICESnapshot() {
        Task { await snapshotICE() }
    }

    /// Async version of `dumpICESnapshot` — awaits each peer's stats before returning.
    func snapshotICE() async {
        let peers: [(Int, LKRTCPeerConnection)] = withState {
            peerPool.map { ($0.key, $0.value) }
        }
        guard !peers.isEmpty else {
            debug("ice snapshot: no peers")
            return
        }
        for (tgt, pc) in peers.sorted(by: { $0.0 < $1.0 }) {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                pc.statistics { [weak self] (report: LKRTCStatisticsReport) in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    var locals: [String] = []
                    var remotes: [String] = []
                    var pairs: [String] = []

                    for stat in report.statistics.values {
                        let v = stat.values
                        switch stat.type {
                            case "local-candidate":
                                let ctype = v["candidateType"] as? String ?? "?"
                                let proto = v["protocol"] as? String ?? "?"
                                let addr = v["address"] as? String ?? (v["ip"] as? String ?? "?")
                                let port = v["port"] as? NSNumber ?? 0
                                let relay = v["relayProtocol"] as? String
                                let url = v["url"] as? String
                                var line = "local id=\(stat.id) typ=\(ctype) proto=\(proto) \(addr):\(port)"
                                if let r = relay { line += " relayProto=\(r)" }
                                if let u = url { line += " url=\(u)" }
                                locals.append(line)
                            case "remote-candidate":
                                let ctype = v["candidateType"] as? String ?? "?"
                                let proto = v["protocol"] as? String ?? "?"
                                let addr = v["address"] as? String ?? (v["ip"] as? String ?? "?")
                                let port = v["port"] as? NSNumber ?? 0
                                remotes.append(
                                    "remote id=\(stat.id) typ=\(ctype) proto=\(proto) \(addr):\(port)"
                                )
                            case "candidate-pair":
                                let state = v["state"] as? String ?? "?"
                                let nominated = (v["nominated"] as? NSNumber)?.boolValue ?? false
                                let selected = (v["selected"] as? NSNumber)?.boolValue ?? false
                                let localID = v["localCandidateId"] as? String ?? "?"
                                let remoteID = v["remoteCandidateId"] as? String ?? "?"
                                if nominated || selected || state == "succeeded" {
                                    pairs.append(
                                        "pair state=\(state) nominated=\(nominated) selected=\(selected) local=\(localID) remote=\(remoteID)"
                                    )
                                }
                            default:
                                break
                        }
                    }

                    let iceStr = self.iceStateName(pc.iceConnectionState)
                    self.debug("ICE snapshot target=\(tgt) ice=\(iceStr)")
                    for line in locals.sorted() { self.debug("  \(line)") }
                    for line in remotes.sorted() { self.debug("  \(line)") }
                    for line in pairs { self.debug("  \(line)") }
                    if pairs.isEmpty { self.debug("  (no nominated/selected pairs)") }
                    continuation.resume()
                }
            }
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
        if target >= 0 {
            withState { cachedIceConnectionStates[target] = newState }
        }
        debug(
            "ice connection state target=\(target) state=\(newState.rawValue)"
        )
        switch newState {
            case .connected, .completed:
                debug("ice connection established target=\(target)")
            case .failed:
                debug("ice connection failed target=\(target) - check TURN reachability")
                reportTransportDegraded("ice failed target=\(target)")
            case .closed:
                debug("ice connection closed target=\(target)")
                reportTransportDegraded("ice closed target=\(target)")
            case .disconnected:
                debug("ice connection disconnected target=\(target) - may reconnect")
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
        // Extract typ and protocol from SDP for diagnostics (e.g. "typ relay" or "typ host")
        let candidateInfo = Self.parseCandidateType(from: candidate.sdp)
        debug(
            "local candidate target=\(target) \(candidateInfo) mid=\(candidate.sdpMid ?? "nil")"
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
        } else if dataChannel.label == "ion-sfu" {
            ionSFUAPIChannel = dataChannel
            debug("recognized inbound ion-sfu api channel")
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
