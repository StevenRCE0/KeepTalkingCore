#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers
import Network
import os

/// The process-wide transport: one per process, owned by the host app and
/// handed to every client as `KeepTalkingTransport.iroh(host)`. Each client's
/// `connect()` attaches its context as a room (`KeepTalkingIrohAttachment`);
/// everything below is shared by every attached room.
///
/// - **SFU** — one connection to the Rust `kt-sfu` (`keeptalking/sfu/2`): a
///   session stream for room management, and a stream per lane.
///   Each attached context subscribes to its *topic* (`KeepTalkingIrohTopic`,
///   derived from the context secret) and announces a sealed presence blob
///   with our node id and endpoint ids. The SFU also fans publishes and
///   datagrams out to the topic, so a sender uploads once.
/// - **Mesh** — iroh connections (`keeptalking/peer/2`), one per remote
///   endpoint however many topics we share. They start on the relay and go
///   direct when hole punching works; the lower id dials. Rooms on the mesh
///   dial every member; rooms on the SFU open peer links only on demand
///   (blob transfers).
/// - **Bluetooth** — optional, on the process-wide Bluetooth-only endpoint
///   (`KeepTalkingIrohBluetoothRadio`), lent to one host at a time. Its
///   handshakes must run over Bluetooth, so it can't share the relay
///   endpoint; the higher id dials. Without the SFU, nearby devices are
///   found by reading the full key their advert only half-carries.
/// - **Membership** (`KeepTalkingIrohMembership`) — learned from sealed
///   presence, through the SFU or from the hello every link starts with.
///   The SFU roster is only discovery.
/// - **Delivery** — per room, the SFU or the mesh (`DeliveryPolicy`); on the
///   SFU, broadcasts fan out and directed frames go to one member
///   (PUBLISH_TO). Every frame rides a lane (`KeepTalkingEnvelopeDelivery`):
///   control and interactive are long-lived ordered streams, bulk frames get
///   a stream each, so no lane waits behind another. On the mesh every known
///   member has a byte-bounded queue per lane, drained by whichever of its
///   links carries it: network while that has a path, Bluetooth otherwise.
///   Nothing waits on a connection being up. When a member's carrier
///   changes, its context resyncs with it, recovering whatever a dying
///   connection swallowed. Blob bytes travel point to point on a stream per
///   transfer, never through the SFU. Voice datagrams never ride Bluetooth.
///
/// Frames for an attached topic are delivered whoever sent them: payloads
/// are sealed with the topic's key, so only members produce anything that
/// opens. Endpoint ids to dial come only from sealed presence, never from
/// the SFU. Keys are ephemeral; discovery is off (minimal preset, our relay
/// only); the SFU id comes from configuration or `<relay>/kt/sfu`.
public final class KeepTalkingIrohTransportHost: @unchecked Sendable {
    /// When the host uses the Bluetooth endpoint: Bluetooth links to members
    /// that announced an id, and discovery of nearby devices (serving and
    /// reading Bluetooth ids, dialling and accepting them, hellos).
    public enum BluetoothMode: String, Sendable, Hashable, CaseIterable {
        case off
        /// Online or not, so an online node also links to a nearby
        /// Bluetooth-only one.
        case always
        /// While the network gate is open: there is no network path, the SFU
        /// is unreachable, or a member that announced a Bluetooth id has no
        /// working network link — so an online device still meets a
        /// neighbour that went offline. Also for a short discovery window
        /// every couple of minutes, and when a context attaches or the
        /// network changes, to find context nodes it never met over the
        /// network; a window only links to what the network doesn't reach.
        case whenNetworkFails
    }

    public struct Configuration: Sendable, Hashable {
        /// Relay URL, e.g. `https://signal.rcex.live/`.
        public var relayURL: String
        /// SFU endpoint id (hex). Nil looks it up at `<relay>/kt/sfu`.
        public var sfuEndpointID: String?
        /// QUIC address-discovery port of the relay. Nil takes it from
        /// `/kt/sfu` (and disables QAD if the SFU id is configured by hand).
        public var relayQUICPort: UInt16?
        /// The Bluetooth LE endpoint (`iroh-ble-transport`, patched fork;
        /// AGPL-3.0). One per device: a controller never sees its own adverts.
        public var bluetooth: BluetoothMode

        public init(
            relayURL: String,
            sfuEndpointID: String? = nil,
            relayQUICPort: UInt16? = nil,
            bluetooth: BluetoothMode = .off
        ) {
            self.relayURL = relayURL
            self.sfuEndpointID = sfuEndpointID
            self.relayQUICPort = relayQUICPort
            self.bluetooth = bluetooth
        }
    }

    public typealias DeliveryPolicy = KeepTalkingIrohDeliveryPolicy
    public typealias Route = KeepTalkingIrohRoute
    typealias FrameKind = KeepTalkingIrohPeerFrame.Kind
    typealias Lane = KeepTalkingEnvelopeDelivery.Lane
    typealias Instant = SuspendingClock.Instant

    enum HostError: LocalizedError {
        case stopped
        case notAttached
        case noRoute
        case frameTooLarge(bytes: Int, limit: Int)
        case sfuInfo(String)
        case malformedFrame
        case notMember(UUID)

        var errorDescription: String? {
            switch self {
                case .stopped: return "The iroh transport host is stopped."
                case .notAttached: return "The context is not attached to the iroh host."
                case .noRoute: return "Neither the SFU nor any member is reachable."
                case .frameTooLarge(let bytes, let limit): return "Frame of \(bytes) bytes is over \(limit)."
                case .sfuInfo(let reason): return "SFU lookup failed: \(reason)"
                case .malformedFrame: return "Malformed frame."
                case .notMember(let node): return "Node \(node) isn't a member of this context."
            }
        }
    }

    static let peerALPN = KeepTalkingIrohPeerFrame.alpn

    // Outbound queue keys. Endpoint ids are 32 bytes; none of these are.

    /// A member's frames on one lane, drained by whichever link carries it.
    static func memberQueue(_ main: Data, _ lane: Lane) -> Data {
        var key = main
        key.append(lane.rawValue)
        return key
    }

    /// Control frames for one link only, like hellos — apart from the member
    /// queues, so a link that isn't carrying its member never drains those.
    static func linkQueue(_ endpointID: Data) -> Data {
        var key = Data("link".utf8)
        key.append(endpointID)
        return key
    }

    /// The SFU session stream: room management (subscribe, announce).
    static let sfuSessionQueue = Data("sfu-session".utf8)

    /// One SFU lane.
    static func sfuQueue(_ lane: Lane) -> Data {
        var key = Data("sfu".utf8)
        key.append(lane.rawValue)
        return key
    }

    /// How long a member stays wanted for a peer link once something (a
    /// blob transfer) asked for one in a room on the SFU.
    static let linkDemand: Duration = .seconds(120)
    /// Per-destination outbound budget.
    static let queueBudget = 16 << 20
    static let maxEvents = 300
    /// Network gate open this long before the host claims Bluetooth…
    static let bluetoothStartAfter: Duration = .seconds(3)
    /// …and closed this long before it lets go again.
    static let bluetoothStopAfter: Duration = .seconds(30)
    /// In `whenNetworkFails`, the radio also runs this long…
    static let discoveryWindow: Duration = .seconds(20)
    /// …this often, to find context nodes the network doesn't reach.
    static let discoveryInterval: Duration = .seconds(120)
    /// How long a member the SFU doesn't list is kept without any link
    /// reaching it, so Bluetooth can still find it.
    static let memberRetention: Duration = .seconds(30 * 60)
    /// An accepted link that hasn't shown a shared context by then is closed.
    static let acceptGrace: Duration = .seconds(30)
    /// At most one hello per link this often.
    static let helloInterval: Duration = .seconds(1)
    /// An SFU write making no progress this long means a dead session.
    static let sfuStallTimeout: Duration = .seconds(20)
    /// Network links ping this often…
    static let pingInterval: Duration = .seconds(2)
    /// …and one that heard nothing for this long stops carrying, and counts
    /// as a failing network for the Bluetooth gate. QUIC alone takes 30 s.
    static let silenceAfter: Duration = .seconds(6)
    /// Bytes of the key a Bluetooth advert carries.
    static let bluetoothPrefixLength = 12
    /// A nearby device that served no identity is asked again after this.
    static let identityRetryAfter: Duration = .seconds(30)

    public let configuration: Configuration
    let state = NIOLockedValueBox(State())
    let clock = SuspendingClock()

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

    /// Binds the network endpoint and starts the accept, SFU and maintenance
    /// loops. Idempotent; after a failed start the next call tries again.
    public func start() async throws {
        let task = try state.withLockedValue { state -> Task<Endpoint, Error> in
            if state.isShutDown { throw HostError.stopped }
            if let task = state.startTask { return task }
            let task = Task { try await self.bindEndpoint() }
            state.startTask = task
            return task
        }
        do {
            _ = try await task.value
        } catch {
            state.withLockedValue { state in
                if state.endpoint == nil { state.startTask = nil }
            }
            throw error
        }
    }

    public func shutdown() async {
        let (endpoint, tasks, ios, sfu) = state.withLockedValue { state in
            state.isShutDown = true
            state.pathMonitor?.cancel()
            state.pathMonitor = nil
            let ios = Array(state.io.values)
            let sfu = (state.sfu.connection, Array(state.sfu.doorbells.values))
            let tasks = state.tasks
            state.tasks = []
            state.io = [:]
            state.table = KeepTalkingIrohLinkTable()
            state.bluetooth.endpoint = nil
            state.sfu = SFUState()
            return (state.endpoint, tasks, ios, sfu)
        }
        tasks.forEach { $0.cancel() }
        ios.forEach { Self.tearDown($0, reason: "shutdown") }
        sfu.1.forEach { $0.finish() }
        try? sfu.0?.close(errorCode: 0, reason: Data("shutdown".utf8))
        try? await endpoint?.close()
        KeepTalkingIrohBluetoothRadio.shared.release(from: self)
        log("host shut down")
    }

    private func bindEndpoint() async throws -> Endpoint {
        let options = EndpointOptions(
            preset: presetMinimal(),
            alpns: [Self.peerALPN],
            relayMode: try RelayMode.customFromUrls(urls: [configuration.relayURL])
        )
        let endpoint = try await Endpoint.bind(options: options)
        do {
            if let port = configuration.relayQUICPort {
                try await endpoint.insertRelay(
                    config: RelayConfig(url: configuration.relayURL, quicPort: port, authToken: nil)
                )
            }
        } catch {
            try? await endpoint.close()
            throw error
        }
        let myID = endpoint.id().toBytes()
        let installed = state.withLockedValue { state -> Bool in
            guard !state.isShutDown else { return false }
            state.endpoint = endpoint
            state.myEndpointID = myID
            state.tasks += [
                Task { await self.acceptLoop(endpoint, kind: .network) },
                Task { await self.sfuLoop(endpoint) },
                Task { await self.maintenanceLoop() },
            ]
            state.pathMonitor = startPathMonitor()
            return true
        }
        guard installed else {
            try? await endpoint.close()
            throw HostError.stopped
        }
        log("endpoint \(Self.hex(myID).prefix(10)) bound \(endpoint.boundSockets().joined(separator: ", "))")
        return endpoint
    }

    // MARK: - Attachments

    /// Registers a context: subscribes to its topic at the SFU, announces our
    /// sealed presence and says hello on every link. The endpoint must be
    /// bound (`start()`). A later attach of the same topic takes it over.
    func attach(
        _ sink: KeepTalkingIrohAttachment,
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
        assert(blob.count <= KeepTalkingIrohSFUFrame.maxAnnounceLength)
        // Queue the SFU frames in the critical section that registers the
        // topic: the SFU loop re-subscribes every registered topic in the one
        // that publishes its session, so a topic is never missed or doubled.
        let (doorbell, links, joined) = state.withLockedValue {
            state -> (AsyncStream<Void>.Continuation?, [Data], Bool) in
            state.membership.attach(topic, nodeID: nodeID, secret: secret)
            // Taking over a topic already subscribed: the SFU ignores the
            // repeated SUBSCRIBE, so no snapshot will say we joined.
            let joined = state.membership.contexts[topic.topic]?.joined ?? false
            let previous = state.attachments[topic.topic]
            var attachment = Attachment(sink: sink, topic: topic, nodeID: nodeID, blob: blob)
            if let previous { attachment.inheritCounters(from: previous) }
            state.attachments[topic.topic] = attachment
            state.bluetooth.strangers = []
            state.bluetooth.discovery.lookSoon()
            guard let doorbell = state.sfu.doorbells[Self.sfuSessionQueue] else {
                return (nil, state.connectedLinks, false)
            }
            state.outbound.enqueue(
                KeepTalkingIrohSFUFrame.encode(.subscribe(topic: topic.topic)),
                for: Self.sfuSessionQueue
            )
            state.outbound.enqueue(
                KeepTalkingIrohSFUFrame.encode(.announce(topic: topic.topic, blob: blob)),
                for: Self.sfuSessionQueue
            )
            return (doorbell, state.connectedLinks, joined)
        }
        doorbell?.yield()
        sendHello(to: links)
        // Not inline: the transport attaches under its own lock, which
        // sfuJoined takes again to send a heartbeat.
        if joined { Task { sink.sfuJoined() } }
        log("ctx \(topic.contextID.uuidString.prefix(8)) attached on topic \(Self.hex(topic.topic).prefix(10))")
    }

    /// Unregisters `sink`'s context. A stale detach — another attachment took
    /// the topic over since — does nothing.
    func detach(_ sink: KeepTalkingIrohAttachment, topic: Data) {
        let detached = mutateLinks(touching: nil) { state -> (AsyncStream<Void>.Continuation?, [LinkIO], [Data])? in
            guard let attachment = state.attachments[topic], attachment.sink === sink else { return nil }
            state.attachments[topic] = nil
            let ids = state.membership.detach(topic)
            state.outbound.enqueue(
                KeepTalkingIrohSFUFrame.encode(.unsubscribe(topic: topic)),
                for: Self.sfuSessionQueue
            )
            return (
                state.sfu.doorbells[Self.sfuSessionQueue], state.dropUnneededLinks(among: ids), state.connectedLinks
            )
        }
        guard let detached else { return }
        let (doorbell, orphans, links) = detached
        doorbell?.yield()
        orphans.forEach { Self.tearDown($0, reason: "left") }
        // Peers learn we left from a hello that no longer lists the topic.
        sendHello(to: links)
        log("topic \(Self.hex(topic).prefix(10)) detached")
    }

    // MARK: - Sending

    /// Publishes one frame to `topic` on `lane`. A room on the SFU gets it
    /// fanned out there, or sent to one member when it's directed; a room on
    /// the mesh gets it queued for every member (or the one it's directed
    /// at). Throws when there's no route, so callers such as the outbox keep
    /// the payload.
    @discardableResult
    func publish(_ kind: FrameKind, topic: Data, payload: Data, to target: UUID?, lane: Lane) throws -> Route {
        let bodyLength = 1 + payload.count
        guard bodyLength <= KeepTalkingIrohSFUFrame.maxPublishLength else {
            throw HostError.frameTooLarge(bytes: bodyLength, limit: KeepTalkingIrohSFUFrame.maxPublishLength - 1)
        }
        let (route, doorbells) = try state.withLockedValue {
            state -> (Route, [AsyncStream<Void>.Continuation]) in
            guard !state.isShutDown else { throw HostError.stopped }
            guard state.attachments[topic] != nil else { throw HostError.notAttached }
            let members = state.membership.members(of: topic)
            let recipient = target.flatMap { target in members.first { $0.nodeID == target }?.main }
            switch state.route(for: topic) {
                case .sfu?:
                    var body = Data([kind.rawValue])
                    body.append(payload)
                    let frame = KeepTalkingIrohSFUFrame.encode(
                        recipient.map { .publishTo(topic: topic, recipient: $0, payload: body) }
                            ?? .publish(topic: topic, payload: body)
                    )
                    let queue = Self.sfuQueue(lane)
                    guard state.outbound.fits(frame.count, for: queue) else { throw HostError.noRoute }
                    state.outbound.enqueue(frame, for: queue)
                    state.attachments[topic]?.sfuPublished += 1
                    return (.sfu, [state.sfu.doorbells[queue]].compactMap { $0 })
                case .mesh?:
                    let frame = KeepTalkingIrohPeerFrame.encode(kind: kind, topic: topic, payload: payload)
                    state.attachments[topic]?.meshPublished += 1
                    let mains = recipient.map { [$0] } ?? members.map(\.main)
                    return (.mesh, mains.flatMap { state.enqueue(frame, forMember: $0, lane: lane) })
                case nil:
                    throw HostError.noRoute
            }
        }
        doorbells.forEach { $0.yield() }
        return route
    }

    /// Unreliable realtime bytes (voice), routed like a publish. Datagrams
    /// don't queue: on the mesh they go only to members a network link
    /// reaches now — never over Bluetooth, which can't carry a call.
    func sendDatagram(topic: Data, payload: Data) throws {
        let datagram = KeepTalkingIrohSFUFrame.datagram(topic: topic, payload: payload)
        let connections = try state.withLockedValue { state -> [Connection] in
            guard !state.isShutDown else { throw HostError.stopped }
            let members = state.membership.members(of: topic)
            switch state.route(for: topic) {
                case .sfu?:
                    state.attachments[topic]?.sfuDatagramsSent += 1
                    return [state.sfu.connection].compactMap { $0 }
                case .mesh?:
                    return members.compactMap { member in
                        guard state.table.isCarrying(member.main) else { return nil }
                        state.table.update(member.main) { $0.datagramsSent += 1 }
                        return state.io[member.main]?.connection
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

    // MARK: - Room status

    /// `topic`'s status, as its attachment reports it.
    func roomStatus(of topic: Data) -> KeepTalkingTransportStatus {
        let (route, carriers, settling) = state.withLockedValue { state in
            let carriers = state.membership.members(of: topic).map { member -> (LinkKind, Connection?)? in
                guard let link = state.carrier(of: member.main), let kind = state.table.links[link]?.kind else {
                    return nil
                }
                return (kind, state.io[link]?.connection)
            }
            return (state.route(for: topic), carriers, state.sfuSettling(for: topic))
        }
        return KeepTalkingIrohDelivery.status(route: route, members: carriers.map(Self.reach), settling: settling)
    }

    /// `topic`'s members and queues; the attachment adds its own counters.
    func roomStats(of topic: Data) -> KeepTalkingRuntimeStats {
        let (members, reachable, queued) = state.withLockedValue { state -> (Int, Int, Int) in
            let members = state.membership.members(of: topic)
            let reachable = members.filter { state.carrier(of: $0.main) != nil }.count
            let queued = members.reduce(0) { total, member in
                Lane.allCases.reduce(total) { $0 + state.outbound.bytes(for: Self.memberQueue(member.main, $1)) }
            }
            return (members.count, reachable, queued)
        }
        return KeepTalkingRuntimeStats(
            members: members,
            reachableMembers: reachable,
            queuedBytes: queued,
            status: roomStatus(of: topic)
        )
    }

    /// How a member's carrier reaches it. Reads the connection's paths, so
    /// call it outside the lock.
    private static func reach(_ carrier: (LinkKind, Connection?)?) -> KeepTalkingIrohDelivery.MemberReach {
        guard let (kind, connection) = carrier else { return .unreachable }
        if kind == .bluetooth { return .bluetooth }
        let direct = connection?.paths().contains { $0.isSelected && !$0.isRelay } ?? false
        return direct ? .direct : .relay
    }

    // MARK: - Change notifications

    /// Applies a state change and tells each context how the carrying link of
    /// the members it touched changed: one appeared (`peerLinkUp`), none is
    /// left (`peerLinkDown`), or traffic moved to another live connection
    /// (`peerRerouted` — the context resyncs over it, since whatever went
    /// into the old one may be gone). Doorbells of new carriers are rung so
    /// queued frames move. `touching` names the endpoints whose members to
    /// compare; nil compares every member.
    @discardableResult
    func mutateLinks<T>(touching endpointIDs: Set<Data>?, _ change: (inout State) -> T) -> T {
        let (result, changes, doorbells) = state.withLockedValue {
            state -> (T, [CarrierChange], [AsyncStream<Void>.Continuation]) in
            let before = state.carriers(touching: endpointIDs)
            let result = change(&state)
            let after = state.carriers(touching: endpointIDs)
            var changes: [CarrierChange] = []
            var doorbells: [AsyncStream<Void>.Continuation] = []
            for key in Set(before.keys).union(after.keys) {
                let old = before[key]
                let new = after[key]
                guard old?.carrier != new?.carrier || old?.stableID != new?.stableID,
                    let nodeID = (new ?? old)?.nodeID
                else { continue }
                let sink = state.attachments[key.topic]?.sink
                switch (old?.carrier, new?.carrier) {
                    case (nil, nil): continue
                    case (nil, _?): changes.append(.up(sink, nodeID))
                    case (_?, nil): changes.append(.down(sink, nodeID))
                    default: changes.append(.rerouted(sink, nodeID))
                }
                if let carrier = new?.carrier, let io = state.io[carrier] {
                    doorbells.append(contentsOf: io.doorbells.values)
                }
            }
            return (result, changes, doorbells)
        }
        doorbells.forEach { $0.yield() }
        for change in changes {
            switch change {
                case .up(let sink, let nodeID): sink?.peerLinkUp(nodeID)
                case .down(let sink, let nodeID): sink?.peerLinkDown(nodeID)
                case .rerouted(let sink, let nodeID): sink?.peerRerouted(nodeID)
            }
        }
        return result
    }

    enum CarrierChange {
        case up(KeepTalkingIrohAttachment?, UUID)
        case down(KeepTalkingIrohAttachment?, UUID)
        case rerouted(KeepTalkingIrohAttachment?, UUID)
    }

    func notifyAllContexts(_ body: (KeepTalkingIrohAttachment) -> Void) {
        let sinks = state.withLockedValue { $0.attachments.values.compactMap(\.sink) }
        sinks.forEach(body)
    }

    /// Finishes a link's doorbell, cancels its tasks and closes its
    /// connection.
    static func tearDown(_ io: LinkIO, reason: String) {
        io.doorbells.values.forEach { $0.finish() }
        io.tasks.forEach { $0.cancel() }
        try? io.connection?.close(errorCode: 0, reason: Data(reason.utf8))
    }

    // MARK: - Log

    static let logger = Logger(subsystem: "KeepTalkingSDK", category: "transport")

    /// Records an event for `instruments()`, and in the system log (Xcode's
    /// console) under KeepTalkingSDK / transport.
    func log(_ text: String) {
        Self.logger.info("\(text, privacy: .public)")
        state.withLockedValue { state in
            state.nextEventID += 1
            state.events.append(.init(id: state.nextEventID, at: Date(), text: text))
            if state.events.count > Self.maxEvents {
                state.events.removeFirst(state.events.count - Self.maxEvents)
            }
        }
    }

    // MARK: - Helpers

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

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.0fms", milliseconds(duration))
    }
}

// MARK: - State

extension KeepTalkingIrohTransportHost {
    enum SFUStatus: Equatable {
        case idle
        case connecting(attempt: Int)
        case ready
    }

    struct SFUState {
        var status: SFUStatus = .idle
        var connection: Connection?
        /// Per queue (session, each lane): rung when it has frames; set while
        /// a session is up.
        var doorbells: [Data: AsyncStream<Void>.Continuation] = [:]
        /// Lanes hold their frames until the session's subscriptions are in,
        /// so the SFU never sees a publish for a topic it hasn't subscribed.
        var lanesOpen = false
        var resolvedID: String?
        var attempts = 0
        var connectLatency: Duration?
        var connectedSince: Date?
        /// When each pump's current write started; absent while idle.
        var writingSince: [Data: Instant] = [:]
        var skippedFrames = 0
        /// Below the SFU's 200 frames/s and 4 MiB/s (bursts 400 and 4 MiB),
        /// across all lanes.
        var framePacer = KeepTalkingIrohPacer(rate: 150, burst: 300)
        var bytePacer = KeepTalkingIrohPacer(rate: 3 * 1024 * 1024, burst: 3 * 1024 * 1024)
        /// Snapshot chunks received so far, per topic.
        var pendingSnapshots: [Data: [KeepTalkingIrohSFUFrame.Member]] = [:]
        /// Rung by a network change to end the wait before the next attempt.
        var retryBell: AsyncStream<Void>.Continuation?
        /// The network changed during an attempt: skip the wait after it.
        var retryNow = false

        /// How long to wait before sending `frames` frames of `bytes` bytes.
        mutating func pace(frames: Int, bytes: Int, now: Instant) -> Duration {
            max(framePacer.take(Double(frames), now: now), bytePacer.take(Double(bytes), now: now))
        }
    }

    struct BluetoothState {
        /// The process-wide Bluetooth endpoint id, announced in presence.
        var myID: Data?
        /// The radio's endpoint while this host holds it.
        var endpoint: Endpoint?
        var starting = false
        var failure: String?
        var starts = 0
        var gate = KeepTalkingIrohNetworkGate(
            openAfter: KeepTalkingIrohTransportHost.bluetoothStartAfter,
            closeAfter: KeepTalkingIrohTransportHost.bluetoothStopAfter
        )
        var discovery = KeepTalkingIrohDiscoverySchedule(
            window: KeepTalkingIrohTransportHost.discoveryWindow,
            interval: KeepTalkingIrohTransportHost.discoveryInterval
        )
        /// The radio is held for a discovery window only: links just to
        /// devices whose hello we haven't seen and members the network
        /// doesn't reach.
        var discovering = false
        /// Bluetooth ids read from nearby devices → their device id.
        var nearby: [Data: String] = [:]
        /// Nearby ids whose hello opened none of our contexts; forgotten
        /// when we attach another.
        var strangers: Set<Data> = []
        var probing = false
        var probeRetryAt: [String: Instant] = [:]
    }

    struct Attachment {
        weak var sink: KeepTalkingIrohAttachment?
        let topic: KeepTalkingIrohTopic
        let nodeID: UUID
        let blob: Data
        var meshPublished = 0
        var sfuPublished = 0
        var meshReceived = 0
        var sfuReceived = 0
        var sfuDatagramsSent = 0
        var sfuDatagramsReceived = 0

        init(sink: KeepTalkingIrohAttachment, topic: KeepTalkingIrohTopic, nodeID: UUID, blob: Data) {
            self.sink = sink
            self.topic = topic
            self.nodeID = nodeID
            self.blob = blob
        }

        mutating func inheritCounters(from other: Attachment) {
            meshPublished = other.meshPublished
            sfuPublished = other.sfuPublished
            meshReceived = other.meshReceived
            sfuReceived = other.sfuReceived
            sfuDatagramsSent = other.sfuDatagramsSent
            sfuDatagramsReceived = other.sfuDatagramsReceived
        }
    }

    /// The iroh side of a link: its connection once up, the doorbell each
    /// lane's pump waits on, and its tasks.
    struct LinkIO {
        var connection: Connection?
        var doorbells: [Lane: AsyncStream<Void>.Continuation] = [:]
        var tasks: [Task<Void, Never>] = []
        var watch: WatchHandle?
    }

    struct MemberKey: Hashable {
        let topic: Data
        let main: Data
    }

    struct State {
        var isShutDown = false
        var startTask: Task<Endpoint, Error>?
        var endpoint: Endpoint?
        var myEndpointID: Data?
        var tasks: [Task<Void, Never>] = []
        var policy = DeliveryPolicy.standard
        var membership = KeepTalkingIrohMembership()
        var attachments: [Data: Attachment] = [:]
        var table = KeepTalkingIrohLinkTable()
        var io: [Data: LinkIO] = [:]
        var outbound = KeepTalkingIrohOutbound(budget: KeepTalkingIrohTransportHost.queueBudget)
        /// Members wanted for a peer link until then, though their rooms are
        /// on the SFU: something (a blob transfer) needs one.
        var demand: [Data: Instant] = [:]
        var sfu = SFUState()
        var bluetooth = BluetoothState()
        /// Watches the system's network path while the endpoint is bound.
        var pathMonitor: NWPathMonitor?
        /// The last path seen, for the log; nil before the first.
        var path: String?
        var pathSatisfied = true
        /// Counts network changes, so a burst of them acts once.
        var networkChanges = 0
        var droppedFrames = 0
        var events: [KeepTalkingIrohInstruments.Event] = []
        var nextEventID = 0

        var sfuUsable: Bool {
            sfu.status == .ready && sfu.lanesOpen
        }

        /// The SFU can carry `topic`: the session is up and its snapshot for
        /// the topic arrived, so the subscription is in.
        func sfuUsable(for topic: Data) -> Bool {
            sfuUsable && membership.contexts[topic]?.joined == true
        }

        /// The SFU session, or `topic`'s subscription on it, is still on its
        /// first way up: nothing reachable then reads as connecting, not
        /// offline.
        func sfuSettling(for topic: Data) -> Bool {
            switch sfu.status {
                case .idle, .connecting(attempt: 0): return true
                case .connecting: return false
                case .ready: return !sfuUsable(for: topic)
            }
        }

        /// Where `topic`'s traffic goes now.
        func route(for topic: Data) -> Route? {
            KeepTalkingIrohDelivery.route(
                policy,
                sfuUsable: sfuUsable(for: topic),
                members: membership.contexts[topic]?.members.count ?? 0
            )
        }

        /// Members of rooms on the mesh, which get a peer link each.
        var meshMembers: Set<Data> {
            membership.contexts.reduce(into: Set<Data>()) { result, entry in
                if route(for: entry.key) == .mesh { result.formUnion(entry.value.members.keys) }
            }
        }

        /// Whether to dial `endpointID` (a member's network or Bluetooth id,
        /// or a nearby device): its room is on the mesh, something demands a
        /// link, or it's a nearby device whose hello we haven't seen.
        func wantsDial(_ endpointID: Data, now: Instant) -> Bool {
            guard isWanted(endpointID) else { return false }
            let mains = membership.mains(for: endpointID)
            // Looking around only: no Bluetooth link to a member the network
            // already carries.
            if bluetooth.discovering, isBluetoothID(endpointID), !mains.isEmpty, mains.allSatisfy(table.isCarrying) {
                return false
            }
            if bluetooth.nearby[endpointID] != nil, !bluetooth.strangers.contains(endpointID) { return true }
            if mains.contains(where: { (demand[$0] ?? now) > now }) { return true }
            return !mains.isDisjoint(with: meshMembers)
        }

        var connectedLinks: [Data] {
            table.links.filter(\.value.isConnected).map(\.key)
        }

        /// A member, or a nearby device whose hello we haven't seen refused.
        func isBluetoothID(_ endpointID: Data) -> Bool {
            bluetooth.nearby[endpointID] != nil || membership.bluetoothIDs.contains(endpointID)
        }

        func isWanted(_ endpointID: Data) -> Bool {
            guard !isShutDown else { return false }
            if membership.isMember(endpointID) { return true }
            return bluetooth.nearby[endpointID] != nil && !bluetooth.strangers.contains(endpointID)
        }

        /// The link carrying member `main`: its network link while that has
        /// a path, its Bluetooth link otherwise.
        func carrier(of main: Data) -> Data? {
            if table.isCarrying(main) { return main }
            if let bluetooth = membership.bluetoothID(of: main), table.isCarrying(bluetooth) { return bluetooth }
            return nil
        }

        /// Members whose traffic `linkID` carries now.
        func carried(by linkID: Data) -> [Data] {
            guard table.isCarrying(linkID) else { return [] }
            return membership.mains(for: linkID).filter { carrier(of: $0) == linkID }
        }

        /// The network gate's input: why the network counts as failing, or
        /// nil. No network path, the SFU unusable, or a member that announced
        /// a Bluetooth id has no working network link.
        var networkFailure: String? {
            if !pathSatisfied { return "no network path" }
            if !sfuUsable { return "SFU unusable" }
            let unlinked = meshMembers.first { main in
                membership.bluetoothID(of: main) != nil && !table.isCarrying(main)
            }
            return unlinked.map { "no network link to \(KeepTalkingIrohTransportHost.hex($0).prefix(10))" }
        }

        /// Queues a peer frame for `main` on `lane`; returns its carrier's
        /// doorbell for that lane.
        mutating func enqueue(_ frame: Data, forMember main: Data, lane: Lane) -> [AsyncStream<Void>.Continuation] {
            outbound.enqueue(frame, for: KeepTalkingIrohTransportHost.memberQueue(main, lane))
            guard let carrier = carrier(of: main), let doorbell = io[carrier]?.doorbells[lane] else { return [] }
            return [doorbell]
        }

        /// Node, carrying link and its connection per member that the given
        /// endpoints stand for (every member when nil), per context.
        func carriers(touching endpointIDs: Set<Data>?) -> [MemberKey: (
            nodeID: UUID, carrier: Data?, stableID: UInt64?
        )] {
            var result: [MemberKey: (nodeID: UUID, carrier: Data?, stableID: UInt64?)] = [:]
            for (topic, context) in membership.contexts {
                let mains =
                    endpointIDs.map { ids in Set(ids.flatMap(context.mains(for:))) } ?? Set(context.members.keys)
                for main in mains {
                    guard let nodeID = context.members[main] else { continue }
                    let carrier = carrier(of: main)
                    result[MemberKey(topic: topic, main: main)] = (
                        nodeID, carrier, carrier.flatMap { table.links[$0]?.stableID }
                    )
                }
            }
            return result
        }

        /// Forgets links no context needs; returns their iroh side to tear
        /// down. `candidates` limits the sweep, so an accepted link whose
        /// hello hasn't arrived yet survives. Queues of members that are gone
        /// go too.
        mutating func dropUnneededLinks(among candidates: [Data]) -> [LinkIO] {
            var orphans: [LinkIO] = []
            for id in Set(candidates) where !isWanted(id) {
                if !membership.allMains.contains(id) {
                    for lane in Lane.allCases {
                        outbound.remove(KeepTalkingIrohTransportHost.memberQueue(id, lane))
                    }
                }
                guard table.links[id] != nil else { continue }
                table.remove(id)
                outbound.remove(KeepTalkingIrohTransportHost.linkQueue(id))
                if let io = io.removeValue(forKey: id) { orphans.append(io) }
            }
            return orphans
        }
    }
}

/// Forwards iroh path events of one connection back to the host.
final class LinkPathWatcher: PathEventCallback, @unchecked Sendable {
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
// MARK: - Multiplexer

extension KeepTalkingIrohTransportHost: KeepTalkingTransportMultiplexer {
    /// Starts the host if this is its first attachment, then joins the
    /// room's topic.
    func attach(
        _ room: KeepTalkingTransportRoom,
        events: @escaping KeepTalkingTransportEventHandler
    ) async throws -> any KeepTalkingTransportAttachment {
        do {
            try await start()
            let attachment = KeepTalkingIrohAttachment(host: self, room: room, events: events)
            try attach(attachment, topic: attachment.topic, nodeID: room.nodeID, secret: room.secret)
            return attachment
        } catch HostError.stopped {
            throw KeepTalkingTransportError.unavailable
        }
    }
}
#endif
