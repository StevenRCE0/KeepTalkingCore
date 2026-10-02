import Foundation

/// Peer-link bookkeeping without the iroh objects: whose turn it is to dial,
/// which dial attempt may fill a slot, which connection is current, path
/// loss, redial backoff and hello pacing. Pure, so it is unit-tested.
///
/// iroh calls can't be cancelled from Swift, so a dial or accept may finish
/// after the host stopped wanting it. Every dial owns its slot through a
/// token, and `install` refuses a connection whose slot is gone; the host
/// closes whatever was refused.
struct KeepTalkingIrohLinkTable: Sendable {
    typealias Instant = SuspendingClock.Instant

    enum Kind: String, Sendable { case network, bluetooth }
    enum Side: String, Sendable { case dialed, accepted }

    struct Link: Sendable {
        let kind: Kind
        var side: Side
        /// Set while a dial attempt owns this slot.
        var dialToken: UInt64?
        /// The current connection's stable id; nil while dialing.
        var stableID: UInt64?
        /// Every path of the connection closed: it carries nothing until one
        /// reopens or QUIC gives up on it.
        var pathless = false
        var connectedAt: Instant?
        var lastHelloAt: Instant?
        var dialAttempts = 0
        var connectLatency: Duration?
        var timeToDirect: Duration?
        var framesSent = 0
        var framesReceived = 0
        var bytesSent = 0
        var bytesReceived = 0
        var datagramsSent = 0
        var datagramsReceived = 0

        var isConnected: Bool { stableID != nil }
    }

    enum Install: Equatable, Sendable {
        case installed(replaced: UInt64?)
        case refused
    }

    struct Closed: Equatable, Sendable {
        /// Dial again on this kind: we dialed it and it's still wanted.
        let redial: Kind?
    }

    /// A connection shorter than this counts as a failure for redial backoff.
    static let shortLived: Duration = .seconds(10)
    static let maxBackoff: Duration = .seconds(60)

    private(set) var links: [Data: Link] = [:]
    private var backoff: [Data: (failures: Int, until: Instant)] = [:]
    private var lastToken: UInt64 = 0

    /// Whose turn it is: on the network the lower id dials; over Bluetooth
    /// the higher one, since `iroh-ble-transport` keeps the connection whose
    /// central holds the higher id.
    static func shouldDial(_ remote: Data, kind: Kind, myID: Data) -> Bool {
        kind == .network ? myID.lexicographicallyPrecedes(remote) : remote.lexicographicallyPrecedes(myID)
    }

    func isCarrying(_ id: Data) -> Bool {
        links[id].map { $0.isConnected && !$0.pathless } ?? false
    }

    func isCurrent(_ id: Data, stableID: UInt64) -> Bool {
        links[id]?.stableID == stableID
    }

    func ownsDial(_ id: Data, token: UInt64) -> Bool {
        links[id]?.dialToken == token && links[id]?.stableID == nil
    }

    /// Opens a dial slot when it's our turn, nothing is there and backoff
    /// allows; returns the attempt's token.
    mutating func beginDial(to id: Data, kind: Kind, myID: Data, now: Instant) -> UInt64? {
        guard links[id] == nil, Self.shouldDial(id, kind: kind, myID: myID) else { return nil }
        if let wait = backoff[id], wait.until > now { return nil }
        lastToken &+= 1
        var link = Link(kind: kind, side: .dialed)
        link.dialToken = lastToken
        links[id] = link
        return lastToken
    }

    mutating func noteDialAttempt(_ id: Data, token: UInt64) {
        guard ownsDial(id, token: token) else { return }
        links[id]?.dialAttempts += 1
    }

    /// The dial attempt gave up; frees its slot.
    mutating func endDial(_ id: Data, token: UInt64) {
        if ownsDial(id, token: token) { links[id] = nil }
    }

    /// Records a connection. A dialed one needs its slot still waiting on
    /// `token`; an accepted one replaces whatever is there, since the peer
    /// reconnected.
    mutating func install(
        _ id: Data,
        kind: Kind,
        side: Side,
        stableID: UInt64,
        token: UInt64?,
        now: Instant,
        latency: Duration
    ) -> Install {
        let previous = links[id]
        if let previous, previous.kind != kind { return .refused }
        if side == .dialed {
            guard let token, ownsDial(id, token: token) else { return .refused }
        }
        var link = Link(kind: kind, side: side)
        link.stableID = stableID
        link.connectedAt = now
        link.connectLatency = latency
        link.dialAttempts = previous?.dialAttempts ?? 0
        links[id] = link
        return .installed(replaced: previous?.stableID)
    }

    /// The connection `stableID` closed; nil when it was no longer current.
    /// A short-lived connection pushes the next dial back.
    mutating func closed(_ id: Data, stableID: UInt64, now: Instant, wanted: Bool) -> Closed? {
        guard let link = links[id], link.stableID == stableID else { return nil }
        links[id] = nil
        let lived = link.connectedAt.map { now - $0 } ?? .zero
        if lived < Self.shortLived {
            let failures = (backoff[id]?.failures ?? 0) + 1
            let delay = min(Duration.seconds(1 << min(failures, 6)), Self.maxBackoff)
            backoff[id] = (failures, now + delay)
        } else {
            backoff[id] = nil
        }
        return Closed(redial: link.side == .dialed && wanted ? link.kind : nil)
    }

    /// Removes a link outright; returns it.
    @discardableResult
    mutating func remove(_ id: Data) -> Link? {
        links.removeValue(forKey: id)
    }

    /// Returns whether it changed.
    mutating func setPathless(_ id: Data, stableID: UInt64, _ pathless: Bool) -> Bool {
        guard isCurrent(id, stableID: stableID), links[id]?.pathless != pathless else { return false }
        links[id]?.pathless = pathless
        return true
    }

    /// Whether to take in a hello now; at most one per `interval` per link.
    mutating func admitHello(_ id: Data, now: Instant, interval: Duration) -> Bool {
        guard links[id]?.isConnected == true else { return false }
        if let last = links[id]?.lastHelloAt, now - last < interval { return false }
        links[id]?.lastHelloAt = now
        return true
    }

    mutating func update(_ id: Data, _ body: (inout Link) -> Void) {
        guard var link = links[id] else { return }
        body(&link)
        links[id] = link
    }

    /// Accepted links older than `grace` whose endpoint `wanted` rejects:
    /// they never showed a shared context.
    func unproven(now: Instant, grace: Duration, wanted: (Data) -> Bool) -> [Data] {
        links.compactMap { id, link in
            guard link.side == .accepted, let since = link.connectedAt, now - since >= grace, !wanted(id)
            else { return nil }
            return id
        }
    }

    mutating func pruneBackoff(now: Instant) {
        backoff = backoff.filter { now - $0.value.until < Self.maxBackoff * 5 }
    }

    /// The network changed: what failed on the old one may work now, so
    /// every endpoint may be dialled again at once.
    mutating func clearBackoff() {
        backoff = [:]
    }
}
