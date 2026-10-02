#if canImport(IrohLib)
import Foundation
import IrohLib

/// The SFU session: one connection to `kt-sfu` (`keeptalking/sfu/2`), kept
/// up best effort. Room management rides the session stream; publishes ride
/// a stream per lane — control and interactive long-lived, a stream per bulk
/// frame — each drained from its own byte-bounded queue, so no lane waits
/// behind another. On (re)connect every attached topic is re-subscribed, and
/// the lanes hold their frames until those subscriptions are in.
extension KeepTalkingIrohTransportHost {
    /// Lanes open this long after connecting even if a snapshot is missing.
    static let sfuLaneGate: Duration = .seconds(3)

    func sfuLoop(_ endpoint: Endpoint) async {
        var attempt = 0
        while !Task.isCancelled, !state.withLockedValue({ $0.isShutDown }) {
            if state.withLockedValue({ $0.sfu.suspended }) {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            setSFUStatus(.connecting(attempt: attempt))
            let started = clock.now
            var session: Connection?
            var tasks: [Task<Void, Never>] = []
            do {
                let sfuID = try await resolveSFU(endpoint)
                let connection = try await endpoint.connect(
                    addr: EndpointAddr(
                        id: try EndpointId.fromString(s: sfuID),
                        relayUrl: configuration.relayURL,
                        addresses: []
                    ),
                    alpn: KeepTalkingIrohSFUFrame.alpn
                )
                session = connection
                let stream = try await connection.openBi()
                var streams: [Data: AsyncStream<Void>] = [:]
                var bells: [Data: AsyncStream<Void>.Continuation] = [:]
                for key in [Self.sfuSessionQueue] + Lane.allCases.map(Self.sfuQueue) {
                    let (doorbell, bell) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                    streams[key] = doorbell
                    bells[key] = bell
                }
                let latency = clock.now - started
                let ready = state.withLockedValue { state -> Bool in
                    guard !state.isShutDown, !state.sfu.suspended else { return false }
                    state.sfu.connection = connection
                    state.sfu.doorbells = bells
                    state.sfu.connectLatency = latency
                    state.sfu.connectedSince = Date()
                    state.sfu.status = .ready
                    var frames: [Data] = []
                    for (topic, attachment) in state.attachments {
                        frames.append(KeepTalkingIrohSFUFrame.encode(.subscribe(topic: topic)))
                        frames.append(KeepTalkingIrohSFUFrame.encode(.announce(topic: topic, blob: attachment.blob)))
                    }
                    state.outbound.prepend(frames, for: Self.sfuSessionQueue)
                    state.sfu.lanesOpen = state.attachments.isEmpty
                    return true
                }
                guard ready else {
                    bells.values.forEach { $0.finish() }
                    try? connection.close(errorCode: 0, reason: Data("stopped".utf8))
                    continue
                }
                let sessionSend = stream.send()
                let sessionDoorbell = streams[Self.sfuSessionQueue]!
                tasks.append(
                    Task {
                        await self.sfuSessionPump(connection, send: sessionSend, doorbell: sessionDoorbell)
                    })
                for lane in Lane.allCases {
                    let doorbell = streams[Self.sfuQueue(lane)]!
                    tasks.append(Task { await self.sfuLanePump(connection, lane: lane, doorbell: doorbell) })
                }
                tasks.append(Task { await self.sfuAcceptLanes(connection) })
                tasks.append(Task { await self.sfuDatagramLoop(connection) })
                tasks.append(
                    Task {
                        try? await Task.sleep(for: Self.sfuLaneGate, clock: self.clock)
                        self.openSFULanes(connection: connection)
                    })
                bells.values.forEach { $0.yield() }
                attempt = 0
                log("SFU connected in \(Self.ms(latency))")
                notifyAllContexts { $0.sfuStateChanged() }

                let recv = stream.recv()
                while !Task.isCancelled {
                    let prefix = try await recv.readExact(size: 4)
                    let length = try KeepTalkingIrohSFUFrame.frameLength(fromPrefix: prefix)
                    let body = try await recv.readExact(size: UInt32(length))
                    if let frame = try? KeepTalkingIrohSFUFrame.decodeServer(body) {
                        handleSFUFrame(frame, connection: connection)
                    } else {
                        state.withLockedValue { $0.sfu.skippedFrames += 1 }
                    }
                }
            } catch {
                if !state.withLockedValue({ $0.sfu.suspended }) {
                    log("SFU: \(error.localizedDescription)")
                }
            }
            tasks.forEach { $0.cancel() }
            let connection = state.withLockedValue { state -> Connection? in
                let connection = state.sfu.connection
                state.sfu.doorbells.values.forEach { $0.finish() }
                state.sfu.doorbells = [:]
                state.sfu.lanesOpen = false
                state.sfu.connection = nil
                state.sfu.connectedSince = nil
                state.sfu.writingSince = [:]
                state.sfu.pendingSnapshots = [:]
                state.sfu.status = .connecting(attempt: attempt + 1)
                state.membership.markAllUnjoined()
                return connection
            }
            try? (connection ?? session)?.close(errorCode: 0, reason: Data("reconnect".utf8))
            attempt += 1
            notifyAllContexts { $0.sfuStateChanged() }
            if !state.withLockedValue({ $0.sfu.suspended }) {
                try? await Task.sleep(for: .seconds(min(1 << min(attempt - 1, 3), 8)))
            }
        }
    }

    /// Opens the lanes of `connection`'s session (once its subscriptions are
    /// in, or the gate timed out) and lets queued publishes go.
    private func openSFULanes(connection: Connection) {
        let opened = state.withLockedValue { state -> (Bool, [AsyncStream<Void>.Continuation]) in
            guard state.sfu.connection?.stableId() == connection.stableId(), !state.sfu.lanesOpen else {
                return (false, [])
            }
            state.sfu.lanesOpen = true
            return (true, Lane.allCases.compactMap { state.sfu.doorbells[Self.sfuQueue($0)] })
        }
        guard opened.0 else { return }
        opened.1.forEach { $0.yield() }
        notifyAllContexts { $0.sfuStateChanged() }
    }

    /// Writes room management on the session stream.
    private func sfuSessionPump(_ connection: Connection, send: SendStream, doorbell: AsyncStream<Void>) async {
        await drainSFU(connection, queue: Self.sfuSessionQueue, doorbell: doorbell, paced: false) { batch in
            for frame in batch { try await send.writeAll(buf: frame) }
        }
    }

    /// Writes one lane: control and interactive on one long-lived stream
    /// each, bulk on a stream per frame.
    private func sfuLanePump(_ connection: Connection, lane: Lane, doorbell: AsyncStream<Void>) async {
        let streamType = KeepTalkingIrohPeerFrame.StreamType.lane(lane)
        var stream: SendStream?
        await drainSFU(
            connection, queue: Self.sfuQueue(lane), doorbell: doorbell, paced: true, oneAtATime: lane == .bulk
        ) {
            batch in
            for frame in batch {
                if lane == .bulk {
                    let bulk = try await connection.openUni()
                    try await bulk.setPriority(p: KeepTalkingIrohPeerFrame.priority(streamType))
                    var bytes = Data([streamType.preamble])
                    bytes.append(frame)
                    try await bulk.writeAll(buf: bytes)
                    try await bulk.finish()
                } else {
                    if stream == nil {
                        let opened = try await connection.openUni()
                        try await opened.setPriority(p: KeepTalkingIrohPeerFrame.priority(streamType))
                        try await opened.writeAll(buf: Data([streamType.preamble]))
                        stream = opened
                    }
                    try await stream?.writeAll(buf: frame)
                }
            }
        }
    }

    /// Drains one SFU queue whenever its doorbell rings, pacing publishes
    /// below the SFU's limits and recording when a write is in flight (for
    /// stall detection). A write failure ends the session.
    private func drainSFU(
        _ connection: Connection,
        queue: Data,
        doorbell: AsyncStream<Void>,
        paced: Bool,
        oneAtATime: Bool = false,
        write: ([Data]) async throws -> Void
    ) async {
        let stableID = connection.stableId()
        do {
            for await _ in doorbell {
                while true {
                    let now = clock.now
                    let next = state.withLockedValue { state -> (batch: [Data], wait: Duration)? in
                        guard state.sfu.connection?.stableId() == stableID else { return nil }
                        guard queue == Self.sfuSessionQueue || state.sfu.lanesOpen else { return ([], .zero) }
                        let batch = state.outbound.drain(queue, upTo: oneAtATime ? 1 : 512 * 1024)
                        state.sfu.writingSince[queue] = batch.isEmpty ? nil : now
                        guard paced, !batch.isEmpty else { return (batch, .zero) }
                        let bytes = batch.reduce(0) { $0 + $1.count }
                        return (batch, state.sfu.pace(frames: batch.count, bytes: bytes, now: now))
                    }
                    guard let next else { return }
                    if next.batch.isEmpty { break }
                    if next.wait > .zero { try await Task.sleep(for: next.wait, clock: clock) }
                    try await write(next.batch)
                }
                state.withLockedValue { $0.sfu.writingSince[queue] = nil }
            }
        } catch {
            try? connection.close(errorCode: 1, reason: Data("write failed".utf8))
        }
    }

    /// Reads the lane streams the SFU opens to us: DELIVER frames until the
    /// stream ends (a bulk stream carries one).
    private func sfuAcceptLanes(_ connection: Connection) async {
        while !Task.isCancelled {
            guard let recv = try? await connection.acceptUni() else { return }
            Task {
                guard let preamble = try? await recv.readExact(size: 1).first,
                    case .lane(let lane)? = KeepTalkingIrohPeerFrame.StreamType(preamble: preamble)
                else {
                    try? await recv.stop(errorCode: 1)
                    return
                }
                do {
                    while let prefix = try await Self.readPrefixOrEnd(recv) {
                        let length = try KeepTalkingIrohSFUFrame.frameLength(fromPrefix: prefix)
                        let body = try await recv.readExact(size: UInt32(length))
                        if let frame = try? KeepTalkingIrohSFUFrame.decodeServer(body) {
                            handleSFUFrame(frame, connection: connection)
                        } else {
                            state.withLockedValue { $0.sfu.skippedFrames += 1 }
                        }
                        if lane == .bulk { break }
                    }
                } catch {
                    try? await recv.stop(errorCode: 1)
                }
            }
        }
    }

    private func sfuDatagramLoop(_ connection: Connection) async {
        while !Task.isCancelled {
            guard let datagram = try? await connection.readDatagram() else { return }
            guard let split = KeepTalkingIrohSFUFrame.splitDatagram(datagram) else { continue }
            let sink = state.withLockedValue { state -> KeepTalkingIrohAttachment? in
                state.attachments[split.topic]?.sfuDatagramsReceived += 1
                return state.attachments[split.topic]?.sink
            }
            sink?.deliverRealtime(split.payload, from: nil)
        }
    }

    /// An SFU write has made no progress for `sfuStallTimeout`; returns the
    /// connection to close.
    func stalledSFU(now: Instant) -> Connection? {
        state.withLockedValue { state in
            guard state.sfu.writingSince.values.contains(where: { now - $0 >= Self.sfuStallTimeout }) else {
                return nil
            }
            return state.sfu.connection
        }
    }

    private func setSFUStatus(_ status: SFUStatus) {
        state.withLockedValue { state in
            state.sfu.status = status
            if case .connecting = status { state.sfu.attempts += 1 }
        }
    }

    /// The SFU id from configuration or `<relay>/kt/sfu`, cached. A looked-up
    /// QAD port is applied to the relay the first time.
    private func resolveSFU(_ endpoint: Endpoint) async throws -> String {
        if let configured = configuration.sfuEndpointID, !configured.isEmpty { return configured }
        if let cached = state.withLockedValue({ $0.sfu.resolvedID }) { return cached }
        guard let base = URL(string: configuration.relayURL) else {
            throw HostError.sfuInfo("bad relay URL \(configuration.relayURL)")
        }
        let url = base.appendingPathComponent("kt").appendingPathComponent("sfu")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HostError.sfuInfo("\(url) answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let info = try JSONDecoder().decode(SFUInfo.self, from: data)
        guard info.alpn == nil || info.alpn.map({ Data($0.utf8) }) == KeepTalkingIrohSFUFrame.alpn else {
            throw HostError.sfuInfo("SFU speaks \(info.alpn ?? "?")")
        }
        if configuration.relayQUICPort == nil, let port = info.qadPort {
            try? await endpoint.insertRelay(
                config: RelayConfig(url: configuration.relayURL, quicPort: port, authToken: nil)
            )
        }
        state.withLockedValue { $0.sfu.resolvedID = info.sfu }
        log("SFU id \(info.sfu.prefix(10)) from \(url.host() ?? "relay")")
        return info.sfu
    }

    private struct SFUInfo: Decodable {
        let sfu: String
        let alpn: String?
        let qadPort: UInt16?

        enum CodingKeys: String, CodingKey {
            case sfu, alpn
            case qadPort = "qad_port"
        }
    }

    // MARK: - Frames

    private func handleSFUFrame(_ frame: KeepTalkingIrohSFUFrame.Server, connection: Connection) {
        switch frame {
            case .snapshot(let topic, let chunk, let more):
                let members = state.withLockedValue { state -> [KeepTalkingIrohSFUFrame.Member]? in
                    state.sfu.pendingSnapshots[topic, default: []].append(contentsOf: chunk)
                    guard !more else { return nil }
                    return state.sfu.pendingSnapshots.removeValue(forKey: topic)
                }
                if let members {
                    applySnapshot(topic: topic, members: members)
                    // Every subscription in: no need to wait out the gate.
                    let allJoined = state.withLockedValue { state in
                        state.attachments.keys.allSatisfy { state.membership.contexts[$0]?.joined == true }
                    }
                    if allJoined { openSFULanes(connection: connection) }
                }
            case .joined(let topic, let endpointID):
                log("topic \(Self.hex(topic).prefix(10)) joined by \(Self.hex(endpointID).prefix(10))")
            case .presence(let topic, let endpointID, let blob):
                learnFromSFU(topic: topic, reportedID: endpointID, blob: blob)
            case .left(let topic, let endpointID):
                sfuDropped(topic: topic, members: [endpointID])
            case .deliver(let topic, let body):
                guard let first = body.first, let kind = FrameKind(rawValue: first), kind != .hello else { return }
                let sink = state.withLockedValue { state -> KeepTalkingIrohAttachment? in
                    state.attachments[topic]?.sfuReceived += 1
                    return state.attachments[topic]?.sink
                }
                sink?.deliver(kind, payload: Data(body.dropFirst()), from: nil, route: .sfu)
            case .error(let topic, let reason):
                let scope = topic == KeepTalkingIrohSFUFrame.noTopic ? "" : " (topic \(Self.hex(topic).prefix(10)))"
                log("SFU error\(scope): \(reason)")
        }
    }

    /// A snapshot is the whole room: members it lacks left the SFU while
    /// our session was down (`sfuDropped` decides whether they leave us
    /// too); then learn the current ones.
    private func applySnapshot(topic: Data, members: [KeepTalkingIrohSFUFrame.Member]) {
        let present = Set(members.map(\.endpointID))
        let (sink, absent) = state.withLockedValue { state -> (KeepTalkingIrohAttachment?, [Data]) in
            state.membership.markJoined(topic)
            let absent = state.membership.members(of: topic).map(\.main).filter { !present.contains($0) }
            return (state.attachments[topic]?.sink, absent)
        }
        sfuDropped(topic: topic, members: absent)
        log("topic \(Self.hex(topic).prefix(10)) snapshot: \(members.count) other member(s)")
        for member in members where !member.blob.isEmpty {
            learnFromSFU(topic: topic, reportedID: member.endpointID, blob: member.blob)
        }
        sink?.sfuJoined()
    }

    /// The SFU no longer lists `members` in `topic`. Its roster is only
    /// discovery: whoever a link still reaches, or Bluetooth may, stays.
    private func sfuDropped(topic: Data, members: [Data]) {
        guard !members.isEmpty else { return }
        let now = clock.now
        let (departures, orphans, kept) = mutateLinks(touching: Set(members)) {
            state -> ([(KeepTalkingIrohMembership.Departure, KeepTalkingIrohAttachment?)], [LinkIO], [Data]) in
            var departures: [(KeepTalkingIrohMembership.Departure, KeepTalkingIrohAttachment?)] = []
            var kept: [Data] = []
            let bluetoothUsable = state.bluetooth.myID != nil
            for main in members {
                let table = state.table
                if let departure = state.membership.sfuDropped(
                    main,
                    in: topic,
                    now: now,
                    bluetoothUsable: bluetoothUsable,
                    reachable: table.isCarrying
                ) {
                    departures.append((departure, state.attachments[topic]?.sink))
                } else if state.membership.contexts[topic]?.members[main] != nil {
                    kept.append(main)
                }
            }
            let orphans = state.dropUnneededLinks(among: departures.flatMap(\.0.unlink))
            return (departures, orphans, kept)
        }
        orphans.forEach { Self.tearDown($0, reason: "left") }
        for (departure, sink) in departures {
            log("topic \(Self.hex(topic).prefix(10)) left by \(departure.nodeID.uuidString.prefix(8))")
            sink?.memberLeft(departure.nodeID)
        }
        for main in kept {
            log(
                "topic \(Self.hex(topic).prefix(10)): \(Self.hex(main).prefix(10)) left the SFU; kept (reachable or Bluetooth)"
            )
        }
    }

    /// Opens a member's sealed presence. Only a blob this context's secret
    /// opens, carrying the very id the SFU reported, makes a member.
    private func learnFromSFU(topic: Data, reportedID: Data, blob: Data) {
        guard let key = state.withLockedValue({ $0.membership.contexts[topic]?.key }) else { return }
        guard let presence = KeepTalkingIrohPresenceSeal.open(blob, key: key) else {
            log("presence from \(Self.hex(reportedID).prefix(10)) does not open")
            return
        }
        let now = clock.now
        let learned = mutateLinks(touching: [reportedID]) { state in
            let myID = state.myEndpointID
            return state.membership.learn(presence, in: topic, from: .sfu(reportedID: reportedID), myID: myID, now: now)
        }
        switch learned {
            case .member(let nodeID, let main, let isNew):
                if isNew { log("member \(nodeID.uuidString.prefix(8)) @ \(Self.hex(main).prefix(10))") }
                ensureLink(to: main, kind: .network)
                if let bluetooth = presence.bluetoothEndpointID { ensureLink(to: bluetooth, kind: .bluetooth) }
            case .ourselves:
                return
            case .rejected(let reason):
                log("presence from \(Self.hex(reportedID).prefix(10)) rejected: \(reason)")
        }
    }
}
#endif
