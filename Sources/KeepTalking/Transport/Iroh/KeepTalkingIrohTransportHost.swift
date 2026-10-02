#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// The iroh endpoints shared by every context attached to them.
///
/// - **SFU** — one connection to the Rust `kt-sfu` (`keeptalking/sfu/1`).
///   Each attached context subscribes to its *topic* (`KeepTalkingIrohTopic`,
///   derived from the context secret) and announces a sealed presence blob
///   with our node id and endpoint ids. The SFU also fans publishes and
///   datagrams out to the topic, so a sender uploads once.
/// - **Mesh** — iroh connections (`keeptalking/peer/1`), one per remote
///   endpoint however many topics we share. They start on the relay and go
///   direct when hole punching works; the lower id dials.
/// - **Bluetooth** — optional, on the process-wide Bluetooth-only endpoint
///   (`KeepTalkingIrohBluetoothRadio`), lent to one host at a time. Its
///   handshakes must run over Bluetooth, so it can't share the relay
///   endpoint; the higher id dials. Without the SFU, nearby devices are
///   found by reading the full key their advert only half-carries.
/// - **Membership** (`KeepTalkingIrohMembership`) — learned from sealed
///   presence, through the SFU or from the hello every link starts with.
///   The SFU roster is only discovery.
/// - **Delivery** — per publish, the SFU or the mesh (`DeliveryPolicy`). On
///   the mesh every known member has a byte-bounded queue, drained by
///   whichever of its links carries it: network while that has a path,
///   Bluetooth otherwise. Nothing waits on a connection being up. When a
///   member's carrier changes, its context resyncs with it, recovering
///   whatever a dying connection swallowed.
///
/// Frames for an attached topic are delivered whoever sent them: payloads
/// are sealed with the topic's key, so only members produce anything that
/// opens. Endpoint ids to dial come only from sealed presence, never from
/// the SFU. Keys are ephemeral; discovery is off (minimal preset, our relay
/// only); the SFU id comes from configuration or `<relay>/kt/sfu`.
@_spi(TransportLab)
public final class KeepTalkingIrohTransportHost: @unchecked Sendable {
    /// When the host uses the Bluetooth endpoint: Bluetooth links to members
    /// that announced an id, and discovery of nearby devices (serving and
    /// reading Bluetooth ids, dialling and accepting them, hellos).
    public enum BluetoothMode: String, Sendable, Hashable, CaseIterable {
        case off
        /// Online or not, so an online node also links to a nearby
        /// Bluetooth-only one.
        case always
        /// Only while the network gate is open: the SFU is unreachable (or
        /// suspended), or a member that announced a Bluetooth id has no
        /// working network link — so an online device still meets a
        /// neighbour that went offline.
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
    typealias Instant = SuspendingClock.Instant

    enum HostError: LocalizedError {
        case stopped
        case notAttached
        case noRoute
        case frameTooLarge(bytes: Int, limit: Int)
        case sfuInfo(String)
        case malformedFrame

        var errorDescription: String? {
            switch self {
                case .stopped: return "The iroh transport host is stopped."
                case .notAttached: return "The context is not attached to the iroh host."
                case .noRoute: return "Neither the SFU nor any member is reachable."
                case .frameTooLarge(let bytes, let limit): return "Frame of \(bytes) bytes is over \(limit)."
                case .sfuInfo(let reason): return "SFU lookup failed: \(reason)"
                case .malformedFrame: return "Malformed frame."
            }
        }
    }

    static let peerALPN = Data("keeptalking/peer/1".utf8)
    /// The SFU's outbound queue key (not 32 bytes, so never an endpoint id).
    static let sfuQueue = Data("sfu".utf8)

    /// The queue of frames for one link only, like hellos — apart from the
    /// member queue its endpoint id keys, so a link that isn't carrying its
    /// member never drains that.
    static func linkQueue(_ endpointID: Data) -> Data {
        var key = Data("link".utf8)
        key.append(endpointID)
        return key
    }
    /// Per-destination outbound budget.
    static let queueBudget = 16 << 20
    static let maxEvents = 300
    /// Network gate open this long before the host claims Bluetooth…
    static let bluetoothStartAfter: Duration = .seconds(3)
    /// …and closed this long before it lets go again.
    static let bluetoothStopAfter: Duration = .seconds(30)
    /// How long a member the SFU doesn't list is kept without any link
    /// reaching it, so Bluetooth can still find it.
    static let memberRetention: Duration = .seconds(30 * 60)
    /// An accepted link that hasn't shown a shared context by then is closed.
    static let acceptGrace: Duration = .seconds(30)
    /// At most one hello per link this often.
    static let helloInterval: Duration = .seconds(1)
    /// An SFU write making no progress this long means a dead session.
    static let sfuStallTimeout: Duration = .seconds(20)
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
            let ios = Array(state.io.values)
            let sfu = (state.sfu.connection, state.sfu.doorbell)
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
        sfu.1?.finish()
        try? sfu.0?.close(errorCode: 0, reason: Data("shutdown".utf8))
        try? await endpoint?.close()
        KeepTalkingIrohBluetoothRadio.shared.release(from: self)
        log("host shut down")
    }

    public var deliveryPolicy: DeliveryPolicy {
        get { state.withLockedValue { $0.policy } }
        set { state.withLockedValue { $0.policy = newValue } }
    }

    /// Lab switch: drop the SFU session and keep it down until resumed, so
    /// the rest of the host runs as if the SFU were unreachable.
    public func setSFUSuspended(_ suspended: Bool) {
        let connection = state.withLockedValue { state -> Connection? in
            state.sfu.suspended = suspended
            return suspended ? state.sfu.connection : nil
        }
        try? connection?.close(errorCode: 0, reason: Data("suspended".utf8))
        log(suspended ? "SFU suspended" : "SFU resumed")
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
        assert(blob.count <= KeepTalkingIrohSFUFrame.maxAnnounceLength)
        // Queue the SFU frames in the critical section that registers the
        // topic: the SFU loop re-subscribes every registered topic in the one
        // that publishes its session, so a topic is never missed or doubled.
        let (doorbell, links) = state.withLockedValue { state -> (AsyncStream<Void>.Continuation?, [Data]) in
            state.membership.attach(topic, nodeID: nodeID, secret: secret)
            let previous = state.attachments[topic.topic]
            var attachment = Attachment(sink: sink, topic: topic, nodeID: nodeID, blob: blob)
            if let previous { attachment.inheritCounters(from: previous) }
            state.attachments[topic.topic] = attachment
            state.bluetooth.strangers = []
            guard let doorbell = state.sfu.doorbell else { return (nil, state.connectedLinks) }
            state.outbound.enqueue(KeepTalkingIrohSFUFrame.encode(.subscribe(topic: topic.topic)), for: Self.sfuQueue)
            state.outbound.enqueue(
                KeepTalkingIrohSFUFrame.encode(.announce(topic: topic.topic, blob: blob)),
                for: Self.sfuQueue
            )
            return (doorbell, state.connectedLinks)
        }
        doorbell?.yield()
        sendHello(to: links)
        log("ctx \(topic.contextID.uuidString.prefix(8)) attached on topic \(Self.hex(topic.topic).prefix(10))")
    }

    /// Unregisters `sink`'s context. A stale detach — another attachment took
    /// the topic over since — does nothing.
    func detach(_ sink: KeepTalkingIrohContextTransport, topic: Data) {
        let detached = mutateLinks(touching: nil) { state -> (AsyncStream<Void>.Continuation?, [LinkIO], [Data])? in
            guard let attachment = state.attachments[topic], attachment.sink === sink else { return nil }
            state.attachments[topic] = nil
            let ids = state.membership.detach(topic)
            state.outbound.enqueue(KeepTalkingIrohSFUFrame.encode(.unsubscribe(topic: topic)), for: Self.sfuQueue)
            return (state.sfu.doorbell, state.dropUnneededLinks(among: ids), state.connectedLinks)
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

    /// Publishes one frame to `topic`. A frame directed at a known member goes
    /// to that member's queue; everything else goes through the SFU or the
    /// mesh per `DeliveryPolicy`. Throws when there's no route, so callers
    /// such as the outbox keep the payload.
    @discardableResult
    func publish(_ kind: FrameKind, topic: Data, payload: Data, to target: UUID?) throws -> Route {
        let bodyLength = 1 + payload.count
        guard bodyLength <= KeepTalkingIrohSFUFrame.maxPublishLength else {
            throw HostError.frameTooLarge(bytes: bodyLength, limit: KeepTalkingIrohSFUFrame.maxPublishLength - 1)
        }
        let peerFrame = KeepTalkingIrohPeerFrame.encode(kind: kind, topic: topic, payload: payload)
        let (route, doorbells) = try state.withLockedValue {
            state -> (Route, [AsyncStream<Void>.Continuation]) in
            guard !state.isShutDown else { throw HostError.stopped }
            guard state.attachments[topic] != nil else { throw HostError.notAttached }
            let members = state.membership.members(of: topic)
            if let target, let main = members.first(where: { $0.nodeID == target })?.main {
                state.attachments[topic]?.meshPublished += 1
                return (.mesh, state.enqueue(peerFrame, forMember: main))
            }
            switch KeepTalkingIrohDelivery.route(state.policy, sfuUsable: state.sfuUsable, members: members.count) {
                case .sfu?:
                    var body = Data([kind.rawValue])
                    body.append(payload)
                    let frame = KeepTalkingIrohSFUFrame.encode(.publish(topic: topic, payload: body))
                    guard state.outbound.fits(frame.count, for: Self.sfuQueue) else { throw HostError.noRoute }
                    state.outbound.enqueue(frame, for: Self.sfuQueue)
                    state.attachments[topic]?.sfuPublished += 1
                    return (.sfu, [state.sfu.doorbell].compactMap { $0 })
                case .mesh?:
                    state.attachments[topic]?.meshPublished += 1
                    return (.mesh, members.flatMap { state.enqueue(peerFrame, forMember: $0.main) })
                case nil:
                    throw HostError.noRoute
            }
        }
        doorbells.forEach { $0.yield() }
        return route
    }

    /// Unreliable realtime bytes (voice), routed like a publish. Datagrams
    /// don't queue: on the mesh they go only to members a link reaches now.
    func sendDatagram(topic: Data, payload: Data) throws {
        let datagram = KeepTalkingIrohSFUFrame.datagram(topic: topic, payload: payload)
        let connections = try state.withLockedValue { state -> [Connection] in
            guard !state.isShutDown else { throw HostError.stopped }
            let members = state.membership.members(of: topic)
            switch KeepTalkingIrohDelivery.route(state.policy, sfuUsable: state.sfuUsable, members: members.count) {
                case .sfu?:
                    state.attachments[topic]?.sfuDatagramsSent += 1
                    return [state.sfu.connection].compactMap { $0 }
                case .mesh?:
                    return members.compactMap { member in
                        guard let carrier = state.carrier(of: member.main) else { return nil }
                        state.table.update(carrier) { $0.datagramsSent += 1 }
                        return state.io[carrier]?.connection
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

    func sfuChannelState() -> BroadcastChannelState {
        state.withLockedValue { state in
            switch state.sfu.status {
                case .idle, .connecting(attempt: 0): return .connecting
                case .connecting(let attempt): return .reconnecting(attempt: attempt)
                case .ready: return .ready
            }
        }
    }

    /// Members a link reaches now.
    func connectedMemberNodes(of topic: Data) -> [UUID] {
        state.withLockedValue { state in
            state.membership.members(of: topic).filter { state.carrier(of: $0.main) != nil }.map(\.nodeID)
        }
    }

    /// True when the SFU or some member can take a publish for `topic`.
    func canDeliver(to topic: Data) -> Bool {
        state.withLockedValue { state in
            KeepTalkingIrohDelivery.route(
                state.policy,
                sfuUsable: state.sfuUsable,
                members: state.membership.members(of: topic).count
            ) != nil
        }
    }

    /// True when some member of `topic` is reached without the relay (a
    /// direct IP path or Bluetooth).
    func hasDirectMember(in topic: Data) -> Bool {
        let connections = state.withLockedValue { state in
            state.membership.members(of: topic).compactMap { member in
                state.carrier(of: member.main).flatMap { state.io[$0]?.connection }
            }
        }
        return connections.contains { connection in
            connection.paths().contains { $0.isSelected && !$0.isRelay }
        }
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
                if let carrier = new?.carrier, let doorbell = state.io[carrier]?.doorbell {
                    doorbells.append(doorbell)
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
        case up(KeepTalkingIrohContextTransport?, UUID)
        case down(KeepTalkingIrohContextTransport?, UUID)
        case rerouted(KeepTalkingIrohContextTransport?, UUID)
    }

    func notifyAllContexts(_ body: (KeepTalkingIrohContextTransport) -> Void) {
        let sinks = state.withLockedValue { $0.attachments.values.compactMap(\.sink) }
        sinks.forEach(body)
    }

    /// Finishes a link's doorbell, cancels its tasks and closes its
    /// connection.
    static func tearDown(_ io: LinkIO, reason: String) {
        io.doorbell?.finish()
        io.tasks.forEach { $0.cancel() }
        try? io.connection?.close(errorCode: 0, reason: Data(reason.utf8))
    }

    // MARK: - Log

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
        /// Rung when the SFU queue has frames; set while a session is up.
        var doorbell: AsyncStream<Void>.Continuation?
        var suspended = false
        var resolvedID: String?
        var attempts = 0
        var connectLatency: Duration?
        var connectedSince: Date?
        /// When the session's current write started; nil while idle.
        var writingSince: Instant?
        var skippedFrames = 0
        /// Snapshot chunks received so far, per topic.
        var pendingSnapshots: [Data: [KeepTalkingIrohSFUFrame.Member]] = [:]
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
        /// Bluetooth ids read from nearby devices → their device id.
        var nearby: [Data: String] = [:]
        /// Nearby ids whose hello opened none of our contexts; forgotten
        /// when we attach another.
        var strangers: Set<Data> = []
        var probing = false
        var probeRetryAt: [String: Instant] = [:]
    }

    struct Attachment {
        weak var sink: KeepTalkingIrohContextTransport?
        let topic: KeepTalkingIrohTopic
        let nodeID: UUID
        let blob: Data
        var meshPublished = 0
        var sfuPublished = 0
        var meshReceived = 0
        var sfuReceived = 0
        var sfuDatagramsSent = 0
        var sfuDatagramsReceived = 0

        init(sink: KeepTalkingIrohContextTransport, topic: KeepTalkingIrohTopic, nodeID: UUID, blob: Data) {
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

    /// The iroh side of a link: its connection once up, the doorbell its
    /// pump waits on, and its tasks.
    struct LinkIO {
        var connection: Connection?
        var doorbell: AsyncStream<Void>.Continuation?
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
        var sfu = SFUState()
        var bluetooth = BluetoothState()
        var droppedFrames = 0
        var events: [KeepTalkingIrohInstruments.Event] = []
        var nextEventID = 0

        var sfuUsable: Bool {
            sfu.status == .ready && sfu.doorbell != nil && !sfu.suspended
        }

        var connectedLinks: [Data] {
            table.links.filter(\.value.isConnected).map(\.key)
        }

        /// A member, or a nearby device whose hello we haven't seen refused.
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

        /// The network gate's input: the SFU is unusable, or a member that
        /// announced a Bluetooth id has no working network link.
        var networkFailing: Bool {
            !sfuUsable
                || membership.allMains.contains { main in
                    membership.bluetoothID(of: main) != nil && !table.isCarrying(main)
                }
        }

        /// Queues a peer frame for `main`; returns its carrier's doorbell.
        mutating func enqueue(_ frame: Data, forMember main: Data) -> [AsyncStream<Void>.Continuation] {
            outbound.enqueue(frame, for: main)
            guard let carrier = carrier(of: main), let doorbell = io[carrier]?.doorbell else { return [] }
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
                if !membership.allMains.contains(id) { outbound.remove(id) }
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
#endif
