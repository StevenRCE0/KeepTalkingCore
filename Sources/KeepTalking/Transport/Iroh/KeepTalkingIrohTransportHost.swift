#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// One iroh endpoint shared by every context attached to it.
///
/// The host owns the connection machinery that `ContextTransport` used to
/// spread over the SFU client, libjuice and the HTTP/2 direct channels:
///
/// - **Presence** rides one connection to the Rust `kt-sfu` hub
///   (`keeptalking/presence/1`). Each attached context is JOINed there and
///   gets a context-sealed blob carrying our node id and endpoint id.
/// - **Peers** are iroh connections (`keeptalking/peer/1`), one per remote
///   endpoint no matter how many contexts we share. They start on the hub's
///   embedded relay and upgrade to a direct path when hole punching works.
///   The lower endpoint id dials; the other side accepts.
/// - **Trust** comes from the seal, never the hub: a peer's frames reach a
///   context only if its endpoint id was announced in that context's sealed
///   presence.
///
/// The key is ephemeral (fresh per host), discovery is off (minimal preset,
/// our relay only). Per-context clients talk to the host through
/// `KeepTalkingIrohContextTransport` attachments.
@_spi(TransportLab)
public final class KeepTalkingIrohTransportHost: @unchecked Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Hub endpoint id (hex) printed by `kt-sfu`. Clients pin it.
        public var hubEndpointID: String
        /// Relay URL, e.g. `https://signal.rcex.live/`.
        public var relayURL: String
        /// QUIC address-discovery port of the relay; nil disables QAD.
        public var relayQUICPort: UInt16?

        public init(hubEndpointID: String, relayURL: String, relayQUICPort: UInt16? = nil) {
            self.hubEndpointID = hubEndpointID
            self.relayURL = relayURL
            self.relayQUICPort = relayQUICPort
        }
    }

    enum FrameKind: UInt8, Sendable {
        case envelope = 0x01
        case blob = 0x02
        case ping = 0x03
        case pong = 0x04
    }

    enum HostError: LocalizedError {
        case stopped
        case noConnectedPeers(UUID)
        case frameTooLarge(Int)

        var errorDescription: String? {
            switch self {
                case .stopped: return "The iroh transport host is stopped."
                case .noConnectedPeers(let context):
                    return "No peer of context \(context) is connected."
                case .frameTooLarge(let length): return "Peer frame of \(length) bytes is too large."
            }
        }
    }

    static let peerALPN = Data("keeptalking/peer/1".utf8)
    static let maxPeerFrameLength = 8 << 20
    private static let maxEvents = 300

    public let configuration: Configuration
    private let state = NIOLockedValueBox(State())

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Binds the endpoint and starts the accept and hub loops. Idempotent.
    public func start() async throws {
        let task = try state.withLockedValue { state -> Task<Endpoint, Error> in
            if state.isShutDown { throw HostError.stopped }
            if let task = state.startTask { return task }
            let task = Task { try await self.bindEndpoint() }
            state.startTask = task
            return task
        }
        _ = try await task.value
    }

    public func shutdown() async {
        let (endpoint, tasks, connections, writers) = state.withLockedValue { state in
            state.isShutDown = true
            let tasks = state.tasks + state.links.values.flatMap(\.tasks)
            let connections = state.links.values.compactMap(\.connection) + [state.hub.connection].compactMap { $0 }
            let writers = state.links.values.compactMap(\.writer) + [state.hub.writer].compactMap { $0 }
            state.tasks = []
            state.links = [:]
            state.hub = HubState()
            return (state.endpoint, tasks, connections, writers)
        }
        tasks.forEach { $0.cancel() }
        writers.forEach { $0.finish() }
        for connection in connections {
            try? connection.close(errorCode: 0, reason: Data("shutdown".utf8))
        }
        try? await endpoint?.close()
        log("host shut down")
    }

    private func bindEndpoint() async throws -> Endpoint {
        let options = EndpointOptions(
            preset: presetMinimal(),
            alpns: [Self.peerALPN],
            relayMode: try RelayMode.customFromUrls(urls: [configuration.relayURL])
        )
        let endpoint = try await Endpoint.bind(options: options)
        if let port = configuration.relayQUICPort {
            try await endpoint.insertRelay(
                config: RelayConfig(url: configuration.relayURL, quicPort: port, authToken: nil)
            )
        }
        let myID = endpoint.id().toBytes()
        let tasks = [
            Task { await self.acceptLoop(endpoint) },
            Task { await self.hubLoop(endpoint) },
        ]
        state.withLockedValue { state in
            state.endpoint = endpoint
            state.myEndpointID = myID
            state.tasks += tasks
        }
        log("endpoint \(Self.hex(myID).prefix(10)) bound \(endpoint.boundSockets().joined(separator: ", "))")
        return endpoint
    }

    // MARK: - Attachments

    /// Registers a context: JOINs it at the hub and publishes our sealed
    /// presence. The endpoint must be bound (`start()`).
    func attach(
        _ sink: KeepTalkingIrohContextTransport,
        contextID: UUID,
        nodeID: UUID,
        secret: Data
    ) throws {
        let (myID, writer) = try state.withLockedValue { state -> (Data, AsyncStream<Data>.Continuation?) in
            guard !state.isShutDown, let myID = state.myEndpointID else { throw HostError.stopped }
            return (myID, state.hub.writer)
        }
        let blob = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: nodeID,
            endpointID: myID,
            contextID: contextID,
            secret: secret
        )
        state.withLockedValue { state in
            state.contexts[contextID] = ContextEntry(
                nodeID: nodeID,
                sink: WeakSink(sink),
                secret: secret,
                blob: blob
            )
        }
        writer?.yield(KeepTalkingIrohPresenceFrame.encode(.join(context: contextID)))
        writer?.yield(KeepTalkingIrohPresenceFrame.encode(.publish(context: contextID, blob: blob)))
        log("ctx \(contextID.uuidString.prefix(8)) attached as node \(nodeID.uuidString.prefix(8))")
    }

    func detach(contextID: UUID) {
        let (writer, orphans) = state.withLockedValue { state -> (AsyncStream<Data>.Continuation?, [Connection]) in
            guard state.contexts.removeValue(forKey: contextID) != nil else { return (nil, []) }
            return (state.hub.writer, state.dropUnneededLinks())
        }
        writer?.yield(KeepTalkingIrohPresenceFrame.encode(.leave(context: contextID)))
        for connection in orphans {
            try? connection.close(errorCode: 0, reason: Data("left".utf8))
        }
        log("ctx \(contextID.uuidString.prefix(8)) detached")
    }

    // MARK: - Sending

    /// Queues one frame per connected member of `context` (only `target` when
    /// it is connected). Throws when nobody is connected, so callers such as
    /// the outbox keep the payload for a later drain.
    @discardableResult
    func send(_ kind: FrameKind, context: UUID, payload: Data, to target: UUID?) throws -> Int {
        let frame = Self.peerFrame(kind, context: context, payload: payload)
        guard frame.count - 4 <= Self.maxPeerFrameLength else {
            throw HostError.frameTooLarge(frame.count)
        }
        let writers = try state.withLockedValue { state -> [AsyncStream<Data>.Continuation] in
            guard !state.isShutDown else { throw HostError.stopped }
            var recipients = state.connectedMembers(of: context)
            if let target, let only = recipients.first(where: { $0.nodeID == target }) {
                recipients = [only]
            }
            var writers: [AsyncStream<Data>.Continuation] = []
            for recipient in recipients {
                guard let writer = state.links[recipient.endpointID]?.writer else { continue }
                state.links[recipient.endpointID]?.framesSent += 1
                state.links[recipient.endpointID]?.bytesSent += frame.count
                writers.append(writer)
            }
            return writers
        }
        guard !writers.isEmpty else { throw HostError.noConnectedPeers(context) }
        writers.forEach { $0.yield(frame) }
        return writers.count
    }

    /// Unreliable realtime bytes (voice) to every connected member.
    func sendDatagram(context: UUID, payload: Data) throws {
        var datagram = context.rfc4122Bytes
        datagram.append(payload)
        let connections = try state.withLockedValue { state -> [Connection] in
            guard !state.isShutDown else { throw HostError.stopped }
            return state.connectedMembers(of: context).compactMap { member in
                state.links[member.endpointID]?.datagramsSent += 1
                return state.links[member.endpointID]?.connection
            }
        }
        guard !connections.isEmpty else { throw HostError.noConnectedPeers(context) }
        for connection in connections {
            try? connection.sendDatagram(data: datagram)
        }
    }

    // MARK: - Reads for attachments

    var isHubReady: Bool {
        state.withLockedValue { $0.hub.status == .ready }
    }

    func hubChannelState() -> BroadcastChannelState {
        state.withLockedValue { state in
            switch state.hub.status {
                case .idle, .connecting(attempt: 0): return .connecting
                case .connecting(let attempt): return .reconnecting(attempt: attempt)
                case .ready: return .ready
            }
        }
    }

    func connectedMemberNodes(of context: UUID) -> [UUID] {
        state.withLockedValue { $0.connectedMembers(of: context).map(\.nodeID) }
    }

    /// True when some connected member of `context` talks over a direct path.
    func hasDirectMember(in context: UUID) -> Bool {
        let connections = state.withLockedValue { state in
            state.connectedMembers(of: context).compactMap { state.links[$0.endpointID]?.connection }
        }
        return connections.contains { connection in
            connection.paths().contains { $0.isSelected && $0.isIp }
        }
    }

    // MARK: - Hub

    private func hubLoop(_ endpoint: Endpoint) async {
        var attempt = 0
        while !Task.isCancelled, !state.withLockedValue({ $0.isShutDown }) {
            setHubStatus(.connecting(attempt: attempt))
            let started = ContinuousClock.now
            do {
                let hubID = try EndpointId.fromString(s: configuration.hubEndpointID)
                let connection = try await endpoint.connect(
                    addr: EndpointAddr(id: hubID, relayUrl: configuration.relayURL, addresses: []),
                    alpn: KeepTalkingIrohPresenceFrame.alpn
                )
                let stream = try await connection.openBi()
                let (frames, writer) = AsyncStream.makeStream(of: Data.self)
                let writerTask = Task {
                    let send = stream.send()
                    for await frame in frames {
                        do { try await send.writeAll(buf: frame) } catch { break }
                    }
                }
                let latency = ContinuousClock.now - started
                let rejoin = state.withLockedValue { state -> [Data] in
                    state.hub.connection = connection
                    state.hub.writer = writer
                    state.hub.connectLatency = latency
                    state.hub.connectedSince = Date()
                    state.hub.status = .ready
                    var frames: [Data] = []
                    for (context, entry) in state.contexts {
                        frames.append(KeepTalkingIrohPresenceFrame.encode(.join(context: context)))
                        frames.append(
                            KeepTalkingIrohPresenceFrame.encode(.publish(context: context, blob: entry.blob))
                        )
                    }
                    return frames
                }
                rejoin.forEach { writer.yield($0) }
                attempt = 0
                log("hub connected in \(Self.ms(latency))")
                notifyAllContexts { $0.hubStateChanged() }

                let recv = stream.recv()
                while !Task.isCancelled {
                    let prefix = try await recv.readExact(size: 4)
                    let length = try KeepTalkingIrohPresenceFrame.frameLength(fromPrefix: prefix)
                    let body = try await recv.readExact(size: UInt32(length))
                    handleHubFrame(try KeepTalkingIrohPresenceFrame.decodeServer(body))
                }
                writerTask.cancel()
            } catch {
                log("hub: \(error.localizedDescription)")
            }
            let connection = state.withLockedValue { state -> Connection? in
                let connection = state.hub.connection
                state.hub.writer?.finish()
                state.hub.writer = nil
                state.hub.connection = nil
                state.hub.connectedSince = nil
                for key in state.contexts.keys { state.contexts[key]?.joined = false }
                return connection
            }
            try? connection?.close(errorCode: 0, reason: Data("reconnect".utf8))
            attempt += 1
            notifyAllContexts { $0.hubStateChanged() }
            try? await Task.sleep(for: .seconds(min(1 << min(attempt - 1, 3), 8)))
        }
    }

    private func setHubStatus(_ status: HubStatus) {
        state.withLockedValue { state in
            state.hub.status = status
            if case .connecting = status { state.hub.attempts += 1 }
        }
    }

    private func handleHubFrame(_ frame: KeepTalkingIrohPresenceFrame.Server) {
        switch frame {
            case .snapshot(let context, let members):
                let sink = state.withLockedValue { state -> KeepTalkingIrohContextTransport? in
                    state.contexts[context]?.joined = true
                    return state.contexts[context]?.sink.value
                }
                log("ctx \(context.uuidString.prefix(8)) snapshot: \(members.count) other member(s)")
                for member in members where !member.blob.isEmpty {
                    learn(context: context, reportedID: member.endpointID, blob: member.blob)
                }
                sink?.hubJoined()
            case .joined(let context, let endpointID):
                log("ctx \(context.uuidString.prefix(8)) joined by \(Self.hex(endpointID).prefix(10))")
            case .presence(let context, let endpointID, let blob):
                learn(context: context, reportedID: endpointID, blob: blob)
            case .left(let context, let endpointID):
                let (sink, nodeID, orphans) = state.withLockedValue { state in
                    let nodeID = state.contexts[context]?.members.removeValue(forKey: endpointID)
                    return (state.contexts[context]?.sink.value, nodeID, state.dropUnneededLinks())
                }
                for connection in orphans {
                    try? connection.close(errorCode: 0, reason: Data("left".utf8))
                }
                log("ctx \(context.uuidString.prefix(8)) left by \(Self.hex(endpointID).prefix(10))")
                if let nodeID { sink?.memberLeft(nodeID) }
            case .error(let reason):
                log("hub error: \(reason)")
        }
    }

    /// Opens a member's sealed presence. Only a blob this context's secret
    /// opens, carrying the very id the hub reported, makes it a member.
    private func learn(context: UUID, reportedID: Data, blob: Data) {
        let outcome = state.withLockedValue { state -> LearnOutcome in
            guard let entry = state.contexts[context] else { return .ignored }
            guard let presence = KeepTalkingIrohPresenceSeal.open(blob, contextID: context, secret: entry.secret)
            else { return .unreadable }
            guard presence.endpointID == reportedID else { return .mismatch }
            guard presence.endpointID != state.myEndpointID else { return .ignored }
            state.contexts[context]?.members[presence.endpointID] = presence.nodeID
            let isConnected = state.links[presence.endpointID]?.connection != nil
            return .member(presence.nodeID, isConnected: isConnected, sink: entry.sink.value)
        }
        switch outcome {
            case .ignored:
                return
            case .unreadable:
                log(
                    "ctx \(context.uuidString.prefix(8)) presence from \(Self.hex(reportedID).prefix(10)) does not open"
                )
            case .mismatch:
                log(
                    "ctx \(context.uuidString.prefix(8)) presence id != hub id for \(Self.hex(reportedID).prefix(10)); dropped"
                )
            case .member(let nodeID, let isConnected, let sink):
                log(
                    "ctx \(context.uuidString.prefix(8)) member \(nodeID.uuidString.prefix(8)) @ \(Self.hex(reportedID).prefix(10))"
                )
                if isConnected {
                    sink?.peerLinkUp(nodeID)
                } else {
                    ensureLink(to: reportedID)
                }
        }
    }

    // MARK: - Peer links

    /// Dials `endpointID` when we hold the lower id; the other side waits.
    private func ensureLink(to endpointID: Data) {
        let shouldDial = state.withLockedValue { state -> Bool in
            guard
                !state.isShutDown,
                let myID = state.myEndpointID,
                myID.lexicographicallyPrecedes(endpointID),
                state.links[endpointID] == nil
            else { return false }
            state.links[endpointID] = PeerLink(side: .dialed)
            return true
        }
        guard shouldDial else { return }
        let task = Task { await self.dialLoop(endpointID) }
        state.withLockedValue { $0.links[endpointID]?.tasks.append(task) }
    }

    private func dialLoop(_ endpointID: Data) async {
        var attempt = 0
        while !Task.isCancelled {
            let endpoint = state.withLockedValue { state -> Endpoint? in
                guard state.isWanted(endpointID) else { return nil }
                state.links[endpointID]?.dialAttempts += 1
                return state.endpoint
            }
            guard let endpoint else {
                state.withLockedValue { state in
                    if state.links[endpointID]?.connection == nil { state.links[endpointID] = nil }
                }
                return
            }
            let started = ContinuousClock.now
            do {
                let connection = try await endpoint.connect(
                    addr: EndpointAddr(
                        id: try EndpointId.fromBytes(bytes: endpointID),
                        relayUrl: configuration.relayURL,
                        addresses: []
                    ),
                    alpn: Self.peerALPN
                )
                install(connection, endpointID: endpointID, side: .dialed, latency: ContinuousClock.now - started)
                return
            } catch {
                attempt += 1
                log("dial \(Self.hex(endpointID).prefix(10)) failed (#\(attempt)): \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(min(1 << min(attempt, 4), 16)))
            }
        }
    }

    private func acceptLoop(_ endpoint: Endpoint) async {
        while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
            Task {
                let started = ContinuousClock.now
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
                        latency: ContinuousClock.now - started
                    )
                } catch {
                    log("accept failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func install(
        _ connection: Connection,
        endpointID: Data,
        side: PeerLink.Side,
        latency: Duration
    ) {
        let (frames, writer) = AsyncStream.makeStream(of: Data.self)
        let watcher = LinkPathWatcher(host: self, endpointID: endpointID, stableID: connection.stableId())
        let watch = connection.watchPathEvents(callback: watcher)
        let replaced = state.withLockedValue { state -> PeerLink? in
            let previous = state.links[endpointID]
            var link = PeerLink(side: side)
            link.connection = connection
            link.writer = writer
            link.watch = watch
            link.connectLatency = latency
            link.connectedAt = ContinuousClock.now
            link.dialAttempts = previous?.dialAttempts ?? 0
            state.links[endpointID] = link
            return previous
        }
        // A reconnect (either side) supersedes the old link.
        replaced?.writer?.finish()
        replaced?.tasks.forEach { $0.cancel() }
        try? replaced?.connection?.close(errorCode: 0, reason: Data("superseded".utf8))

        let tasks = [
            Task { await self.writeLoop(connection, frames: frames, endpointID: endpointID) },
            Task { await self.readLoop(connection, endpointID: endpointID) },
            Task { await self.datagramLoop(connection, endpointID: endpointID) },
            Task { await self.watchClosed(connection, endpointID: endpointID) },
        ]
        state.withLockedValue { $0.links[endpointID]?.tasks = tasks }
        log(
            "peer \(Self.hex(endpointID).prefix(10)) \(side.rawValue) in \(Self.ms(latency)) via \(Self.selectedPath(connection))"
        )
        notifyMembership(of: endpointID) { sink, nodeID in sink.peerLinkUp(nodeID) }
    }

    private func writeLoop(_ connection: Connection, frames: AsyncStream<Data>, endpointID: Data) async {
        do {
            let send = try await connection.openUni()
            for await frame in frames {
                try await send.writeAll(buf: frame)
            }
            try? await send.finish()
        } catch {
            log("peer \(Self.hex(endpointID).prefix(10)) write: \(error.localizedDescription)")
        }
    }

    private func readLoop(_ connection: Connection, endpointID: Data) async {
        do {
            let recv = try await connection.acceptUni()
            while !Task.isCancelled {
                let prefix = try await recv.readExact(size: 4)
                let length = Int(prefix.readBigEndianUInt32(at: prefix.startIndex))
                guard (17...Self.maxPeerFrameLength).contains(length) else {
                    throw HostError.frameTooLarge(length)
                }
                let body = try await recv.readExact(size: UInt32(length))
                handlePeerFrame(body, from: endpointID, connection: connection)
            }
        } catch {
            if connection.closeReason() == nil {
                log("peer \(Self.hex(endpointID).prefix(10)) read: \(error.localizedDescription)")
            }
        }
    }

    private func datagramLoop(_ connection: Connection, endpointID: Data) async {
        while !Task.isCancelled {
            guard let datagram = try? await connection.readDatagram() else { return }
            guard datagram.count >= 16 else { continue }
            let context = UUID(rfc4122Bytes: Data(datagram.prefix(16)))
            let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID)? in
                state.links[endpointID]?.datagramsReceived += 1
                guard
                    let entry = state.contexts[context],
                    let nodeID = entry.members[endpointID],
                    let sink = entry.sink.value
                else { return nil }
                return (sink, nodeID)
            }
            if let route {
                route.0.deliverRealtime(Data(datagram.dropFirst(16)), from: route.1)
            }
        }
    }

    private func watchClosed(_ connection: Connection, endpointID: Data) async {
        let reason = await connection.closed()
        let stableID = connection.stableId()
        let (wasCurrent, redial) = state.withLockedValue { state -> (Bool, Bool) in
            guard state.links[endpointID]?.connection?.stableId() == stableID else { return (false, false) }
            state.links[endpointID]?.writer?.finish()
            let side = state.links[endpointID]?.side
            state.links[endpointID] = nil
            return (true, side == .dialed && state.isWanted(endpointID))
        }
        guard wasCurrent else { return }
        log("peer \(Self.hex(endpointID).prefix(10)) closed: \(reason)")
        notifyMembership(of: endpointID) { sink, nodeID in sink.peerLinkDown(nodeID) }
        if redial { ensureLink(to: endpointID) }
    }

    private func handlePeerFrame(_ body: Data, from endpointID: Data, connection: Connection) {
        guard let kind = FrameKind(rawValue: body[body.startIndex]) else { return }
        let context = UUID(rfc4122Bytes: Data(body[(body.startIndex + 1)..<(body.startIndex + 17)]))
        let payload = Data(body.dropFirst(17))
        let route = state.withLockedValue {
            state -> (KeepTalkingIrohContextTransport, UUID, AsyncStream<Data>.Continuation?)? in
            state.links[endpointID]?.framesReceived += 1
            state.links[endpointID]?.bytesReceived += body.count + 4
            guard
                let entry = state.contexts[context],
                let nodeID = entry.members[endpointID],
                let sink = entry.sink.value
            else {
                state.droppedFrames += 1
                return nil
            }
            return (sink, nodeID, state.links[endpointID]?.writer)
        }
        guard let route else { return }
        let (sink, nodeID, writer) = route
        switch kind {
            case .ping:
                writer?.yield(Self.peerFrame(.pong, context: context, payload: payload))
                sink.peerHeard(nodeID)
            case .pong:
                sink.peerHeard(nodeID)
            case .envelope, .blob:
                sink.deliver(kind, payload: payload, from: nodeID)
        }
    }

    fileprivate func pathEvent(_ event: PathEvent, endpointID: Data, stableID: UInt64) {
        let connection = state.withLockedValue { state -> Connection? in
            guard let connection = state.links[endpointID]?.connection, connection.stableId() == stableID
            else { return nil }
            return connection
        }
        guard let connection, case .selected = event else { return }
        let isDirect = connection.paths().contains { $0.isSelected && $0.isIp }
        let firstDirect = state.withLockedValue { state -> Duration? in
            guard isDirect, state.links[endpointID]?.timeToDirect == nil,
                let connectedAt = state.links[endpointID]?.connectedAt
            else { return nil }
            let elapsed = ContinuousClock.now - connectedAt
            state.links[endpointID]?.timeToDirect = elapsed
            return elapsed
        }
        if let firstDirect {
            log(
                "peer \(Self.hex(endpointID).prefix(10)) direct after \(Self.ms(firstDirect)) via \(Self.selectedPath(connection))"
            )
        } else {
            log("peer \(Self.hex(endpointID).prefix(10)) path → \(Self.selectedPath(connection))")
        }
        notifyMembership(of: endpointID) { sink, _ in sink.routeMayHaveChanged() }
    }

    // MARK: - Notifications

    private func notifyMembership(
        of endpointID: Data,
        _ body: (KeepTalkingIrohContextTransport, UUID) -> Void
    ) {
        let targets = state.withLockedValue { state in
            state.contexts.values.compactMap { entry -> (KeepTalkingIrohContextTransport, UUID)? in
                guard let nodeID = entry.members[endpointID], let sink = entry.sink.value else { return nil }
                return (sink, nodeID)
            }
        }
        for (sink, nodeID) in targets { body(sink, nodeID) }
    }

    private func notifyAllContexts(_ body: (KeepTalkingIrohContextTransport) -> Void) {
        let sinks = state.withLockedValue { $0.contexts.values.compactMap(\.sink.value) }
        sinks.forEach(body)
    }

    // MARK: - Instruments

    /// A point-in-time reading of the endpoint, the hub session, every
    /// context and every peer link, plus the recent event log.
    public func instruments() -> KeepTalkingIrohInstruments {
        let snapshot = state.withLockedValue { $0 }
        let hubConnection = snapshot.hub.connection
        let hubPath = hubConnection.map(Self.selectedPath)
        var hubStatus: String
        switch snapshot.hub.status {
            case .idle: hubStatus = "idle"
            case .connecting(let attempt): hubStatus = attempt == 0 ? "connecting" : "reconnecting #\(attempt)"
            case .ready: hubStatus = "ready"
        }
        if snapshot.isShutDown { hubStatus = "shut down" }

        let nodeByEndpoint = snapshot.contexts.values.reduce(into: [Data: Set<UUID>]()) { result, entry in
            for (endpointID, nodeID) in entry.members { result[endpointID, default: []].insert(nodeID) }
        }
        let peers = snapshot.links.map { endpointID, link -> KeepTalkingIrohInstruments.Peer in
            let connection = link.connection
            let paths = connection?.paths() ?? []
            let stats = connection?.stats()
            return KeepTalkingIrohInstruments.Peer(
                id: Self.hex(endpointID),
                nodeIDs: nodeByEndpoint[endpointID].map { Array($0) } ?? [],
                side: link.side.rawValue,
                status: connection == nil
                    ? "dialing (#\(link.dialAttempts))"
                    : (connection?.closeReason().map { "closed: \($0)" } ?? "connected"),
                connectLatencyMs: link.connectLatency.map(Self.milliseconds),
                timeToDirectMs: link.timeToDirect.map(Self.milliseconds),
                isDirect: paths.contains { $0.isSelected && $0.isIp },
                selectedPath: connection.map(Self.selectedPath),
                rttMs: connection?.rtt(),
                paths: paths.map { path in
                    KeepTalkingIrohInstruments.Path(
                        remoteAddress: path.remoteAddr,
                        isRelay: path.isRelay,
                        isSelected: path.isSelected,
                        rttMs: path.rttMs
                    )
                },
                framesSent: link.framesSent,
                framesReceived: link.framesReceived,
                bytesSent: link.bytesSent,
                bytesReceived: link.bytesReceived,
                datagramsSent: link.datagramsSent,
                datagramsReceived: link.datagramsReceived,
                lostPackets: stats?.lostPackets
            )
        }
        return KeepTalkingIrohInstruments(
            endpointID: snapshot.myEndpointID.map(Self.hex),
            boundSockets: snapshot.endpoint?.boundSockets() ?? [],
            hub: KeepTalkingIrohInstruments.Hub(
                status: hubStatus,
                attempts: snapshot.hub.attempts,
                connectLatencyMs: snapshot.hub.connectLatency.map(Self.milliseconds),
                connectedSince: snapshot.hub.connectedSince,
                selectedPath: hubPath,
                rttMs: hubConnection?.rtt()
            ),
            contexts: snapshot.contexts.map { contextID, entry in
                KeepTalkingIrohInstruments.Context(
                    id: contextID,
                    nodeID: entry.nodeID,
                    joined: entry.joined,
                    members: entry.members.map { endpointID, nodeID in
                        KeepTalkingIrohInstruments.Member(nodeID: nodeID, endpointID: Self.hex(endpointID))
                    }
                )
            },
            peers: peers.sorted { $0.id < $1.id },
            droppedFrames: snapshot.droppedFrames,
            events: snapshot.events
        )
    }

    func log(_ text: String) {
        state.withLockedValue { state in
            state.nextEventID += 1
            state.events.append(.init(id: state.nextEventID, at: Date(), text: text))
            if state.events.count > Self.maxEvents {
                state.events.removeFirst(state.events.count - Self.maxEvents)
            }
        }
    }

    // MARK: - Helpers

    static func peerFrame(_ kind: FrameKind, context: UUID, payload: Data) -> Data {
        var frame = Data(capacity: 21 + payload.count)
        frame.appendBigEndian(UInt32(17 + payload.count))
        frame.append(kind.rawValue)
        frame.append(context.rfc4122Bytes)
        frame.append(payload)
        return frame
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func selectedPath(_ connection: Connection) -> String {
        guard let path = connection.paths().first(where: \.isSelected) else { return "none" }
        return path.isRelay ? "relay" : "direct \(path.remoteAddr)"
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.0fms", milliseconds(duration))
    }
}

// MARK: - State

extension KeepTalkingIrohTransportHost {
    fileprivate enum HubStatus: Equatable {
        case idle
        case connecting(attempt: Int)
        case ready
    }

    fileprivate struct HubState {
        var status: HubStatus = .idle
        var connection: Connection?
        var writer: AsyncStream<Data>.Continuation?
        var attempts = 0
        var connectLatency: Duration?
        var connectedSince: Date?
    }

    fileprivate struct WeakSink {
        weak var value: KeepTalkingIrohContextTransport?
        init(_ value: KeepTalkingIrohContextTransport) { self.value = value }
    }

    fileprivate struct ContextEntry {
        let nodeID: UUID
        let sink: WeakSink
        let secret: Data
        let blob: Data
        /// True once the hub's snapshot for this context arrived.
        var joined = false
        /// Endpoint id → node id, from sealed presence only.
        var members: [Data: UUID] = [:]
    }

    fileprivate struct PeerLink {
        enum Side: String { case dialed, accepted }

        let side: Side
        var connection: Connection?
        var writer: AsyncStream<Data>.Continuation?
        var watch: WatchHandle?
        var tasks: [Task<Void, Never>] = []
        var dialAttempts = 0
        var connectLatency: Duration?
        var connectedAt: ContinuousClock.Instant?
        var timeToDirect: Duration?
        var framesSent = 0
        var framesReceived = 0
        var bytesSent = 0
        var bytesReceived = 0
        var datagramsSent = 0
        var datagramsReceived = 0

        init(side: Side) { self.side = side }
    }

    fileprivate enum LearnOutcome {
        case ignored
        case unreadable
        case mismatch
        case member(UUID, isConnected: Bool, sink: KeepTalkingIrohContextTransport?)
    }

    fileprivate struct State {
        var isShutDown = false
        var startTask: Task<Endpoint, Error>?
        var endpoint: Endpoint?
        var myEndpointID: Data?
        var tasks: [Task<Void, Never>] = []
        var hub = HubState()
        var contexts: [UUID: ContextEntry] = [:]
        var links: [Data: PeerLink] = [:]
        var droppedFrames = 0
        var events: [KeepTalkingIrohInstruments.Event] = []
        var nextEventID = 0

        /// Members of `context` whose link is connected.
        func connectedMembers(of context: UUID) -> [(endpointID: Data, nodeID: UUID)] {
            guard let members = contexts[context]?.members else { return [] }
            return members.compactMap { endpointID, nodeID in
                links[endpointID]?.connection == nil ? nil : (endpointID, nodeID)
            }
        }

        func isWanted(_ endpointID: Data) -> Bool {
            !isShutDown && contexts.values.contains { $0.members[endpointID] != nil }
        }

        /// Forgets links no attached context needs; returns what to close.
        mutating func dropUnneededLinks() -> [Connection] {
            var orphans: [Connection] = []
            for (endpointID, link) in links where !isWanted(endpointID) {
                link.writer?.finish()
                link.tasks.forEach { $0.cancel() }
                if let connection = link.connection { orphans.append(connection) }
                links[endpointID] = nil
            }
            return orphans
        }
    }
}

/// Forwards iroh path events of one connection back to the host.
private final class LinkPathWatcher: PathEventCallback, @unchecked Sendable {
    private weak var host: KeepTalkingIrohTransportHost?
    private let endpointID: Data
    private let stableID: UInt64

    init(host: KeepTalkingIrohTransportHost, endpointID: Data, stableID: UInt64) {
        self.host = host
        self.endpointID = endpointID
        self.stableID = stableID
    }

    func onEvent(event: PathEvent) async throws {
        host?.pathEvent(event, endpointID: endpointID, stableID: stableID)
    }
}
#endif
