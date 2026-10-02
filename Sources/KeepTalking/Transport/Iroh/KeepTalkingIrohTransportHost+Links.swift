#if canImport(IrohLib)
import Foundation
import IrohLib

/// Peer links: dialling, accepting, the per-link pump that drains member
/// queues, reading frames, hellos, and what happens when a link closes or
/// loses its paths.
extension KeepTalkingIrohTransportHost {
    typealias LinkKind = KeepTalkingIrohLinkTable.Kind

    // MARK: - Dialling

    /// Dials `endpointID` when it's wanted, it's our turn and backoff allows;
    /// the other side waits for us.
    func ensureLink(to endpointID: Data, kind: LinkKind) {
        let now = clock.now
        let token = state.withLockedValue { state -> UInt64? in
            let myID = kind == .network ? state.myEndpointID : state.bluetooth.myID
            let endpoint = kind == .network ? state.endpoint : state.bluetooth.endpoint
            guard !state.isShutDown, endpoint != nil, let myID, state.isWanted(endpointID) else { return nil }
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
            let endpoint = state.withLockedValue { state -> Endpoint? in
                guard state.table.ownsDial(endpointID, token: token), state.isWanted(endpointID) else {
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
                try? await Task.sleep(for: .seconds(min(1 << min(attempt, 4), 16)))
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
        let (doorbell, bell) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
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
            state.io[endpointID] = LinkIO(connection: connection, doorbell: bell)
            return (true, replaced)
        }
        guard outcome.installed else {
            bell.finish()
            try? connection.close(errorCode: 0, reason: Data("unwanted".utf8))
            return
        }
        if let replaced = outcome.replaced { Self.tearDown(replaced, reason: "superseded") }

        let watcher = LinkPathWatcher(host: self, endpointID: endpointID, stableID: stableID)
        let watch = connection.watchPathEvents(callback: watcher)
        let tasks = [
            Task { await self.pump(endpointID, stableID: stableID, connection: connection, doorbell: doorbell) },
            Task { await self.readLoop(endpointID, stableID: stableID, connection: connection) },
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
        bell.yield()
        sendHello(to: [endpointID])
    }

    // MARK: - Pump, read, datagrams

    /// Writes what's queued for this link: its own frames (hellos), then the
    /// queues of the members it carries. Wakes on its doorbell.
    private func pump(
        _ endpointID: Data,
        stableID: UInt64,
        connection: Connection,
        doorbell: AsyncStream<Void>
    ) async {
        do {
            let send = try await connection.openUni()
            for await _ in doorbell {
                while true {
                    let batch = state.withLockedValue { state -> [Data]? in
                        guard state.table.isCurrent(endpointID, stableID: stableID) else { return nil }
                        let own = state.outbound.drain(Self.linkQueue(endpointID))
                        if !own.isEmpty { return own }
                        for main in state.carried(by: endpointID) {
                            let batch = state.outbound.drain(main)
                            if !batch.isEmpty { return batch }
                        }
                        return []
                    }
                    guard let batch else { return }
                    if batch.isEmpty { break }
                    for frame in batch {
                        try await send.writeAll(buf: frame)
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
            try? await send.finish()
        } catch {
            if connection.closeReason() == nil {
                log("peer \(Self.hex(endpointID).prefix(10)) write: \(error.localizedDescription)")
                try? connection.close(errorCode: 1, reason: Data("write failed".utf8))
            }
        }
    }

    private func readLoop(_ endpointID: Data, stableID: UInt64, connection: Connection) async {
        do {
            let recv = try await connection.acceptUni()
            while !Task.isCancelled {
                let prefix = try await recv.readExact(size: 4)
                // Until a link shows it shares a context, its frames stay small.
                let proven = state.withLockedValue { $0.membership.isMember(endpointID) }
                guard let length = KeepTalkingIrohPeerFrame.bodyLength(fromPrefix: prefix, proven: proven) else {
                    throw HostError.malformedFrame
                }
                let body = try await recv.readExact(size: UInt32(length))
                handlePeerFrame(body, from: endpointID)
            }
        } catch {
            // Without its read side the peer's writes go nowhere: end the
            // connection so the link falls back and redials.
            if connection.closeReason() == nil {
                log("peer \(Self.hex(endpointID).prefix(10)) read: \(error.localizedDescription)")
                try? connection.close(errorCode: 1, reason: Data("read failed".utf8))
            }
        }
    }

    private func datagramLoop(_ endpointID: Data, connection: Connection) async {
        while !Task.isCancelled {
            guard let datagram = try? await connection.readDatagram() else { return }
            guard let split = KeepTalkingIrohSFUFrame.splitDatagram(datagram) else { continue }
            let (topic, payload) = split
            let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID?)? in
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
        io?.doorbell?.finish()
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

    /// Delivered for any attached topic: the payload only opens for holders
    /// of the topic's key.
    private func handlePeerFrame(_ body: Data, from endpointID: Data) {
        guard let frame = KeepTalkingIrohPeerFrame.decode(body) else { return }
        if frame.kind == .hello {
            handleHello(frame.payload, from: endpointID)
            return
        }
        let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID?)? in
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
                return state.io[id]?.doorbell
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
        var departedSinks: [KeepTalkingIrohContextTransport?] = []
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
