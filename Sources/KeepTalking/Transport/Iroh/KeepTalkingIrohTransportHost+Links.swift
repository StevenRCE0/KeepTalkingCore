#if canImport(IrohLib)
import Foundation
import IrohLib

/// Peer links (`keeptalking/peer/2`): dialling, accepting, a pump per lane
/// that drains member queues, reading lane and blob streams, hellos, blob
/// transfers, and what happens when a link closes or loses its paths.
extension KeepTalkingIrohTransportHost {
    typealias LinkKind = KeepTalkingIrohLinkTable.Kind

    // MARK: - Dialling

    /// Dials `endpointID` when a link is wanted (its room is on the mesh, or
    /// something demands one), it's our turn and backoff allows; the other
    /// side waits for us.
    func ensureLink(to endpointID: Data, kind: LinkKind) {
        let now = clock.now
        let token = state.withLockedValue { state -> UInt64? in
            let myID = kind == .network ? state.myEndpointID : state.bluetooth.myID
            let endpoint = kind == .network ? state.endpoint : state.bluetooth.endpoint
            guard !state.isShutDown, endpoint != nil, let myID, state.wantsDial(endpointID, now: now) else {
                return nil
            }
            return state.table.beginDial(to: endpointID, kind: kind, myID: myID, now: now)
        }
        guard let token else { return }
        let task = Task { await self.dialLoop(endpointID, kind: kind, token: token) }
        state.withLockedValue { state in
            guard state.table.ownsDial(endpointID, token: token) else { return }
            state.io[endpointID, default: LinkIO()].tasks.append(task)
        }
    }

    private func dialLoop(_ endpointID: Data, kind: LinkKind, token: UInt64) async {
        var attempt = 0
        while !Task.isCancelled {
            let now = clock.now
            let endpoint = state.withLockedValue { state -> Endpoint? in
                guard state.table.ownsDial(endpointID, token: token), state.wantsDial(endpointID, now: now) else {
                    return nil
                }
                state.table.noteDialAttempt(endpointID, token: token)
                return kind == .network ? state.endpoint : state.bluetooth.endpoint
            }
            guard let endpoint else { break }
            let started = clock.now
            do {
                let connection = try await endpoint.connect(
                    addr: EndpointAddr(
                        id: try EndpointId.fromBytes(bytes: endpointID),
                        relayUrl: kind == .network ? configuration.relayURL : nil,
                        addresses: []
                    ),
                    alpn: Self.peerALPN
                )
                install(connection, endpointID: endpointID, side: .dialed, kind: kind, token: token, started: started)
                return
            } catch {
                attempt += 1
                log(
                    "dial \(kind.rawValue) \(Self.hex(endpointID).prefix(10)) failed (#\(attempt)): \(error.localizedDescription)"
                )
                // A Bluetooth dial fails at once while the other side's radio
                // is paused, and that side may claim it any second.
                try? await Task.sleep(for: kind == .bluetooth ? .seconds(3) : .seconds(min(1 << min(attempt, 4), 16)))
            }
        }
        state.withLockedValue { state in
            guard state.table.ownsDial(endpointID, token: token) else { return }
            state.table.endDial(endpointID, token: token)
            if state.io[endpointID]?.connection == nil { state.io[endpointID] = nil }
        }
    }

    // MARK: - Accepting

    func acceptLoop(_ endpoint: Endpoint, kind: LinkKind) async {
        while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
            handleIncoming(incoming, kind: kind)
        }
    }

    /// An incoming connection on the process-wide Bluetooth endpoint while
    /// this host holds it.
    func acceptBluetooth(_ incoming: Incoming) {
        handleIncoming(incoming, kind: .bluetooth)
    }

    private func handleIncoming(_ incoming: Incoming, kind: LinkKind) {
        Task {
            let started = clock.now
            do {
                let accepting = try await incoming.accept()
                guard try await accepting.alpn() == Self.peerALPN else {
                    log("refused connection with unknown ALPN")
                    return
                }
                let connection = try await accepting.connect()
                install(
                    connection,
                    endpointID: connection.remoteId().toBytes(),
                    side: .accepted,
                    kind: kind,
                    token: nil,
                    started: started
                )
            } catch {
                log("accept \(kind.rawValue) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Installing

    /// Takes in a connection. Refused — and closed — when the host stopped,
    /// a Bluetooth link arrives after we let the radio go, or the dial that
    /// made it no longer owns its slot.
    private func install(
        _ connection: Connection,
        endpointID: Data,
        side: KeepTalkingIrohLinkTable.Side,
        kind: LinkKind,
        token: UInt64?,
        started: Instant
    ) {
        let stableID = connection.stableId()
        let now = clock.now
        var doorbells: [Lane: AsyncStream<Void>] = [:]
        var bells: [Lane: AsyncStream<Void>.Continuation] = [:]
        for lane in Lane.allCases {
            let (doorbell, bell) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            doorbells[lane] = doorbell
            bells[lane] = bell
        }
        let outcome = mutateLinks(touching: [endpointID]) { state -> (installed: Bool, replaced: LinkIO?) in
            guard !state.isShutDown, kind == .network || state.bluetooth.endpoint != nil else {
                return (false, nil)
            }
            let result = state.table.install(
                endpointID,
                kind: kind,
                side: side,
                stableID: stableID,
                token: token,
                now: now,
                latency: now - started
            )
            guard case .installed(let replacedID) = result else { return (false, nil) }
            let previous = state.io[endpointID]
            // A dial slot's io holds only the dial task, which is finishing.
            let replaced = replacedID == nil ? nil : previous
            state.io[endpointID] = LinkIO(connection: connection, doorbells: bells)
            return (true, replaced)
        }
        guard outcome.installed else {
            bells.values.forEach { $0.finish() }
            try? connection.close(errorCode: 0, reason: Data("unwanted".utf8))
            return
        }
        if let replaced = outcome.replaced { Self.tearDown(replaced, reason: "superseded") }

        // Two long-lived lanes plus bulk and blob streams in flight.
        try? connection.setMaxConcurrentUniStreams(count: 64)
        let watcher = LinkPathWatcher(host: self, endpointID: endpointID, stableID: stableID)
        let watch = connection.watchPathEvents(callback: watcher)
        let laneDoorbells = doorbells
        var tasks = Lane.allCases.map { lane in
            let doorbell = laneDoorbells[lane]!
            return Task {
                await self.lanePump(
                    endpointID,
                    stableID: stableID,
                    connection: connection,
                    lane: lane,
                    doorbell: doorbell
                )
            }
        }
        tasks += [
            Task { await self.acceptStreams(endpointID, connection: connection) },
            Task { await self.datagramLoop(endpointID, connection: connection) },
            Task { await self.watchClosed(endpointID, connection: connection) },
        ]
        let current = state.withLockedValue { state -> Bool in
            guard state.table.isCurrent(endpointID, stableID: stableID) else { return false }
            state.io[endpointID]?.tasks = tasks
            state.io[endpointID]?.watch = watch
            return true
        }
        guard current else {
            tasks.forEach { $0.cancel() }
            return
        }
        log(
            "\(kind.rawValue) peer \(Self.hex(endpointID).prefix(10)) \(side.rawValue) in \(Self.ms(now - started)) via \(Self.selectedPath(connection))"
        )
        bells.values.forEach { $0.yield() }
        sendHello(to: [endpointID])
    }

    // MARK: - Pumps, streams, datagrams

    /// Writes one lane of this link: control carries the link's own frames
    /// (hellos) first, then each lane carries the queues of the members this
    /// link carries. Control and interactive ride one long-lived stream each;
    /// every bulk frame gets a stream of its own.
    private func lanePump(
        _ endpointID: Data,
        stableID: UInt64,
        connection: Connection,
        lane: Lane,
        doorbell: AsyncStream<Void>
    ) async {
        let streamType = KeepTalkingIrohPeerFrame.StreamType.lane(lane)
        var stream: SendStream?
        do {
            for await _ in doorbell {
                while true {
                    let batch = state.withLockedValue { state -> [Data]? in
                        guard state.table.isCurrent(endpointID, stableID: stableID) else { return nil }
                        let limit = lane == .bulk ? 1 : 512 * 1024
                        if lane == .control {
                            let own = state.outbound.drain(Self.linkQueue(endpointID), upTo: limit)
                            if !own.isEmpty { return own }
                        }
                        for main in state.carried(by: endpointID) {
                            let batch = state.outbound.drain(Self.memberQueue(main, lane), upTo: limit)
                            if !batch.isEmpty { return batch }
                        }
                        return []
                    }
                    guard let batch else { return }
                    if batch.isEmpty { break }
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
                    let bytes = batch.reduce(0) { $0 + $1.count }
                    state.withLockedValue { state in
                        state.table.update(endpointID) {
                            $0.framesSent += batch.count
                            $0.bytesSent += bytes
                        }
                    }
                }
            }
            try? await stream?.finish()
        } catch {
            if connection.closeReason() == nil {
                log("peer \(Self.hex(endpointID).prefix(10)) write: \(error.localizedDescription)")
                try? connection.close(errorCode: 1, reason: Data("write failed".utf8))
            }
        }
    }

    /// Takes the peer's streams as they open and reads each by its preamble.
    private func acceptStreams(_ endpointID: Data, connection: Connection) async {
        while !Task.isCancelled {
            guard let recv = try? await connection.acceptUni() else { return }
            Task { await self.readStream(recv, from: endpointID, connection: connection) }
        }
    }

    private func readStream(_ recv: RecvStream, from endpointID: Data, connection: Connection) async {
        do {
            guard let preamble = try await recv.readExact(size: 1).first,
                let type = KeepTalkingIrohPeerFrame.StreamType(preamble: preamble)
            else { throw HostError.malformedFrame }
            switch type {
                case .lane(let lane):
                    while let prefix = try await Self.readPrefixOrEnd(recv) {
                        // Until a link shows it shares a context, its frames
                        // stay small.
                        let proven = state.withLockedValue { $0.membership.isMember(endpointID) }
                        guard
                            let length = KeepTalkingIrohPeerFrame.bodyLength(fromPrefix: prefix, proven: proven)
                        else { throw HostError.malformedFrame }
                        let body = try await recv.readExact(size: UInt32(length))
                        handlePeerFrame(body, from: endpointID)
                        if lane == .bulk { return }
                    }
                case .blob:
                    let topic = try await recv.readExact(size: UInt32(KeepTalkingIrohSFUFrame.topicLength))
                    let route = state.withLockedValue { state -> (KeepTalkingIrohAttachment, UUID)? in
                        guard let sink = state.attachments[topic]?.sink,
                            let nodeID = state.membership.nodeID(for: endpointID, in: topic)
                        else { return nil }
                        return (sink, nodeID)
                    }
                    // Only members of the topic may hand us blob bytes.
                    guard let route else {
                        try? await recv.stop(errorCode: 1)
                        return
                    }
                    route.0.deliverBlobStream(KeepTalkingIrohBlobStream.Reader(recv), from: route.1)
            }
        } catch {
            // A broken long-lived lane leaves the peer's writes going nowhere:
            // end the connection so the link falls back and redials.
            try? await recv.stop(errorCode: 1)
            if connection.closeReason() == nil {
                log("peer \(Self.hex(endpointID).prefix(10)) read: \(error.localizedDescription)")
                try? connection.close(errorCode: 1, reason: Data("read failed".utf8))
            }
        }
    }

    /// The next 4-byte length prefix, or nil when the stream ended cleanly
    /// between frames.
    static func readPrefixOrEnd(_ recv: RecvStream) async throws -> Data? {
        let first = try await recv.read(sizeLimit: 4)
        if first.isEmpty { return nil }
        if first.count == 4 { return first }
        return first + (try await recv.readExact(size: UInt32(4 - first.count)))
    }

    private func datagramLoop(_ endpointID: Data, connection: Connection) async {
        while !Task.isCancelled {
            guard let datagram = try? await connection.readDatagram() else { return }
            noteHeard(endpointID)
            guard let split = KeepTalkingIrohSFUFrame.splitDatagram(datagram) else { continue }
            let (topic, payload) = split
            let route = state.withLockedValue { state -> (KeepTalkingIrohAttachment, UUID?)? in
                state.table.update(endpointID) { $0.datagramsReceived += 1 }
                guard let sink = state.attachments[topic]?.sink else { return nil }
                return (sink, state.membership.nodeID(for: endpointID, in: topic))
            }
            if let route {
                route.0.deliverRealtime(payload, from: route.1)
            }
        }
    }

    // MARK: - Closing and paths

    private func watchClosed(_ endpointID: Data, connection: Connection) async {
        let reason = await connection.closed()
        let stableID = connection.stableId()
        let now = clock.now
        let closed = mutateLinks(touching: [endpointID]) { state -> (LinkIO?, LinkKind?)? in
            guard state.table.isCurrent(endpointID, stableID: stableID) else { return nil }
            let io = state.io.removeValue(forKey: endpointID)
            state.outbound.remove(Self.linkQueue(endpointID))
            let result = state.table.closed(
                endpointID, stableID: stableID, now: now, wanted: state.isWanted(endpointID))
            return (io, result?.redial)
        }
        guard let closed else { return }
        let (io, redial) = closed
        io?.doorbells.values.forEach { $0.finish() }
        io?.tasks.forEach { $0.cancel() }
        log("peer \(Self.hex(endpointID).prefix(10)) closed: \(reason)")
        if let redial { ensureLink(to: endpointID, kind: redial) }
    }

    func pathEvent(_ event: PathEvent, endpointID: Data, stableID: UInt64) {
        let connection = state.withLockedValue { state -> Connection? in
            guard state.table.isCurrent(endpointID, stableID: stableID) else { return nil }
            return state.io[endpointID]?.connection
        }
        guard let connection else { return }
        // A connection whose every path closed lingers until QUIC times it
        // out while swallowing what we write: stop routing through it now.
        let pathless = connection.paths().isEmpty
        let changed = mutateLinks(touching: [endpointID]) { state in
            state.table.setPathless(endpointID, stableID: stableID, pathless)
        }
        if changed {
            log("peer \(Self.hex(endpointID).prefix(10)) \(pathless ? "lost every path" : "has a path again")")
        }
        guard case .selected = event else { return }
        let isDirect = connection.paths().contains { $0.isSelected && !$0.isRelay }
        let now = clock.now
        let firstDirect = state.withLockedValue { state -> Duration? in
            guard isDirect, let link = state.table.links[endpointID], link.stableID == stableID,
                link.timeToDirect == nil, let connectedAt = link.connectedAt
            else { return nil }
            let elapsed = now - connectedAt
            state.table.update(endpointID) { $0.timeToDirect = elapsed }
            return elapsed
        }
        if let firstDirect {
            log(
                "peer \(Self.hex(endpointID).prefix(10)) direct after \(Self.ms(firstDirect)) via \(Self.selectedPath(connection))"
            )
        } else {
            log("peer \(Self.hex(endpointID).prefix(10)) path → \(Self.selectedPath(connection))")
        }
        let sinks = state.withLockedValue { state in
            state.membership.contexts.compactMap { topic, context in
                context.mains(for: endpointID).isEmpty ? nil : state.attachments[topic]?.sink
            }
        }
        sinks.forEach { $0.routeMayHaveChanged() }
    }

    // MARK: - Frames

    /// Something arrived from `endpointID`: a silent link carries again.
    private func noteHeard(_ endpointID: Data) {
        let now = clock.now
        guard state.withLockedValue({ $0.table.heard(endpointID, now: now) }) else { return }
        let changed = mutateLinks(touching: [endpointID]) { $0.table.setSilent(endpointID, false) }
        if changed { log("peer \(Self.hex(endpointID).prefix(10)) heard again") }
    }

    /// Delivered for any attached topic: the payload only opens for holders
    /// of the topic's key.
    private func handlePeerFrame(_ body: Data, from endpointID: Data) {
        guard let frame = KeepTalkingIrohPeerFrame.decode(body) else { return }
        noteHeard(endpointID)
        if frame.kind == .ping { return }
        if frame.kind == .hello {
            handleHello(frame.payload, from: endpointID)
            return
        }
        let route = state.withLockedValue { state -> (KeepTalkingIrohAttachment, UUID?)? in
            state.table.update(endpointID) {
                $0.framesReceived += 1
                $0.bytesReceived += body.count + 4
            }
            guard let sink = state.attachments[frame.topic]?.sink else {
                state.droppedFrames += 1
                return nil
            }
            state.attachments[frame.topic]?.meshReceived += 1
            return (sink, state.membership.nodeID(for: endpointID, in: frame.topic))
        }
        guard let route else { return }
        route.0.deliver(frame.kind, payload: frame.payload, from: route.1, route: .mesh)
    }

    // MARK: - Hello

    /// Says hello on the given links: freshly sealed presence for every
    /// attached context, so it can't be tied to what the SFU stored.
    func sendHello(to endpointIDs: [Data]) {
        guard !endpointIDs.isEmpty else { return }
        let snapshot = state.withLockedValue {
            state -> (Data, Data?, [(UUID, KeepTalkingIrohPresenceSeal.Key)])? in
            guard let myID = state.myEndpointID else { return nil }
            return (myID, state.bluetooth.myID, state.membership.contexts.values.map { ($0.nodeID, $0.key) })
        }
        guard let snapshot else { return }
        let (myID, bluetoothID, contexts) = snapshot
        let blobs = contexts.compactMap { nodeID, key in
            try? KeepTalkingIrohPresenceSeal.seal(
                nodeID: nodeID,
                endpointID: myID,
                bluetoothEndpointID: bluetoothID,
                key: key
            )
        }
        let frame = KeepTalkingIrohPeerFrame.Hello.frame(blobs)
        let doorbells = state.withLockedValue { state in
            endpointIDs.compactMap { id -> AsyncStream<Void>.Continuation? in
                guard state.table.links[id]?.isConnected == true else { return nil }
                state.outbound.enqueue(frame, for: Self.linkQueue(id))
                return state.io[id]?.doorbells[.control]
            }
        }
        doorbells.forEach { $0.yield() }
    }

    /// A peer's hello. Each blob one of our contexts opens — naming the id
    /// this link authenticated — makes it a member there; a context it no
    /// longer lists, it has left. A hello that opens nowhere marks a
    /// stranger, whose link we drop.
    private func handleHello(_ payload: Data, from endpointID: Data) {
        let now = clock.now
        let snapshot = state.withLockedValue {
            state -> (LinkKind, [(Data, KeepTalkingIrohPresenceSeal.Key)])? in
            guard let kind = state.table.links[endpointID]?.kind,
                state.table.admitHello(endpointID, now: now, interval: Self.helloInterval)
            else { return nil }
            return (kind, state.membership.contexts.map { ($0.key, $0.value.key) })
        }
        guard let snapshot else { return }
        let (kind, keys) = snapshot
        guard let blobs = KeepTalkingIrohPeerFrame.Hello.decode(payload) else {
            log("malformed hello from \(Self.hex(endpointID).prefix(10))")
            return
        }
        // Open outside the lock: up to 64 blobs × contexts of AES-GCM.
        var opened: [(topic: Data, presence: KeepTalkingIrohPresenceSeal.Presence)] = []
        for (topic, key) in keys {
            if let presence = blobs.lazy.compactMap({ KeepTalkingIrohPresenceSeal.open($0, key: key) }).first {
                opened.append((topic, presence))
            }
        }
        let source: KeepTalkingIrohMembership.Source =
            kind == .bluetooth ? .bluetoothLink(endpointID) : .networkLink(endpointID)
        let outcome = mutateLinks(touching: [endpointID]) { state -> HelloOutcome in
            var outcome = HelloOutcome()
            var listed: Set<Data> = []
            let myID = state.myEndpointID
            for (topic, presence) in opened {
                switch state.membership.learn(presence, in: topic, from: source, myID: myID, now: now) {
                    case .member(let nodeID, let main, let isNew):
                        listed.insert(topic)
                        outcome.learned.append((nodeID, main, presence.bluetoothEndpointID, isNew))
                    case .ourselves:
                        listed.insert(topic)
                    case .rejected(let reason):
                        outcome.rejected.append(reason)
                }
            }
            outcome.departures = state.membership.helloListed(listed, from: endpointID)
            for departure in outcome.departures {
                outcome.departedSinks.append(state.attachments[departure.topic]?.sink)
            }
            var unlink = outcome.departures.flatMap(\.unlink)
            if listed.isEmpty {
                outcome.stranger = true
                if kind == .bluetooth { state.bluetooth.strangers.insert(endpointID) }
                unlink.append(endpointID)
            } else {
                state.bluetooth.strangers.remove(endpointID)
            }
            outcome.orphans = state.dropUnneededLinks(among: unlink)
            return outcome
        }
        outcome.orphans.forEach { Self.tearDown($0, reason: "no shared context") }
        for (departure, sink) in zip(outcome.departures, outcome.departedSinks) {
            log("member \(departure.nodeID.uuidString.prefix(8)) left topic \(Self.hex(departure.topic).prefix(10))")
            sink?.memberLeft(departure.nodeID)
        }
        for reason in outcome.rejected {
            log("hello from \(Self.hex(endpointID).prefix(10)) rejected: \(reason)")
        }
        if outcome.stranger {
            log("hello from \(Self.hex(endpointID).prefix(10)): no shared context")
        }
        for (nodeID, main, bluetooth, isNew) in outcome.learned {
            if isNew { log("member \(nodeID.uuidString.prefix(8)) met over \(kind.rawValue)") }
            ensureLink(to: main, kind: .network)
            if let bluetooth { ensureLink(to: bluetooth, kind: .bluetooth) }
        }
    }

    struct HelloOutcome {
        var learned: [(nodeID: UUID, main: Data, bluetooth: Data?, isNew: Bool)] = []
        var rejected: [String] = []
        var departures: [KeepTalkingIrohMembership.Departure] = []
        var departedSinks: [KeepTalkingIrohAttachment?] = []
        var stranger = false
        var orphans: [LinkIO] = []
    }

    // MARK: - Helpers

    static func selectedPath(_ connection: Connection) -> String {
        guard let path = connection.paths().first(where: \.isSelected) else { return "none" }
        switch pathKind(path) {
            case "relay": return "relay"
            case "bluetooth": return "bluetooth"
            default: return "direct \(path.remoteAddr)"
        }
    }

    /// `relay`, `ip`, or `bluetooth` (the only custom transport we add).
    static func pathKind(_ path: PathSnapshot) -> String {
        path.isRelay ? "relay" : (path.isIp ? "ip" : "bluetooth")
    }
}
#endif
