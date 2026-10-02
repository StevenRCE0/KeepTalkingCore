#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// The iroh endpoints shared by every context attached to them.
///
/// The host owns the connection machinery that `ContextTransport` used to
/// spread over the SFU client, libjuice and the HTTP/2 direct channels:
///
/// - **Hub** — one connection to the Rust `kt-sfu` hub
///   (`keeptalking/hub/1`). Each attached context subscribes to its *topic*
///   (`KeepTalkingIrohTopic`, derived from the context secret) and announces
///   a sealed blob carrying our node id and endpoint ids. The hub also fans
///   publishes and datagrams out to the topic, so a sender uploads once.
/// - **Mesh** — iroh connections (`keeptalking/peer/1`), one per remote
///   endpoint however many topics we share. Network links start on the relay
///   and go direct when hole punching works. The lower endpoint id dials.
/// - **Bluetooth** — optional, on a *separate*, Bluetooth-only endpoint
///   (vendored `iroh-ble-transport`). Its handshakes must run over Bluetooth
///   (the transport only verifies a pipe that carried one), so it can't share
///   the relay endpoint. It is process-wide (`KeepTalkingIrohBluetoothRadio`):
///   the crate cannot shut its radio down, so the endpoint is bound once and
///   lent to one host at a time. Its key is fixed for the process and
///   announced in sealed presence, so peers know it before the hub goes away.
///   A host uses it always, or only while the network fails it; the radio
///   stays on from its first use until the process exits.
/// - **Membership** — learned from sealed presence, through the hub or, with
///   no hub, from the hello on a Bluetooth link: nearby devices are found by
///   reading the full key their advert only half-carries, then dialled.
///   The hub roster is only discovery. A member the hub stops listing stays
///   while a link reaches it or it may come back over Bluetooth, and is
///   forgotten after `memberRetention` without either.
/// - **Delivery** — each publish goes through the hub or the mesh, chosen
///   per publish by `DeliveryPolicy`. On the mesh each member gets one link:
///   network while it has a path, Bluetooth otherwise. When a member's
///   traffic moves to its other link, its context resyncs with it, so
///   frames a dying link swallowed come back. Receivers take everything;
///   KeepTalking absorbs duplicates by row id.
///
/// Frames for an attached topic are delivered whoever sent them: content is
/// sealed with the topic's key, so only members can produce anything that
/// opens. Endpoint ids to dial still come only from sealed presence, never
/// from the hub. Keys are ephemeral; discovery is off (minimal preset, our
/// relay only); the hub id comes from configuration or `<relay>/kt/hub`.
@_spi(TransportLab)
public final class KeepTalkingIrohTransportHost: @unchecked Sendable {
    /// When the host uses the Bluetooth endpoint.
    public enum BluetoothMode: String, Sendable, Hashable, CaseIterable {
        case off
        case always
        /// Only while the network gate is open: the hub is unreachable (or
        /// suspended), or a member that announced a Bluetooth id has no
        /// working network link — so an online device still meets a
        /// neighbour that went offline.
        case whenNetworkFails
    }

    public struct Configuration: Sendable, Hashable {
        /// Relay URL, e.g. `https://signal.rcex.live/`.
        public var relayURL: String
        /// Hub endpoint id (hex). Nil looks it up at `<relay>/kt/hub`.
        public var hubEndpointID: String?
        /// QUIC address-discovery port of the relay. Nil takes it from
        /// `/kt/hub` (and disables QAD if the hub id is configured by hand).
        public var relayQUICPort: UInt16?
        /// The Bluetooth LE endpoint (`iroh-ble-transport`, vendored and
        /// patched in the iroh-ffi fork; AGPL-3.0). One per device: a controller
        /// never sees its own adverts.
        public var bluetooth: BluetoothMode

        public init(
            relayURL: String,
            hubEndpointID: String? = nil,
            relayQUICPort: UInt16? = nil,
            bluetooth: BluetoothMode = .off
        ) {
            self.relayURL = relayURL
            self.hubEndpointID = hubEndpointID
            self.relayQUICPort = relayQUICPort
            self.bluetooth = bluetooth
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
        /// Sealed presence for every attached context, sent first on a
        /// Bluetooth link (topic field zero). A blob only opens for members,
        /// so it's how two devices that met offline learn which contexts
        /// they share — strangers learn nothing.
        case hello = 0x05
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
    /// Network gate open this long before the host claims Bluetooth…
    private static let bluetoothStartAfter: Duration = .seconds(3)
    /// …and closed this long before it lets go again.
    private static let bluetoothStopAfter: Duration = .seconds(30)
    /// How long a member the hub stopped listing is kept without any link
    /// reaching it, so Bluetooth can still find it.
    static let memberRetention: Duration = .seconds(30 * 60)
    /// Bytes of the key a Bluetooth advert carries.
    private static let bluetoothPrefixLength = 12
    /// A nearby device that served no identity is asked again after this.
    private static let identityRetryAfter: Duration = .seconds(30)

    public let configuration: Configuration
    private let state = NIOLockedValueBox(State())

    public init(configuration: Configuration, policy: DeliveryPolicy = .standard) {
        self.configuration = configuration
        state.withLockedValue { state in
            state.policy = policy
            if configuration.bluetooth != .off {
                state.bluetooth.myID = KeepTalkingIrohBluetoothRadio.shared.endpointID
            }
        }
    }

    // MARK: - Lifecycle

    /// Binds the network endpoint and starts the accept, hub and (if
    /// configured) Bluetooth loops. Idempotent.
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
        let (endpoints, tasks, connections, writers) = state.withLockedValue { state in
            state.isShutDown = true
            let tasks = state.tasks + state.links.values.flatMap(\.tasks)
            let connections =
                state.links.values.compactMap(\.connection) + [state.hub.connection].compactMap { $0 }
            let writers = state.links.values.compactMap(\.writer) + [state.hub.writer].compactMap { $0 }
            let endpoints = [state.endpoint].compactMap { $0 }
            state.tasks = []
            state.bluetooth.endpoint = nil
            state.links = [:]
            state.hub = HubState()
            return (endpoints, tasks, connections, writers)
        }
        tasks.forEach { $0.cancel() }
        writers.forEach { $0.finish() }
        for connection in connections {
            try? connection.close(errorCode: 0, reason: Data("shutdown".utf8))
        }
        for endpoint in endpoints { try? await endpoint.close() }
        KeepTalkingIrohBluetoothRadio.shared.release(from: self)
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
        var tasks = [
            Task { await self.acceptLoop(endpoint, kind: .network) },
            Task { await self.hubLoop(endpoint) },
            Task { await self.maintenanceLoop() },
        ]
        if configuration.bluetooth == .always {
            tasks.append(Task { await self.startBluetooth() })
        }
        state.withLockedValue { state in
            state.endpoint = endpoint
            state.myEndpointID = myID
            state.tasks += tasks
        }
        log("endpoint \(Self.hex(myID).prefix(10)) bound \(endpoint.boundSockets().joined(separator: ", "))")
        return endpoint
    }

    // MARK: - Maintenance

    /// Once a second: forgets members nothing has reached for
    /// `memberRetention`, and in `whenNetworkFails` mode claims Bluetooth
    /// once the network gate has been open a moment and lets go after it has
    /// been closed a while.
    private func maintenanceLoop() async {
        var openSince: ContinuousClock.Instant?
        var closedSince: ContinuousClock.Instant?
        while !Task.isCancelled, !state.withLockedValue({ $0.isShutDown }) {
            let now = ContinuousClock.now
            let (left, orphans) = state.withLockedValue {
                $0.sweepMembers(at: now, retention: Self.memberRetention)
            }
            for connection in orphans {
                try? connection.close(errorCode: 0, reason: Data("left".utf8))
            }
            for (sink, nodeID) in left {
                log("member \(nodeID.uuidString.prefix(8)) unreachable for \(Self.memberRetention): forgotten")
                sink?.memberLeft(nodeID)
            }

            if configuration.bluetooth == .whenNetworkFails {
                let (open, running) = state.withLockedValue { ($0.needsBluetooth, $0.bluetooth.endpoint != nil) }
                if open {
                    closedSince = nil
                    openSince = openSince ?? now
                } else {
                    openSince = nil
                    closedSince = closedSince ?? now
                }
                if !running, let since = openSince, now - since >= Self.bluetoothStartAfter {
                    log("network gate open: claiming bluetooth")
                    await startBluetooth()
                } else if running, let since = closedSince, now - since >= Self.bluetoothStopAfter {
                    log("network gate closed: releasing bluetooth")
                    await stopBluetooth()
                }
            }
            discoverNearby(at: now)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Bluetooth endpoint

    private func startBluetooth() async {
        let proceed = state.withLockedValue { state -> Bool in
            guard !state.isShutDown, state.bluetooth.endpoint == nil, !state.bluetooth.starting else {
                return false
            }
            state.bluetooth.starting = true
            return true
        }
        guard proceed else { return }
        do {
            let endpoint = try await KeepTalkingIrohBluetoothRadio.shared.claim(for: self)
            let targets = state.withLockedValue { state -> [Data]? in
                state.bluetooth.starting = false
                // Shut down while claiming: hand the radio straight back.
                guard !state.isShutDown else { return nil }
                state.bluetooth.endpoint = endpoint
                state.bluetooth.failure = nil
                state.bluetooth.starts += 1
                return state.contexts.values.flatMap { Array($0.bluetoothMembers.keys) }
            }
            guard let targets else {
                KeepTalkingIrohBluetoothRadio.shared.release(from: self)
                return
            }
            log("bluetooth endpoint \(Self.hex(endpoint.id().toBytes()).prefix(10)) claimed")
            for target in Set(targets) { ensureLink(to: target, kind: .bluetooth) }
        } catch {
            let changed = state.withLockedValue { state -> Bool in
                state.bluetooth.starting = false
                defer { state.bluetooth.failure = error.localizedDescription }
                return state.bluetooth.failure != error.localizedDescription
            }
            if changed { log("bluetooth unavailable: \(error.localizedDescription)") }
        }
    }

    /// Drops our Bluetooth links and lends the endpoint back. The radio
    /// itself keeps running (see `KeepTalkingIrohBluetoothRadio`).
    private func stopBluetooth() async {
        let closing = mutateLinks(touching: nil) { state -> [PeerLink] in
            state.bluetooth.endpoint = nil
            let closing = state.links.filter { $0.value.kind == .bluetooth }
            for key in closing.keys { state.links[key] = nil }
            return Array(closing.values)
        }
        for link in closing {
            link.writer?.finish()
            link.tasks.forEach { $0.cancel() }
            try? link.connection?.close(errorCode: 0, reason: Data("bluetooth off".utf8))
        }
        KeepTalkingIrohBluetoothRadio.shared.release(from: self)
        log("bluetooth endpoint released")
    }

    // MARK: - Offline discovery

    /// Finds nearby KeepTalking devices without the hub. Adverts carry a
    /// 12-byte key prefix, which can't be dialled, so the full id is read
    /// from the device (`KeepTalkingIrohBluetoothIdentityReader`) — only for
    /// devices we're due to dial, i.e. whose prefix sorts below ours (the
    /// higher Bluetooth id dials). A dialled device is wanted until its
    /// hello shows we share no context. One read at a time.
    private func discoverNearby(at now: ContinuousClock.Instant) {
        guard
            let bluetooth = state.withLockedValue({ state -> (endpoint: Endpoint, myID: Data)? in
                guard let endpoint = state.bluetooth.endpoint, let myID = state.bluetooth.myID else { return nil }
                return (endpoint, myID)
            })
        else { return }
        let (endpoint, myID) = bluetooth
        let devices: [(deviceID: String, prefix: Data)] = (endpoint.bleStatus()?.peers ?? []).compactMap { peer in
            peer.prefix.flatMap(Self.bytes(fromHex:)).map { (peer.deviceId, $0) }
        }
        let myPrefix = myID.prefix(Self.bluetoothPrefixLength)
        let (probe, redial) = state.withLockedValue { state -> ((String, Data)?, [Data]) in
            // Devices that stopped advertising are no longer worth a dial.
            let present = Set(devices.map(\.prefix))
            for id in state.bluetooth.nearby.keys where !present.contains(id.prefix(Self.bluetoothPrefixLength)) {
                state.bluetooth.nearby[id] = nil
            }
            let redial = state.bluetooth.nearby.keys.filter {
                !state.bluetooth.strangers.contains($0) && state.links[$0] == nil
            }
            guard !state.bluetooth.probing else { return (nil, redial) }
            let known = Set(
                (state.contexts.values.flatMap(\.bluetoothMembers.keys) + Array(state.bluetooth.nearby.keys))
                    .map { Data($0.prefix(Self.bluetoothPrefixLength)) }
            )
            let probe = devices.first { device in
                device.prefix.lexicographicallyPrecedes(myPrefix) && !known.contains(device.prefix)
                    && (state.bluetooth.probeRetryAt[device.deviceID].map { $0 <= now } ?? true)
            }
            if probe != nil { state.bluetooth.probing = true }
            return (probe, redial)
        }
        for id in redial { ensureLink(to: id, kind: .bluetooth) }
        guard let probe else { return }
        let (deviceID, prefix) = probe
        Task { [self] in
            let id = await KeepTalkingIrohBluetoothRadio.shared.readIdentity(deviceID: deviceID)
            // The id must be the one the device advertises half of.
            let verified = id.flatMap { $0.prefix(Self.bluetoothPrefixLength) == prefix ? $0 : nil }
            state.withLockedValue { state in
                state.bluetooth.probing = false
                if let verified {
                    state.bluetooth.nearby[verified] = deviceID
                    state.bluetooth.probeRetryAt[deviceID] = nil
                } else {
                    state.bluetooth.probeRetryAt[deviceID] = ContinuousClock.now + Self.identityRetryAfter
                }
            }
            if let verified {
                log("nearby \(Self.hex(verified).prefix(10)) identified over Bluetooth")
                ensureLink(to: verified, kind: .bluetooth)
            } else {
                log("nearby device \(deviceID.prefix(8)) did not serve an identity")
            }
        }
    }

    /// Sends our hello: sealed presence for every attached context, freshly
    /// sealed so it can't be linked to what the hub stored.
    private func sendHello(to endpointIDs: [Data]) {
        guard !endpointIDs.isEmpty else { return }
        let snapshot = state.withLockedValue {
            state -> (Data, Data?, [ContextEntry], [AsyncStream<Data>.Continuation])? in
            guard let myID = state.myEndpointID else { return nil }
            return (
                myID, state.bluetooth.myID, Array(state.contexts.values),
                endpointIDs.compactMap { state.links[$0]?.writer }
            )
        }
        guard let snapshot, !snapshot.3.isEmpty else { return }
        let (myID, bluetoothID, entries, writers) = snapshot
        var payload = Data()
        for entry in entries {
            guard
                let blob = try? KeepTalkingIrohPresenceSeal.seal(
                    nodeID: entry.nodeID,
                    endpointID: myID,
                    bluetoothEndpointID: bluetoothID,
                    contextID: entry.topic.contextID,
                    secret: entry.secret
                )
            else { continue }
            payload.appendBigEndian(UInt16(blob.count))
            payload.append(blob)
        }
        var body = Data([FrameKind.hello.rawValue])
        body.append(payload)
        let frame = Self.peerFrame(topic: Data(count: 32), body: body)
        writers.forEach { $0.yield(frame) }
    }

    /// A peer's hello: every blob one of our contexts opens — carrying the
    /// very id this link authenticated — makes the peer a member there. A
    /// hello that opens nowhere marks a stranger, whose link we drop.
    private func handleHello(_ payload: Data, from endpointID: Data) {
        var blobs: [Data] = []
        var index = payload.startIndex
        while payload.endIndex - index >= 2 {
            let length = Int(payload[index]) << 8 | Int(payload[index + 1])
            index += 2
            guard payload.endIndex - index >= length else { break }
            blobs.append(Data(payload[index..<(index + length)]))
            index += length
        }
        let now = ContinuousClock.now
        let (learned, orphans) = mutateLinks(touching: [endpointID]) { state -> ([(UUID, Data)], [Connection]) in
            var learned: [(UUID, Data)] = []
            for (topic, entry) in state.contexts {
                for blob in blobs {
                    guard
                        let presence = KeepTalkingIrohPresenceSeal.open(
                            blob,
                            contextID: entry.topic.contextID,
                            secret: entry.secret
                        ),
                        presence.bluetoothEndpointID == endpointID || presence.endpointID == endpointID,
                        presence.endpointID != state.myEndpointID
                    else { continue }
                    let main = presence.endpointID
                    if entry.members[main] == nil { state.contexts[topic]?.offHub[main] = now }
                    state.contexts[topic]?.members[main] = presence.nodeID
                    if let stale = entry.bluetoothOf[main], stale != presence.bluetoothEndpointID {
                        state.contexts[topic]?.bluetoothMembers[stale] = nil
                    }
                    state.contexts[topic]?.bluetoothOf[main] = presence.bluetoothEndpointID
                    if let bluetooth = presence.bluetoothEndpointID {
                        state.contexts[topic]?.bluetoothMembers[bluetooth] = presence.nodeID
                    }
                    learned.append((presence.nodeID, main))
                    break
                }
            }
            guard learned.isEmpty else {
                state.bluetooth.strangers.remove(endpointID)
                return (learned, [])
            }
            state.bluetooth.strangers.insert(endpointID)
            return ([], state.dropUnneededLinks(among: [endpointID]))
        }
        if learned.isEmpty {
            log("hello from \(Self.hex(endpointID).prefix(10)): no shared context")
            for connection in orphans {
                try? connection.close(errorCode: 0, reason: Data("no shared context".utf8))
            }
            return
        }
        for (nodeID, main) in learned {
            log("member \(nodeID.uuidString.prefix(8)) met over Bluetooth")
            ensureLink(to: main, kind: .network)
        }
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
        let (myID, bluetoothID) = try state.withLockedValue { state -> (Data, Data?) in
            guard !state.isShutDown, let myID = state.myEndpointID else { throw HostError.stopped }
            return (myID, state.bluetooth.myID)
        }
        let blob = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: nodeID,
            endpointID: myID,
            bluetoothEndpointID: bluetoothID,
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
        // Nearby devices that shared nothing with us might share this one.
        let bluetoothLinks = state.withLockedValue { state -> [Data] in
            state.bluetooth.strangers = []
            return state.links.filter { $0.value.kind == .bluetooth && $0.value.connection != nil }.map(\.key)
        }
        sendHello(to: bluetoothLinks)
    }

    func detach(topic: Data) {
        let (writer, orphans) = state.withLockedValue { state -> (AsyncStream<Data>.Continuation?, [Connection]) in
            guard let removed = state.contexts.removeValue(forKey: topic) else { return (nil, []) }
            let ids = Array(removed.members.keys) + Array(removed.bluetoothMembers.keys)
            return (state.hub.writer, state.dropUnneededLinks(among: ids))
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

    /// True when some connected member of `topic` is reached without the
    /// relay (a direct IP path or Bluetooth).
    func hasDirectMember(in topic: Data) -> Bool {
        let connections = state.withLockedValue { state in
            state.connectedMembers(of: topic).compactMap { state.links[$0.endpointID]?.connection }
        }
        return connections.contains { connection in
            connection.paths().contains { $0.isSelected && !$0.isRelay }
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
        guard info.alpn == nil || info.alpn.map({ Data($0.utf8) }) == KeepTalkingIrohHubFrame.alpn else {
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
                // A snapshot is the whole room: members it lacks left the hub
                // while our session was down (`hubDropped` decides whether
                // they leave us too), then learn the current ones.
                let present = Set(members.map(\.endpointID))
                let (sink, left, orphans) = state.withLockedValue { state in
                    state.contexts[topic]?.joined = true
                    let absent =
                        (state.contexts[topic]?.members.keys).map { Array($0) }?
                        .filter { !present.contains($0) } ?? []
                    var left: [UUID] = []
                    var unlink: [Data] = []
                    for main in absent {
                        let nodeID = state.contexts[topic]?.members[main]
                        guard let ids = state.hubDropped(main, in: topic, at: .now) else { continue }
                        unlink += ids
                        if let nodeID { left.append(nodeID) }
                    }
                    return (state.contexts[topic]?.sink.value, left, state.dropUnneededLinks(among: unlink))
                }
                for connection in orphans {
                    try? connection.close(errorCode: 0, reason: Data("left".utf8))
                }
                left.forEach { sink?.memberLeft($0) }
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
                let (sink, nodeID, kept, orphans) = state.withLockedValue { state in
                    let nodeID = state.contexts[topic]?.members[endpointID]
                    guard let ids = state.hubDropped(endpointID, in: topic, at: .now) else {
                        return (state.contexts[topic]?.sink.value, nodeID, nodeID != nil, [Connection]())
                    }
                    return (state.contexts[topic]?.sink.value, nodeID, false, state.dropUnneededLinks(among: ids))
                }
                for connection in orphans {
                    try? connection.close(errorCode: 0, reason: Data("left".utf8))
                }
                if kept {
                    log(
                        "topic \(Self.hex(topic).prefix(10)): \(Self.hex(endpointID).prefix(10)) left the hub; kept (reachable or Bluetooth)"
                    )
                } else {
                    log("topic \(Self.hex(topic).prefix(10)) left by \(Self.hex(endpointID).prefix(10))")
                    if let nodeID { sink?.memberLeft(nodeID) }
                }
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
    /// opens, carrying the very id the hub reported, gives us keys to dial.
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
            state.contexts[topic]?.offHub[presence.endpointID] = nil
            if let stale = state.contexts[topic]?.bluetoothOf[presence.endpointID],
                stale != presence.bluetoothEndpointID
            {
                state.contexts[topic]?.bluetoothMembers[stale] = nil
            }
            state.contexts[topic]?.bluetoothOf[presence.endpointID] = presence.bluetoothEndpointID
            if let bluetooth = presence.bluetoothEndpointID {
                state.contexts[topic]?.bluetoothMembers[bluetooth] = presence.nodeID
            }
            let isConnected = state.connectedMembers(of: topic).contains { $0.nodeID == presence.nodeID }
            let bluetoothTarget = state.bluetooth.endpoint == nil ? nil : presence.bluetoothEndpointID
            return .member(
                presence.nodeID,
                isConnected: isConnected,
                sink: entry.sink.value,
                bluetooth: bluetoothTarget
            )
        }
        switch outcome {
            case .ignored:
                return
            case .unreadable:
                log("presence from \(Self.hex(reportedID).prefix(10)) does not open")
            case .mismatch:
                log("presence id != hub id for \(Self.hex(reportedID).prefix(10)); dropped")
            case .member(let nodeID, let isConnected, let sink, let bluetooth):
                log("member \(nodeID.uuidString.prefix(8)) @ \(Self.hex(reportedID).prefix(10))")
                if isConnected { sink?.peerLinkUp(nodeID) }
                ensureLink(to: reportedID, kind: .network)
                if let bluetooth { ensureLink(to: bluetooth, kind: .bluetooth) }
        }
    }

    // MARK: - Peer links

    /// Dials `endpointID` on the matching endpoint when it's our turn; the
    /// other side waits. Network links: the lower id dials. Bluetooth links:
    /// the *higher* id dials, matching `iroh-ble-transport`, which keeps the
    /// BLE connection whose central (dialer) holds the higher id and makes
    /// the lower side hold back so the higher one lands first.
    private func ensureLink(to endpointID: Data, kind: PeerLink.Kind) {
        let shouldDial = state.withLockedValue { state -> Bool in
            let myID = kind == .network ? state.myEndpointID : state.bluetooth.myID
            let endpoint = kind == .network ? state.endpoint : state.bluetooth.endpoint
            guard !state.isShutDown, endpoint != nil, let myID, state.links[endpointID] == nil else {
                return false
            }
            let ourTurn =
                kind == .network
                ? myID.lexicographicallyPrecedes(endpointID)
                : endpointID.lexicographicallyPrecedes(myID)
            guard ourTurn else { return false }
            state.links[endpointID] = PeerLink(side: .dialed, kind: kind)
            return true
        }
        guard shouldDial else { return }
        let task = Task { await self.dialLoop(endpointID, kind: kind) }
        state.withLockedValue { $0.links[endpointID]?.tasks.append(task) }
    }

    private func dialLoop(_ endpointID: Data, kind: PeerLink.Kind) async {
        var attempt = 0
        while !Task.isCancelled {
            let endpoint = state.withLockedValue { state -> Endpoint? in
                guard state.isWanted(endpointID) else { return nil }
                state.links[endpointID]?.dialAttempts += 1
                return kind == .network ? state.endpoint : state.bluetooth.endpoint
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
                        relayUrl: kind == .network ? configuration.relayURL : nil,
                        addresses: []
                    ),
                    alpn: Self.peerALPN
                )
                install(
                    connection,
                    endpointID: endpointID,
                    side: .dialed,
                    kind: kind,
                    latency: ContinuousClock.now - started
                )
                return
            } catch {
                attempt += 1
                log(
                    "dial \(kind.rawValue) \(Self.hex(endpointID).prefix(10)) failed (#\(attempt)): \(error.localizedDescription)"
                )
                try? await Task.sleep(for: .seconds(min(1 << min(attempt, 4), 16)))
            }
        }
    }

    private func acceptLoop(_ endpoint: Endpoint, kind: PeerLink.Kind) async {
        while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
            handleIncoming(incoming, kind: kind)
        }
    }

    /// An incoming connection on the process-wide Bluetooth endpoint while
    /// this host holds it.
    func acceptBluetooth(_ incoming: Incoming) {
        handleIncoming(incoming, kind: .bluetooth)
    }

    private func handleIncoming(_ incoming: Incoming, kind: PeerLink.Kind) {
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
                    kind: kind,
                    latency: ContinuousClock.now - started
                )
            } catch {
                log("accept \(kind.rawValue) failed: \(error.localizedDescription)")
            }
        }
    }

    private func install(
        _ connection: Connection,
        endpointID: Data,
        side: PeerLink.Side,
        kind: PeerLink.Kind,
        latency: Duration
    ) {
        let (frames, writer) = AsyncStream.makeStream(of: Data.self)
        let watcher = LinkPathWatcher(host: self, endpointID: endpointID, stableID: connection.stableId())
        let watch = connection.watchPathEvents(callback: watcher)
        let replaced = mutateLinks(touching: [endpointID]) { state -> PeerLink? in
            let previous = state.links[endpointID]
            var link = PeerLink(side: side, kind: kind)
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
            "\(kind.rawValue) peer \(Self.hex(endpointID).prefix(10)) \(side.rawValue) in \(Self.ms(latency)) via \(Self.selectedPath(connection))"
        )
        if kind == .bluetooth { sendHello(to: [endpointID]) }
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
                return (sink, entry.nodeID(for: endpointID))
            }
            if let route {
                route.0.deliverRealtime(payload, from: route.1)
            }
        }
    }

    private func watchClosed(_ connection: Connection, endpointID: Data) async {
        let reason = await connection.closed()
        let stableID = connection.stableId()
        let (wasCurrent, redial) = mutateLinks(touching: [endpointID]) { state -> (Bool, PeerLink.Kind?) in
            guard let link = state.links[endpointID], link.connection?.stableId() == stableID
            else { return (false, nil) }
            link.writer?.finish()
            state.links[endpointID] = nil
            return (true, link.side == .dialed && state.isWanted(endpointID) ? link.kind : nil)
        }
        guard wasCurrent else { return }
        log("peer \(Self.hex(endpointID).prefix(10)) closed: \(reason)")
        if let redial { ensureLink(to: endpointID, kind: redial) }
    }

    /// `[kind][topic(32)][payload]`. Delivered for any attached topic: the
    /// payload only opens for holders of the topic's key.
    private func handlePeerFrame(_ body: Data, from endpointID: Data) {
        guard let kind = FrameKind(rawValue: body[body.startIndex]) else { return }
        let topic = Data(body[(body.startIndex + 1)..<(body.startIndex + 33)])
        let payload = Data(body.dropFirst(33))
        if kind == .hello {
            handleHello(payload, from: endpointID)
            return
        }
        let route = state.withLockedValue { state -> (KeepTalkingIrohContextTransport, UUID?)? in
            state.links[endpointID]?.framesReceived += 1
            state.links[endpointID]?.bytesReceived += body.count + 4
            guard let entry = state.contexts[topic], let sink = entry.sink.value else {
                state.droppedFrames += 1
                return nil
            }
            state.contexts[topic]?.meshReceived += 1
            return (sink, entry.nodeID(for: endpointID))
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
        guard let connection else { return }
        // A connection whose every path closed lingers until QUIC times it
        // out (up to ~30 s) while swallowing what we write: stop routing
        // through it as soon as that happens.
        let pathless = connection.paths().isEmpty
        let changed = mutateLinks(touching: [endpointID]) { state -> Bool in
            guard state.links[endpointID]?.connection?.stableId() == stableID,
                state.links[endpointID]?.pathless != pathless
            else { return false }
            state.links[endpointID]?.pathless = pathless
            return true
        }
        if changed {
            log("peer \(Self.hex(endpointID).prefix(10)) \(pathless ? "lost every path" : "has a path again")")
        }
        guard case .selected = event else { return }
        let isDirect = connection.paths().contains { $0.isSelected && !$0.isRelay }
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

    /// Applies a link change and tells each context how the carrying link of
    /// the members it touched changed: a link appeared (`peerLinkUp`), none
    /// is left (`peerLinkDown`), or traffic moved to the other live link
    /// (`peerRerouted` — the context resyncs over it, since frames written
    /// into a dying link are gone). `touching` names the endpoints whose
    /// members to compare; nil compares every member.
    private func mutateLinks<T>(touching endpointIDs: Set<Data>?, _ change: (inout State) -> T) -> T {
        let (result, changes) = state.withLockedValue { state -> (T, [CarrierChange]) in
            let before = state.carriers(touching: endpointIDs)
            let result = change(&state)
            let after = state.carriers(touching: endpointIDs)
            var changes: [CarrierChange] = []
            for key in Set(before.keys).union(after.keys) {
                let old = before[key]?.carrier
                let new = after[key]?.carrier
                guard old != new, let nodeID = (after[key] ?? before[key])?.nodeID else { continue }
                let sink = state.contexts[key.topic]?.sink.value
                switch (old, new) {
                    case (nil, _?): changes.append(.up(sink, nodeID))
                    case (_?, nil): changes.append(.down(sink, nodeID))
                    default: changes.append(.rerouted(sink, nodeID))
                }
            }
            return (result, changes)
        }
        for change in changes {
            switch change {
                case .up(let sink, let nodeID): sink?.peerLinkUp(nodeID)
                case .down(let sink, let nodeID): sink?.peerLinkDown(nodeID)
                case .rerouted(let sink, let nodeID): sink?.peerRerouted(nodeID)
            }
        }
        return result
    }

    private enum CarrierChange {
        case up(KeepTalkingIrohContextTransport?, UUID)
        case down(KeepTalkingIrohContextTransport?, UUID)
        case rerouted(KeepTalkingIrohContextTransport?, UUID)
    }

    private func notifyMembership(
        of endpointID: Data,
        _ body: (KeepTalkingIrohContextTransport, UUID) -> Void
    ) {
        let targets = state.withLockedValue { state in
            state.contexts.values.compactMap { entry -> (KeepTalkingIrohContextTransport, UUID)? in
                guard let nodeID = entry.nodeID(for: endpointID), let sink = entry.sink.value else { return nil }
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

    /// A point-in-time reading of the endpoints, the hub session, every
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
            for (endpointID, nodeID) in entry.bluetoothMembers { result[endpointID, default: []].insert(nodeID) }
        }
        let peers = snapshot.links.map { endpointID, link -> KeepTalkingIrohInstruments.Peer in
            let connection = link.connection
            let paths = connection?.paths() ?? []
            let stats = connection?.stats()
            return KeepTalkingIrohInstruments.Peer(
                id: Self.hex(endpointID),
                link: link.kind.rawValue,
                nodeIDs: nodeByEndpoint[endpointID].map { Array($0) } ?? [],
                side: link.side.rawValue,
                status: connection == nil
                    ? "dialing (#\(link.dialAttempts))"
                    : (connection?.closeReason().map { "closed: \($0)" } ?? "connected"),
                connectLatencyMs: link.connectLatency.map(Self.milliseconds),
                timeToDirectMs: link.timeToDirect.map(Self.milliseconds),
                isDirect: paths.contains { $0.isSelected && !$0.isRelay },
                isBluetooth: paths.contains { $0.isSelected && !$0.isRelay && !$0.isIp },
                selectedPath: connection.map(Self.selectedPath),
                rttMs: connection?.rtt(),
                paths: paths.map { path in
                    KeepTalkingIrohInstruments.Path(
                        remoteAddress: path.remoteAddr,
                        kind: Self.pathKind(path),
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
                        KeepTalkingIrohInstruments.Member(
                            nodeID: nodeID,
                            endpointID: Self.hex(endpointID),
                            bluetoothEndpointID: entry.bluetoothOf[endpointID].map { Self.hex($0) },
                            isListedByHub: entry.offHub[endpointID] == nil
                        )
                    },
                    meshPublished: entry.meshPublished,
                    hubPublished: entry.hubPublished,
                    meshReceived: entry.meshReceived,
                    hubReceived: entry.hubReceived,
                    hubDatagramsSent: entry.hubDatagramsSent,
                    hubDatagramsReceived: entry.hubDatagramsReceived
                )
            },
            peers: peers.sorted { ($0.link, $0.id) < ($1.link, $1.id) },
            bluetooth: configuration.bluetooth == .off ? nil : bluetoothInstruments(snapshot.bluetooth),
            droppedFrames: snapshot.droppedFrames,
            events: snapshot.events
        )
    }

    private func bluetoothInstruments(_ bluetooth: BluetoothState) -> KeepTalkingIrohInstruments.Bluetooth {
        let status = bluetooth.endpoint?.bleStatus()
        let state: String
        if bluetooth.endpoint != nil {
            state = "running"
        } else if bluetooth.starting {
            state = "starting"
        } else if let failure = bluetooth.failure {
            state = "failed: \(failure)"
        } else {
            state = configuration.bluetooth == .whenNetworkFails ? "standby (network fine)" : "stopped"
        }
        return KeepTalkingIrohInstruments.Bluetooth(
            mode: configuration.bluetooth.rawValue,
            state: state,
            endpointID: bluetooth.myID.map(Self.hex),
            starts: bluetooth.starts,
            powered: status?.powered ?? false,
            txBytes: status?.txBytes ?? 0,
            rxBytes: status?.rxBytes ?? 0,
            retransmits: status?.retransmits ?? 0,
            devices: (status?.peers ?? []).map { peer in
                KeepTalkingIrohInstruments.BluetoothDevice(
                    id: peer.deviceId,
                    phase: peer.phase,
                    connectPath: peer.connectPath,
                    endpointID: peer.verifiedEndpoint,
                    prefix: peer.prefix,
                    failures: Int(peer.consecutiveFailures)
                )
            },
            nearby: bluetooth.nearby.keys.map(Self.hex).sorted(),
            strangers: bluetooth.strangers.count
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

    static func bytes(fromHex hex: String) -> Data? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
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
        switch pathKind(path) {
            case "relay": return "relay"
            case "bluetooth": return "bluetooth"
            default: return "direct \(path.remoteAddr)"
        }
    }

    /// `relay`, `ip`, or `bluetooth` (the only custom transport we add).
    private static func pathKind(_ path: PathSnapshot) -> String {
        path.isRelay ? "relay" : (path.isIp ? "ip" : "bluetooth")
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

    fileprivate struct BluetoothState {
        /// The process-wide Bluetooth endpoint id, announced in presence.
        var myID: Data?
        /// The radio's endpoint while this host holds it.
        var endpoint: Endpoint?
        var starting = false
        var failure: String?
        var starts = 0
        /// Bluetooth ids read from nearby devices → their device id.
        var nearby: [Data: String] = [:]
        /// Nearby ids whose hello opened none of our contexts; forgotten
        /// when we attach another.
        var strangers: Set<Data> = []
        var probing = false
        var probeRetryAt: [String: ContinuousClock.Instant] = [:]
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
        /// Network endpoint id → node id, from sealed presence only.
        var members: [Data: UUID] = [:]
        /// Network endpoint id → that member's Bluetooth endpoint id.
        var bluetoothOf: [Data: Data] = [:]
        /// Bluetooth endpoint id → node id.
        var bluetoothMembers: [Data: UUID] = [:]
        /// Network endpoint id → since when a member the hub stopped listing
        /// has gone unreached (restarted whenever a link reaches it).
        var offHub: [Data: ContinuousClock.Instant] = [:]
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

        func nodeID(for endpointID: Data) -> UUID? {
            members[endpointID] ?? bluetoothMembers[endpointID]
        }

        /// The network id of the member `endpointID` (network or Bluetooth)
        /// belongs to.
        func mainID(for endpointID: Data) -> Data? {
            if members[endpointID] != nil { return endpointID }
            return bluetoothOf.first { $0.value == endpointID }?.key
        }

        /// Drops a member; returns its Bluetooth id if it had one.
        mutating func forget(main endpointID: Data) -> Data? {
            members[endpointID] = nil
            offHub[endpointID] = nil
            guard let bluetooth = bluetoothOf.removeValue(forKey: endpointID) else { return nil }
            bluetoothMembers[bluetooth] = nil
            return bluetooth
        }
    }

    fileprivate struct PeerLink {
        enum Side: String { case dialed, accepted }
        enum Kind: String { case network, bluetooth }

        let side: Side
        let kind: Kind
        var connection: Connection?
        /// Every path of `connection` closed: it carries nothing until one
        /// reopens or QUIC gives up on it.
        var pathless = false
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

        init(side: Side, kind: Kind) {
            self.side = side
            self.kind = kind
        }
    }

    fileprivate enum LearnOutcome {
        case ignored
        case unreadable
        case mismatch
        case member(UUID, isConnected: Bool, sink: KeepTalkingIrohContextTransport?, bluetooth: Data?)
    }

    fileprivate struct State {
        var isShutDown = false
        var startTask: Task<Endpoint, Error>?
        var endpoint: Endpoint?
        var myEndpointID: Data?
        var tasks: [Task<Void, Never>] = []
        var hub = HubState()
        var bluetooth = BluetoothState()
        var policy = DeliveryPolicy.standard
        var contexts: [Data: ContextEntry] = [:]
        var links: [Data: PeerLink] = [:]
        var droppedFrames = 0
        var events: [KeepTalkingIrohInstruments.Event] = []
        var nextEventID = 0

        var isHubUsable: Bool {
            hub.status == .ready && hub.writer != nil && !hub.suspended
        }

        /// A link that is connected and still has a path.
        func isCarrying(_ endpointID: Data) -> Bool {
            guard let link = links[endpointID] else { return false }
            return link.connection != nil && !link.pathless
        }

        /// The link carrying member `main`: its network link while that
        /// works, its Bluetooth link otherwise.
        func carrier(of main: Data, in entry: ContextEntry) -> Data? {
            if isCarrying(main) { return main }
            if let bluetooth = entry.bluetoothOf[main], isCarrying(bluetooth) { return bluetooth }
            return nil
        }

        /// One link per reachable member of `topic`.
        func connectedMembers(of topic: Data) -> [(endpointID: Data, nodeID: UUID)] {
            guard let entry = contexts[topic] else { return [] }
            return entry.members.compactMap { main, nodeID in
                carrier(of: main, in: entry).map { ($0, nodeID) }
            }
        }

        struct MemberKey: Hashable {
            let topic: Data
            let main: Data
        }

        /// Node and carrying link of every member `endpointIDs` (network or
        /// Bluetooth ids) belong to, per context; nil means every member.
        func carriers(touching endpointIDs: Set<Data>?) -> [MemberKey: (nodeID: UUID, carrier: Data?)] {
            var result: [MemberKey: (nodeID: UUID, carrier: Data?)] = [:]
            for (topic, entry) in contexts {
                let mains =
                    endpointIDs.map { ids in Set(ids.compactMap(entry.mainID(for:))) } ?? Set(entry.members.keys)
                for main in mains {
                    guard let nodeID = entry.members[main] else { continue }
                    result[MemberKey(topic: topic, main: main)] = (nodeID, carrier(of: main, in: entry))
                }
            }
            return result
        }

        /// The network gate: the hub is unusable, or a member that announced
        /// a Bluetooth id has no working network link.
        var needsBluetooth: Bool {
            !isHubUsable
                || contexts.values.contains { entry in
                    entry.bluetoothOf.keys.contains { !isCarrying($0) }
                }
        }

        /// The hub stopped listing `main` in `topic`. Its roster is only
        /// discovery, so a member a link still reaches — or that Bluetooth
        /// may reach — is kept until `sweepMembers` gives up on it. Returns
        /// the ids to unlink when the member is dropped now; nil when it's
        /// kept or wasn't a member.
        mutating func hubDropped(_ main: Data, in topic: Data, at now: ContinuousClock.Instant) -> [Data]? {
            guard let entry = contexts[topic], entry.members[main] != nil else { return nil }
            let mayUseBluetooth = bluetooth.myID != nil && entry.bluetoothOf[main] != nil
            if carrier(of: main, in: entry) != nil || mayUseBluetooth {
                if entry.offHub[main] == nil { contexts[topic]?.offHub[main] = now }
                return nil
            }
            var ids = [main]
            if let bluetooth = contexts[topic]?.forget(main: main) { ids.append(bluetooth) }
            return ids
        }

        /// Forgets members the hub stopped listing that no link has reached
        /// for `retention`. Returns who left and the connections to close.
        mutating func sweepMembers(
            at now: ContinuousClock.Instant,
            retention: Duration
        ) -> (left: [(KeepTalkingIrohContextTransport?, UUID)], orphans: [Connection]) {
            var left: [(KeepTalkingIrohContextTransport?, UUID)] = []
            var unlink: [Data] = []
            for (topic, entry) in contexts {
                for (main, since) in entry.offHub {
                    if carrier(of: main, in: entry) != nil {
                        contexts[topic]?.offHub[main] = now
                        continue
                    }
                    guard now - since >= retention, let nodeID = entry.members[main] else { continue }
                    unlink.append(main)
                    if let bluetooth = contexts[topic]?.forget(main: main) { unlink.append(bluetooth) }
                    left.append((entry.sink.value, nodeID))
                }
            }
            return (left, unlink.isEmpty ? [] : dropUnneededLinks(among: unlink))
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
            guard !isShutDown else { return false }
            if bluetooth.nearby[endpointID] != nil, !bluetooth.strangers.contains(endpointID) { return true }
            return contexts.values.contains {
                $0.members[endpointID] != nil || $0.bluetoothMembers[endpointID] != nil
            }
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
