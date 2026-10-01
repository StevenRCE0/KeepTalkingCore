#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// One iroh endpoint shared by every context attached to it.
///
/// The host owns the connection machinery that `ContextTransport` used to
/// spread over the SFU client, libjuice and the HTTP/2 direct channels:
///
/// - **Hub** — one connection to the Rust `kt-sfu` hub
///   (`keeptalking/hub/1`). Each attached context subscribes to its *topic*
///   (`KeepTalkingIrohTopic`, derived from the context secret) and announces
///   a sealed blob carrying our node id and endpoint id. The hub also fans
///   publishes and datagrams out to the topic, so a sender uploads once.
/// - **Mesh** — iroh connections (`keeptalking/peer/1`), one per remote
///   endpoint however many topics we share. They start on the relay and go
///   direct when hole punching works. The lower endpoint id dials.
/// - **Delivery** — each publish goes through the hub or the mesh, chosen
///   per publish by `DeliveryPolicy`. Receivers take both; KeepTalking
///   absorbs duplicates by row id.
///
/// Frames for an attached topic are delivered whoever sent them: content is
/// sealed with the topic's key, so only members can produce anything that
/// opens. Endpoint ids to dial still come only from sealed presence, never
/// from the hub. The key is ephemeral; discovery is off (minimal preset, our
/// relay only); the hub id comes from configuration or `<relay>/kt/hub`.
@_spi(TransportLab)
public final class KeepTalkingIrohTransportHost: @unchecked Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Relay URL, e.g. `https://signal.rcex.live/`.
        public var relayURL: String
        /// Hub endpoint id (hex). Nil looks it up at `<relay>/kt/hub`.
        public var hubEndpointID: String?
        /// QUIC address-discovery port of the relay. Nil takes it from
        /// `/kt/hub` (and disables QAD if the hub id is configured by hand).
        public var relayQUICPort: UInt16?

        public init(relayURL: String, hubEndpointID: String? = nil, relayQUICPort: UInt16? = nil) {
            self.relayURL = relayURL
            self.hubEndpointID = hubEndpointID
            self.relayQUICPort = relayQUICPort
        }
    }

    /// Where a publish goes. Receivers accept both routes, so senders never
    /// have to agree on a mode.
    public enum DeliveryPolicy: Sendable, Hashable {
        /// The hub once the room has at least `hubAtMembers` other members,
        /// the mesh below that; whichever route is up when the other isn't.
        case automatic(hubAtMembers: Int)
        /// Mesh; the hub only while no member is connected.
        case preferMesh
        /// Hub; the mesh only while the hub is down.
        case preferHub

        public static let standard = DeliveryPolicy.automatic(hubAtMembers: 4)
    }

    public enum Route: String, Sendable {
        case mesh
        case hub
    }

    enum FrameKind: UInt8, Sendable {
        case envelope = 0x01
        case blob = 0x02
        case ping = 0x03
        case pong = 0x04
    }

    enum HostError: LocalizedError {
        case stopped
        case notAttached
        case noRoute
        case frameTooLarge(Int)
        case hubInfo(String)

        var errorDescription: String? {
            switch self {
                case .stopped: return "The iroh transport host is stopped."
                case .notAttached: return "The context is not attached to the iroh host."
                case .noRoute: return "Neither the hub nor any member is reachable."
                case .frameTooLarge(let length): return "Frame of \(length) bytes is too large."
                case .hubInfo(let reason): return "Hub lookup failed: \(reason)"
            }
        }
    }

    static let peerALPN = Data("keeptalking/peer/1".utf8)
    static let maxPeerFrameLength = 8 << 20
    private static let maxEvents = 300

    public let configuration: Configuration
    private let state = NIOLockedValueBox(State())

    public init(configuration: Configuration, policy: DeliveryPolicy = .standard) {
        self.configuration = configuration
        state.withLockedValue { $0.policy = policy }
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
            let connections =
                state.links.values.compactMap(\.connection) + [state.hub.connection].compactMap { $0 }
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

    public var deliveryPolicy: DeliveryPolicy {
        get { state.withLockedValue { $0.policy } }
        set { state.withLockedValue { $0.policy = newValue } }
    }

    /// Lab switch: drop the hub session and keep it down until resumed, so
    /// the rest of the host runs as if the hub were unreachable.
    public func setHubSuspended(_ suspended: Bool) {
        let connection = state.withLockedValue { state -> Connection? in
            state.hub.suspended = suspended
            return suspended ? state.hub.connection : nil
        }
        try? connection?.close(errorCode: 0, reason: Data("suspended".utf8))
        log(suspended ? "hub suspended" : "hub resumed")
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

    /// Registers a context: subscribes to its topic at the hub and announces
    /// our sealed presence. The endpoint must be bound (`start()`).
    func attach(
        _ sink: KeepTalkingIrohContextTransport,
        topic: KeepTalkingIrohTopic,
        nodeID: UUID,
        secret: Data
    ) throws {
        let myID = try state.withLockedValue { state -> Data in
            guard !state.isShutDown, let myID = state.myEndpointID else { throw HostError.stopped }
            return myID
        }
        let blob = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: nodeID,
            endpointID: myID,
            contextID: topic.contextID,
            secret: secret
        )
        // Insert and read the hub writer in one critical section: the hub
        // loop publishes its writer and collects topics to re-subscribe in
        // one too, so either it sees this topic or we see its writer.
        let writer = state.withLockedValue { state -> AsyncStream<Data>.Continuation? in
            state.contexts[topic.topic] = ContextEntry(
                topic: topic,
                nodeID: nodeID,
                sink: WeakSink(sink),
                secret: secret,
                blob: blob
            )
            return state.hub.writer
        }
        writer?.yield(KeepTalkingIrohHubFrame.encode(.subscribe(topic: topic.topic)))
        writer?.yield(KeepTalkingIrohHubFrame.encode(.announce(topic: topic.topic, blob: blob)))
        log("ctx \(topic.contextID.uuidString.prefix(8)) attached on topic \(Self.hex(topic.topic).prefix(10))")
    }

    func detach(topic: Data) {
        let (writer, orphans) = state.withLockedValue { state -> (AsyncStream<Data>.Continuation?, [Connection]) in
            guard let removed = state.contexts.removeValue(forKey: topic) else { return (nil, []) }
            return (state.hub.writer, state.dropUnneededLinks(among: Array(removed.members.keys)))
        }
        writer?.yield(KeepTalkingIrohHubFrame.encode(.unsubscribe(topic: topic)))
        for connection in orphans {
            try? connection.close(errorCode: 0, reason: Data("left".utf8))
        }
        log("topic \(Self.hex(topic).prefix(10)) detached")
    }

    // MARK: - Sending

    /// Publishes one frame to `topic`. A directed frame goes straight to its
    /// target when that member is connected; everything else goes through
    /// the hub or the mesh per `DeliveryPolicy`. Throws when neither route
    /// is up, so callers such as the outbox keep the payload.
    @discardableResult
    func publish(_ kind: FrameKind, topic: Data, payload: Data, to target: UUID?) throws -> Route {
        var body = Data(capacity: 1 + payload.count)
        body.append(kind.rawValue)
        body.append(payload)
        guard body.count <= KeepTalkingIrohHubFrame.maxPublishLength else {
            throw HostError.frameTooLarge(body.count)
        }
        let (route, writers) = try state.withLockedValue { state -> (Route, [AsyncStream<Data>.Continuation]) in
            guard !state.isShutDown else { throw HostError.stopped }
            guard state.contexts[topic] != nil else { throw HostError.notAttached }
            let members = state.connectedMembers(of: topic)
            if let target, let member = members.first(where: { $0.nodeID == target }),
                let writer = state.links[member.endpointID]?.writer
            {
                state.countMesh(topic: topic, endpointIDs: [member.endpointID], bytes: body.count + 36)
                return (.mesh, [writer])
            }
            switch state.route(for: topic, connectedMembers: members.count) {
                case .hub?:
                    guard let writer = state.hub.writer else { throw HostError.noRoute }
                    state.contexts[topic]?.hubPublished += 1
                    return (.hub, [writer])
                case .mesh?:
                    let ids = members.map(\.endpointID)
                    state.countMesh(topic: topic, endpointIDs: ids, bytes: body.count + 36)
                    return (.mesh, ids.compactMap { state.links[$0]?.writer })
                case nil:
                    throw HostError.noRoute
            }
        }
        switch route {
            case .hub:
                writers.forEach {
                    $0.yield(KeepTalkingIrohHubFrame.encode(.publish(topic: topic, payload: body)))
                }
            case .mesh:
                let frame = Self.peerFrame(topic: topic, body: body)
                writers.forEach { $0.yield(frame) }
        }
        return route
    }

    /// Unreliable realtime bytes (voice), routed like a publish.
    func sendDatagram(topic: Data, payload: Data) throws {
        let datagram = KeepTalkingIrohHubFrame.datagram(topic: topic, payload: payload)
        let connections = try state.withLockedValue { state -> [Connection] in
            guard !state.isShutDown else { throw HostError.stopped }
            let members = state.connectedMembers(of: topic)
            switch state.route(for: topic, connectedMembers: members.count) {
                case .hub?:
                    state.contexts[topic]?.hubDatagramsSent += 1
                    return [state.hub.connection].compactMap { $0 }
                case .mesh?:
                    return members.compactMap { member in
                        state.links[member.endpointID]?.datagramsSent += 1
                        return state.links[member.endpointID]?.connection
                    }
                case nil:
                    throw HostError.noRoute
            }
        }
        guard !connections.isEmpty else { throw HostError.noRoute }
        for connection in connections {
            try? connection.sendDatagram(data: datagram)
        }
    }

    // MARK: - Reads for attachments

    func hubChannelState() -> BroadcastChannelState {
        state.withLockedValue { state in
            switch state.hub.status {
                case .idle, .connecting(attempt: 0): return .connecting
                case .connecting(let attempt): return .reconnecting(attempt: attempt)
                case .ready: return .ready
            }
        }
    }

    func connectedMemberNodes(of topic: Data) -> [UUID] {
        state.withLockedValue { $0.connectedMembers(of: topic).map(\.nodeID) }
    }

    /// True when the hub or some member can take a publish for `topic`.
    func canDeliver(to topic: Data) -> Bool {
        state.withLockedValue { state in
            state.route(for: topic, connectedMembers: state.connectedMembers(of: topic).count) != nil
        }
    }

    /// True when some connected member of `topic` talks over a direct path.
    func hasDirectMember(in topic: Data) -> Bool {
        let connections = state.withLockedValue { state in
            state.connectedMembers(of: topic).compactMap { state.links[$0.endpointID]?.connection }
        }
        return connections.contains { connection in
            connection.paths().contains { $0.isSelected && $0.isIp }
        }
    }

    // MARK: - Hub

    private func hubLoop(_ endpoint: Endpoint) async {
        var attempt = 0
        while !Task.isCancelled, !state.withLockedValue({ $0.isShutDown }) {
            if state.withLockedValue({ $0.hub.suspended }) {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            setHubStatus(.connecting(attempt: attempt))
            let started = ContinuousClock.now
            do {
                let hubID = try await resolveHub(endpoint)
                let connection = try await endpoint.connect(
                    addr: EndpointAddr(
                        id: try EndpointId.fromString(s: hubID),
                        relayUrl: configuration.relayURL,
                        addresses: []
                    ),
                    alpn: KeepTalkingIrohHubFrame.alpn
                )
                let stream = try await connection.openBi()
                let (frames, writer) = AsyncStream.makeStream(of: Data.self)
                let writerTask = Task {
                    let send = stream.send()
                    for await frame in frames {
                        do { try await send.writeAll(buf: frame) } catch { break }
                    }
                }
                let datagramTask = Task { await self.hubDatagramLoop(connection) }
                let latency = ContinuousClock.now - started
                let resubscribe = state.withLockedValue { state -> [Data] in
                    state.hub.connection = connection
                    state.hub.writer = writer
                    state.hub.connectLatency = latency
                    state.hub.connectedSince = Date()
                    state.hub.status = .ready
                    var frames: [Data] = []
                    for (topic, entry) in state.contexts {
                        frames.append(KeepTalkingIrohHubFrame.encode(.subscribe(topic: topic)))
                        frames.append(KeepTalkingIrohHubFrame.encode(.announce(topic: topic, blob: entry.blob)))
                    }
                    return frames
                }
                resubscribe.forEach { writer.yield($0) }
                attempt = 0
                log("hub connected in \(Self.ms(latency))")
                notifyAllContexts { $0.hubStateChanged() }

                let recv = stream.recv()
                while !Task.isCancelled {
                    let prefix = try await recv.readExact(size: 4)
                    let length = try KeepTalkingIrohHubFrame.frameLength(fromPrefix: prefix)
                    let body = try await recv.readExact(size: UInt32(length))
                    handleHubFrame(try KeepTalkingIrohHubFrame.decodeServer(body))
                }
                writerTask.cancel()
                datagramTask.cancel()
            } catch {
                if !state.withLockedValue({ $0.hub.suspended }) {
                    log("hub: \(error.localizedDescription)")
                }
            }
            let connection = state.withLockedValue { state -> Connection? in
                let connection = state.hub.connection
                state.hub.writer?.finish()
                state.hub.writer = nil
                state.hub.connection = nil
                state.hub.connectedSince = nil
                state.hub.status = .connecting(attempt: attempt + 1)
                for key in state.contexts.keys { state.contexts[key]?.joined = false }
                return connection
            }
            try? connection?.close(errorCode: 0, reason: Data("reconnect".utf8))
            attempt += 1
            notifyAllContexts { $0.hubStateChanged() }
            if !state.withLockedValue({ $0.hub.suspended }) {
                try? await Task.sleep(for: .seconds(min(1 << min(attempt - 1, 3), 8)))
            }
        }
    }

    /// The hub id from configuration or `<relay>/kt/hub`, cached. A looked-up
    /// QAD port is applied to the relay the first time.
    private func resolveHub(_ endpoint: Endpoint) async throws -> String {
        if let configured = configuration.hubEndpointID, !configured.isEmpty { return configured }
        if let cached = state.withLockedValue({ $0.hub.resolvedID }) { return cached }
        guard let base = URL(string: configuration.relayURL) else {
            throw HostError.hubInfo("bad relay URL \(configuration.relayURL)")
        }
        let url = base.appendingPathComponent("kt").appendingPathComponent("hub")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HostError.hubInfo("\(url) answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let info = try JSONDecoder().decode(HubInfo.self, from: data)
        guard info.alpn == nil || info.alpn.map { Data($0.utf8) } == KeepTalkingIrohHubFrame.alpn else {
            throw HostError.hubInfo("hub speaks \(info.alpn ?? "?")")
        }
        if configuration.relayQUICPort == nil, let port = info.qadPort {
            try? await endpoint.insertRelay(
                config: RelayConfig(url: configuration.relayURL, quicPort: port, authToken: nil)
            )
        }
        state.withLockedValue { $0.hub.resolvedID = info.hub }
        log("hub id \(info.hub.prefix(10)) from \(url.host() ?? "relay")")
        return info.hub
    }

    private struct HubInfo: Decodable {
        let hub: String
        let alpn: String?
        let qadPort: UInt16?

        enum CodingKeys: String, CodingKey {
            case hub, alpn
            case qadPort = "qad_port"
        }
    }

    private func hubDatagramLoop(_ connection: Connection) async {
        while !Task.isCancelled {
            guard let datagram = try? await connection.readDatagram() else { return }
            guard let split = KeepTalkingIrohHubFrame.splitDatagram(datagram) else { continue }
            let (topic, payload) = split
            let sink = state.withLockedValue { state -> KeepTalkingIrohContextTransport? in
                state.contexts[topic]?.hubDatagramsReceived += 1
                return state.contexts[topic]?.sink.value
            }
            sink?.deliverRealtime(payload, from: nil)
        }
    }

    private func setHubStatus(_ status: HubStatus) {
        state.withLockedValue { state in
            state.hub.status = status
            if case .connecting = status { state.hub.attempts += 1 }
        }
    }

    private func handleHubFrame(_ frame: KeepTalkingIrohHubFrame.Server) {
        switch frame {
            case .snapshot(let topic, let members):
                // A snapshot is the whole room: forget members that left while
                // the hub session was down, then learn the current ones.
                let present = Set(members.map(\.endpointID))
                let (sink, orphans) = state.withLockedValue { state in
                    state.contexts[topic]?.joined = true
                    let previous = state.contexts[topic]?.members ?? [:]
                    state.contexts[topic]?.members = previous.filter { present.contains($0.key) }
                    let gone = previous.keys.filter { !present.contains($0) }
                    return (state.contexts[topic]?.sink.value, state.dropUnneededLinks(among: gone))
                }
                for connection in orphans {
                    try? connection.close(errorCode: 0, reason: Data("left".utf8))
                }
                log("topic \(Self.hex(topic).prefix(10)) snapshot: \(members.count) other member(s)")
                for member in members where !member.blob.isEmpty {
                    learn(topic: topic, reportedID: member.endpointID, blob: member.blob)
                }
                sink?.hubJoined()
            case .joined(let topic, let endpointID):
                log("topic \(Self.hex(topic).prefix(10)) joined by \(Self.hex(endpointID).prefix(10))")
            case .presence(let topic, let endpointID, let blob):
                learn(topic: topic, reportedID: endpointID, blob: blob)
            case .left(let topic, let endpointID):
                let (sink, nodeID, orphans) = state.withLockedValue { state in
                    let nodeID = state.contexts[topic]?.members.removeValue(forKey: endpointID)
                    return (
                        state.contexts[topic]?.sink.value, nodeID,
                        state.dropUnneededLinks(among: [endpointID])
                    )
                }
                for connection in orphans {
                    try? connection.close(errorCode: 0, reason: Data("left".utf8))
                }
                log("topic \(Self.hex(topic).prefix(10)) left by \(Self.hex(endpointID).prefix(10))")
                if let nodeID { sink?.memberLeft(nodeID) }
            case .deliver(let topic, let body):
                guard let first = body.first, let kind = FrameKind(rawValue: first) else { return }
                let sink = state.withLockedValue { state -> KeepTalkingIrohContextTransport? in
                    state.contexts[topic]?.hubReceived += 1
                    return state.contexts[topic]?.sink.value
                }
                sink?.deliver(kind, payload: Data(body.dropFirst()), from: nil, route: .hub)
            case .error(let reason):
                log("hub error: \(reason)")
        }
    }

    /// Opens a member's sealed presence. Only a blob this context's secret
    /// opens, carrying the very id the hub reported, gives us a key to dial.
    private func learn(topic: Data, reportedID: Data, blob: Data) {
        let outcome = state.withLockedValue { state -> LearnOutcome in
            guard let entry = state.contexts[topic] else { return .ignored }
            guard
                let presence = KeepTalkingIrohPresenceSeal.open(
                    blob,
                    contextID: entry.topic.contextID,
                    secret: entry.secret
                )
            else { return .unreadable }
            guard presence.endpointID == reportedID else { return .mismatch }
            guard presence.endpointID != state.myEndpointID else { return .ignored }
            state.contexts[topic]?.members[presence.endpointID] = presence.nodeID
            let isConnected = state.links[presence.endpointID]?.connection != nil
            return .member(presence.nodeID, isConnected: isConnected, sink: entry.sink.value)
        }
        switch outcome {
            case .ignored:
                return
            case .unreadable:
                log("presence from \(Self.hex(reportedID).prefix(10)) does not open")
            case .mismatch:
                log("presence id != hub id for \(Self.hex(reportedID).prefix(10)); dropped")
            case .member(let nodeID, let isConnected, let sink):
                log("member \(nodeID.uuidString.prefix(8)) @ \(Self.hex(reportedID).prefix(10))")
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
                guard (33...Self.maxPeerFrameLength).contains(length) else {
                    throw HostError.frameTooLarge(length)
                }
                let body = try await recv.readExact(size: UInt32(length))
                handlePeerFrame(body, from: endpointID)
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
            guard let split = KeepTalkingIrohHubFrame.splitDatagram(datagram) else { continue }
            let (topic, payload) = split
            let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID?)? in
                state.links[endpointID]?.datagramsReceived += 1
                guard let entry = state.contexts[topic], let sink = entry.sink.value else { return nil }
                return (sink, entry.members[endpointID])
            }
            if let route {
                route.0.deliverRealtime(payload, from: route.1)
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

    /// `[kind][topic(32)][payload]`. Delivered for any attached topic: the
    /// payload only opens for holders of the topic's key.
    private func handlePeerFrame(_ body: Data, from endpointID: Data) {
        guard let kind = FrameKind(rawValue: body[body.startIndex]) else { return }
        let topic = Data(body[(body.startIndex + 1)..<(body.startIndex + 33)])
        let payload = Data(body.dropFirst(33))
        let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID?)? in
            state.links[endpointID]?.framesReceived += 1
            state.links[endpointID]?.bytesReceived += body.count + 4
            guard let entry = state.contexts[topic], let sink = entry.sink.value else {
                state.droppedFrames += 1
                return nil
            }
            state.contexts[topic]?.meshReceived += 1
            return (sink, entry.members[endpointID])
        }
        guard let route else { return }
        route.0.deliver(kind, payload: payload, from: route.1, route: .mesh)
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
        var hubStatus: String
        switch snapshot.hub.status {
            case .idle: hubStatus = "idle"
            case .connecting(let attempt): hubStatus = attempt == 0 ? "connecting" : "reconnecting #\(attempt)"
            case .ready: hubStatus = "ready"
        }
        if snapshot.hub.suspended { hubStatus = "suspended" }
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
            policy: Self.describe(snapshot.policy),
            hub: KeepTalkingIrohInstruments.Hub(
                status: hubStatus,
                hubID: configuration.hubEndpointID ?? snapshot.hub.resolvedID,
                attempts: snapshot.hub.attempts,
                connectLatencyMs: snapshot.hub.connectLatency.map(Self.milliseconds),
                connectedSince: snapshot.hub.connectedSince,
                selectedPath: hubConnection.map(Self.selectedPath),
                rttMs: hubConnection?.rtt()
            ),
            contexts: snapshot.contexts.map { topic, entry in
                KeepTalkingIrohInstruments.Context(
                    id: entry.topic.contextID,
                    topic: Self.hex(topic),
                    nodeID: entry.nodeID,
                    joined: entry.joined,
                    members: entry.members.map { endpointID, nodeID in
                        KeepTalkingIrohInstruments.Member(nodeID: nodeID, endpointID: Self.hex(endpointID))
                    },
                    meshPublished: entry.meshPublished,
                    hubPublished: entry.hubPublished,
                    meshReceived: entry.meshReceived,
                    hubReceived: entry.hubReceived,
                    hubDatagramsSent: entry.hubDatagramsSent,
                    hubDatagramsReceived: entry.hubDatagramsReceived
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

    /// `[u32 len][kind][topic(32)][payload]`, where `body` is `[kind][payload]`.
    static func peerFrame(topic: Data, body: Data) -> Data {
        var frame = Data(capacity: 36 + body.count)
        frame.appendBigEndian(UInt32(topic.count + body.count))
        frame.append(body[body.startIndex])
        frame.append(topic)
        frame.append(body.dropFirst())
        return frame
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ policy: DeliveryPolicy) -> String {
        switch policy {
            case .automatic(let threshold): return "automatic (hub at ≥\(threshold) members)"
            case .preferMesh: return "prefer mesh"
            case .preferHub: return "prefer hub"
        }
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
        var suspended = false
        var resolvedID: String?
        var attempts = 0
        var connectLatency: Duration?
        var connectedSince: Date?
    }

    fileprivate struct WeakSink {
        weak var value: KeepTalkingIrohContextTransport?
        init(_ value: KeepTalkingIrohContextTransport) { self.value = value }
    }

    fileprivate struct ContextEntry {
        let topic: KeepTalkingIrohTopic
        let nodeID: UUID
        let sink: WeakSink
        let secret: Data
        let blob: Data
        /// True once the hub's snapshot for this topic arrived.
        var joined = false
        /// Endpoint id → node id, from sealed presence only. These are the
        /// endpoints we dial and count as members for routing.
        var members: [Data: UUID] = [:]
        var meshPublished = 0
        var hubPublished = 0
        var meshReceived = 0
        var hubReceived = 0
        var hubDatagramsSent = 0
        var hubDatagramsReceived = 0

        init(topic: KeepTalkingIrohTopic, nodeID: UUID, sink: WeakSink, secret: Data, blob: Data) {
            self.topic = topic
            self.nodeID = nodeID
            self.sink = sink
            self.secret = secret
            self.blob = blob
        }
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
        var policy = DeliveryPolicy.standard
        var contexts: [Data: ContextEntry] = [:]
        var links: [Data: PeerLink] = [:]
        var droppedFrames = 0
        var events: [KeepTalkingIrohInstruments.Event] = []
        var nextEventID = 0

        var isHubUsable: Bool {
            hub.status == .ready && hub.writer != nil && !hub.suspended
        }

        /// Members of `topic` whose link is connected.
        func connectedMembers(of topic: Data) -> [(endpointID: Data, nodeID: UUID)] {
            guard let members = contexts[topic]?.members else { return [] }
            return members.compactMap { endpointID, nodeID in
                links[endpointID]?.connection == nil ? nil : (endpointID, nodeID)
            }
        }

        /// The policy's pick for a broadcast on `topic`, falling back to
        /// whichever route is up. Nil when neither is.
        func route(for topic: Data, connectedMembers: Int) -> Route? {
            let hub = isHubUsable
            let mesh = connectedMembers > 0
            let preferHub: Bool
            switch policy {
                case .automatic(let threshold):
                    preferHub = (contexts[topic]?.members.count ?? 0) >= threshold
                case .preferMesh:
                    preferHub = false
                case .preferHub:
                    preferHub = true
            }
            if preferHub { return hub ? .hub : (mesh ? .mesh : nil) }
            return mesh ? .mesh : (hub ? .hub : nil)
        }

        mutating func countMesh(topic: Data, endpointIDs: [Data], bytes: Int) {
            contexts[topic]?.meshPublished += 1
            for endpointID in endpointIDs {
                links[endpointID]?.framesSent += 1
                links[endpointID]?.bytesSent += bytes
            }
        }

        func isWanted(_ endpointID: Data) -> Bool {
            !isShutDown && contexts.values.contains { $0.members[endpointID] != nil }
        }

        /// Forgets links no attached context needs; returns what to close.
        /// `among` limits the sweep to those endpoints, so an accepted link
        /// whose sealed presence has not arrived yet survives.
        mutating func dropUnneededLinks(among candidates: [Data]? = nil) -> [Connection] {
            var orphans: [Connection] = []
            let scope = candidates.map(Set.init)
            for (endpointID, link) in links
            where !isWanted(endpointID) && scope?.contains(endpointID) != false {
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
