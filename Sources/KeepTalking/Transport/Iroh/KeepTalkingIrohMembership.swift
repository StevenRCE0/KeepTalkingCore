import Foundation

/// Who is in each attached context, learned only from sealed presence —
/// through the SFU, or from a hello on a peer link. Kept apart from links and
/// iroh so it can be unit-tested.
///
/// - The SFU roster is discovery, not membership: a member the SFU stops
///   listing stays while a link reaches it or Bluetooth may, and goes after
///   `retention` without either (`sweep`).
/// - A hello is a peer's own word on which contexts it is in: a context it
///   no longer lists, it has left.
/// - A node that comes back under a new network id replaces its old one.
/// - A Bluetooth id a member gave over the network (SFU presence, or a
///   hello on a network link) can't be rebound by a hello on a Bluetooth
///   link, so one member can't redirect another's traffic to itself.
struct KeepTalkingIrohMembership: Sendable {
    typealias Instant = SuspendingClock.Instant
    typealias Presence = KeepTalkingIrohPresenceSeal.Presence

    struct Context: Sendable {
        let topic: KeepTalkingIrohTopic
        let nodeID: UUID
        let key: KeepTalkingIrohPresenceSeal.Key
        /// Network endpoint id → node id.
        var members: [Data: UUID] = [:]
        /// Network endpoint id → that member's Bluetooth endpoint id.
        var bluetoothOf: [Data: Data] = [:]
        /// Members whose Bluetooth binding came from their own word over the
        /// network.
        var vouched: Set<Data> = []
        /// Members the SFU doesn't list → since when no link has reached them.
        var unlisted: [Data: Instant] = [:]
        /// The SFU's snapshot for this topic has arrived.
        var joined = false

        /// The network ids `endpointID` stands for here: itself if it's a
        /// member's, otherwise every member whose Bluetooth id it is.
        func mains(for endpointID: Data) -> [Data] {
            if members[endpointID] != nil { return [endpointID] }
            return bluetoothOf.filter { $0.value == endpointID }.map(\.key)
        }

        /// Drops a member; returns the ids no other member here still uses.
        mutating func forget(_ main: Data) -> [Data] {
            members[main] = nil
            vouched.remove(main)
            unlisted[main] = nil
            guard let bluetooth = bluetoothOf.removeValue(forKey: main) else { return [main] }
            return bluetoothOf.values.contains(bluetooth) ? [main] : [main, bluetooth]
        }
    }

    /// How a presence blob reached us; the sealed ids must match it.
    enum Source: Equatable, Sendable {
        /// Through the SFU, which reported this network id as the sender.
        case sfu(reportedID: Data)
        /// In a hello on a network link to this endpoint.
        case networkLink(Data)
        /// In a hello on a Bluetooth link to this endpoint.
        case bluetoothLink(Data)
    }

    enum Learned: Equatable, Sendable {
        case member(nodeID: UUID, main: Data, isNew: Bool)
        /// Our own presence, echoed back.
        case ourselves
        case rejected(String)
    }

    /// Someone who left a context, with the ids to unlink if nothing else
    /// needs them.
    struct Departure: Equatable, Sendable {
        let topic: Data
        let nodeID: UUID
        let unlink: [Data]
    }

    private(set) var contexts: [Data: Context] = [:]

    // MARK: - Attachments

    /// Registers a context; a context already attached keeps its members.
    mutating func attach(_ topic: KeepTalkingIrohTopic, nodeID: UUID, secret: Data) {
        guard contexts[topic.topic] == nil else { return }
        contexts[topic.topic] = Context(
            topic: topic,
            nodeID: nodeID,
            key: KeepTalkingIrohPresenceSeal.Key(contextID: topic.contextID, secret: secret)
        )
    }

    /// Drops a context; returns every endpoint id its members used.
    mutating func detach(_ topic: Data) -> [Data] {
        guard let removed = contexts.removeValue(forKey: topic) else { return [] }
        return Array(removed.members.keys) + Array(removed.bluetoothOf.values)
    }

    mutating func markJoined(_ topic: Data, _ joined: Bool = true) {
        contexts[topic]?.joined = joined
    }

    mutating func markAllUnjoined() {
        for topic in contexts.keys { contexts[topic]?.joined = false }
    }

    // MARK: - Queries

    func nodeID(for endpointID: Data, in topic: Data) -> UUID? {
        guard let context = contexts[topic] else { return nil }
        return context.mains(for: endpointID).lazy.compactMap { context.members[$0] }.first
    }

    /// The network ids `endpointID` stands for, in any context.
    func mains(for endpointID: Data) -> Set<Data> {
        contexts.values.reduce(into: Set<Data>()) { $0.formUnion($1.mains(for: endpointID)) }
    }

    /// `endpointID` is a member's network or Bluetooth id somewhere.
    func isMember(_ endpointID: Data) -> Bool {
        contexts.values.contains { !$0.mains(for: endpointID).isEmpty }
    }

    /// A member's Bluetooth id, from any context that knows one.
    func bluetoothID(of main: Data) -> Data? {
        contexts.values.lazy.compactMap { $0.bluetoothOf[main] }.first
    }

    var bluetoothIDs: Set<Data> {
        contexts.values.reduce(into: Set<Data>()) { $0.formUnion($1.bluetoothOf.values) }
    }

    var allMains: Set<Data> {
        contexts.values.reduce(into: Set<Data>()) { $0.formUnion($1.members.keys) }
    }

    func members(of topic: Data) -> [(main: Data, nodeID: UUID)] {
        (contexts[topic]?.members ?? [:]).map { ($0.key, $0.value) }
    }

    // MARK: - Learning

    /// Takes in a member's presence for `topic`.
    mutating func learn(
        _ presence: Presence,
        in topic: Data,
        from source: Source,
        myID: Data?,
        now: Instant
    ) -> Learned {
        guard var context = contexts[topic] else { return .rejected("not attached") }
        let main = presence.endpointID
        guard main != myID else { return .ourselves }
        switch source {
            case .sfu(let reported):
                guard main == reported else { return .rejected("presence id differs from the SFU's") }
            case .networkLink(let link):
                guard main == link else { return .rejected("presence id differs from the link's") }
            case .bluetoothLink(let link):
                guard presence.bluetoothEndpointID == link else {
                    return .rejected("presence Bluetooth id differs from the link's")
                }
                if context.vouched.contains(main), context.bluetoothOf[main] != link {
                    return .rejected("Bluetooth id contradicts the member's own over the network")
                }
        }
        let isNew = context.members[main] == nil
        for (other, node) in context.members where node == presence.nodeID && other != main {
            _ = context.forget(other)
        }
        context.members[main] = presence.nodeID
        context.bluetoothOf[main] = presence.bluetoothEndpointID
        switch source {
            case .sfu:
                context.vouched.insert(main)
                context.unlisted[main] = nil
            case .networkLink:
                context.vouched.insert(main)
                if isNew { context.unlisted[main] = now }
            case .bluetoothLink:
                if isNew { context.unlisted[main] = now }
        }
        contexts[topic] = context
        return .member(nodeID: presence.nodeID, main: main, isNew: isNew)
    }

    // MARK: - Leaving

    /// The SFU stopped listing `main` in `topic`. It stays while `reachable`
    /// says a link reaches it, or while it has a Bluetooth id and
    /// `bluetoothUsable`; otherwise it leaves now.
    mutating func sfuDropped(
        _ main: Data,
        in topic: Data,
        now: Instant,
        bluetoothUsable: Bool,
        reachable: (Data) -> Bool
    ) -> Departure? {
        guard var context = contexts[topic], let nodeID = context.members[main] else { return nil }
        let bluetooth = context.bluetoothOf[main]
        let keep = reachable(main) || bluetooth.map { bluetoothUsable || reachable($0) } ?? false
        if keep {
            if context.unlisted[main] == nil { context.unlisted[main] = now }
            contexts[topic] = context
            return nil
        }
        let unlink = context.forget(main)
        contexts[topic] = context
        return Departure(topic: topic, nodeID: nodeID, unlink: unlink)
    }

    /// A hello from `endpointID` listed `topics`. Wherever the members that
    /// endpoint stands for are known but their context isn't listed, they
    /// have left it.
    mutating func helloListed(_ topics: Set<Data>, from endpointID: Data) -> [Departure] {
        var departures: [Departure] = []
        for (topic, var context) in contexts where !topics.contains(topic) {
            let mains = context.mains(for: endpointID)
            guard !mains.isEmpty else { continue }
            for main in mains {
                guard let nodeID = context.members[main] else { continue }
                departures.append(Departure(topic: topic, nodeID: nodeID, unlink: context.forget(main)))
            }
            contexts[topic] = context
        }
        return departures
    }

    /// Forgets members the SFU doesn't list that no link has reached for
    /// `retention`; reaching one restarts its clock.
    mutating func sweep(now: Instant, retention: Duration, reachable: (Data) -> Bool) -> [Departure] {
        var departures: [Departure] = []
        for (topic, var context) in contexts where !context.unlisted.isEmpty {
            for (main, since) in context.unlisted {
                if reachable(main) || (context.bluetoothOf[main].map(reachable) ?? false) {
                    context.unlisted[main] = now
                    continue
                }
                guard now - since >= retention, let nodeID = context.members[main] else { continue }
                departures.append(Departure(topic: topic, nodeID: nodeID, unlink: context.forget(main)))
            }
            contexts[topic] = context
        }
        return departures
    }
}
