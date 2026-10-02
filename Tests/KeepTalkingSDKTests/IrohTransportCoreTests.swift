import Foundation
import Testing

@_spi(TransportLab) @testable import KeepTalkingSDK

private func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

private let start = SuspendingClock.now

/// Membership: who is in each context, learned only from sealed presence,
/// with the SFU roster as discovery and hellos as each peer's own word.
struct IrohMembershipTests {
    typealias Presence = KeepTalkingIrohPresenceSeal.Presence

    private let secret = Data(repeating: 7, count: 32)
    private let contextID = UUID()
    private var topic: KeepTalkingIrohTopic { KeepTalkingIrohTopic(contextID: contextID, secret: secret) }
    private let me = id(0x01)
    private let alice = UUID()
    private let bob = UUID()

    private func membership() -> KeepTalkingIrohMembership {
        var membership = KeepTalkingIrohMembership()
        membership.attach(topic, nodeID: UUID(), secret: secret)
        return membership
    }

    @Test("SFU presence must name the id the SFU reported; our own echo is ignored")
    func sfuPresence() {
        var membership = membership()
        let presence = Presence(nodeID: alice, endpointID: id(0x10))
        #expect(
            membership.learn(presence, in: topic.topic, from: .sfu(reportedID: id(0x11)), myID: me, now: start)
                == .rejected("presence id differs from the SFU's")
        )
        #expect(
            membership.learn(presence, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
                == .member(nodeID: alice, main: id(0x10), isNew: true)
        )
        #expect(
            membership.learn(presence, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
                == .member(nodeID: alice, main: id(0x10), isNew: false)
        )
        let echo = Presence(nodeID: UUID(), endpointID: me)
        #expect(membership.learn(echo, in: topic.topic, from: .sfu(reportedID: me), myID: me, now: start) == .ourselves)
        #expect(membership.nodeID(for: id(0x10), in: topic.topic) == alice)
    }

    @Test("A node back under a new network id replaces its old one")
    func newNetworkID() {
        var membership = membership()
        let old = Presence(nodeID: alice, endpointID: id(0x10), bluetoothEndpointID: id(0xB0))
        let new = Presence(nodeID: alice, endpointID: id(0x11), bluetoothEndpointID: id(0xB0))
        _ = membership.learn(old, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
        _ = membership.learn(new, in: topic.topic, from: .sfu(reportedID: id(0x11)), myID: me, now: start)
        #expect(membership.allMains == [id(0x11)])
        #expect(membership.bluetoothID(of: id(0x11)) == id(0xB0))
        #expect(membership.mains(for: id(0xB0)) == [id(0x11)])
    }

    @Test("A Bluetooth hello can't rebind a Bluetooth id the member gave over the network")
    func bluetoothRebind() {
        var membership = membership()
        let vouched = Presence(nodeID: alice, endpointID: id(0x10), bluetoothEndpointID: id(0xB0))
        _ = membership.learn(vouched, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
        // Another member seals alice's network id with its own Bluetooth id.
        let forged = Presence(nodeID: alice, endpointID: id(0x10), bluetoothEndpointID: id(0xBF))
        let learned = membership.learn(forged, in: topic.topic, from: .bluetoothLink(id(0xBF)), myID: me, now: start)
        guard case .rejected = learned else {
            Issue.record("expected the rebind to be rejected, got \(learned)")
            return
        }
        #expect(membership.bluetoothID(of: id(0x10)) == id(0xB0))
        // The blob must also name the Bluetooth link it arrived on.
        let mismatched = Presence(nodeID: bob, endpointID: id(0x20), bluetoothEndpointID: id(0xB2))
        guard
            case .rejected = membership.learn(
                mismatched,
                in: topic.topic,
                from: .bluetoothLink(id(0xB3)),
                myID: me,
                now: start
            )
        else {
            Issue.record("expected a Bluetooth id mismatch to be rejected")
            return
        }
    }

    @Test("Offline, a Bluetooth hello makes an unknown node a member, kept only until retention runs out")
    func offlineMember() {
        var membership = membership()
        let presence = Presence(nodeID: bob, endpointID: id(0x20), bluetoothEndpointID: id(0xB2))
        #expect(
            membership.learn(presence, in: topic.topic, from: .bluetoothLink(id(0xB2)), myID: me, now: start)
                == .member(nodeID: bob, main: id(0x20), isNew: true)
        )
        #expect(membership.isMember(id(0xB2)))
        // Reached over Bluetooth: the clock restarts.
        let later = start + .seconds(600)
        #expect(membership.sweep(now: later, retention: .seconds(300), reachable: { $0 == id(0xB2) }).isEmpty)
        // Unreached for the retention window: gone.
        let departures = membership.sweep(
            now: later + .seconds(301), retention: .seconds(300), reachable: { _ in false })
        #expect(departures.map(\.nodeID) == [bob])
        #expect(Set(departures.flatMap(\.unlink)) == [id(0x20), id(0xB2)])
        #expect(!membership.isMember(id(0x20)))
    }

    @Test("The SFU dropping a member keeps it while reachable or on Bluetooth, drops it otherwise")
    func sfuDropped() {
        var membership = membership()
        let withBluetooth = Presence(nodeID: alice, endpointID: id(0x10), bluetoothEndpointID: id(0xB0))
        let networkOnly = Presence(nodeID: bob, endpointID: id(0x20))
        _ = membership.learn(withBluetooth, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
        _ = membership.learn(networkOnly, in: topic.topic, from: .sfu(reportedID: id(0x20)), myID: me, now: start)

        #expect(
            membership.sfuDropped(
                id(0x10), in: topic.topic, now: start, bluetoothUsable: true, reachable: { _ in false })
                == nil
        )
        #expect(
            membership.sfuDropped(
                id(0x20), in: topic.topic, now: start, bluetoothUsable: true, reachable: { $0 == id(0x20) })
                == nil
        )
        #expect(
            membership.contexts[topic.topic]?.unlisted.keys.sorted { $0.lexicographicallyPrecedes($1) } == [
                id(0x10), id(0x20),
            ])
        let dropped = membership.sfuDropped(
            id(0x20),
            in: topic.topic,
            now: start,
            bluetoothUsable: true,
            reachable: { _ in false }
        )
        #expect(dropped == .init(topic: topic.topic, nodeID: bob, unlink: [id(0x20)]))
        // Presence through the SFU lists the member again.
        _ = membership.learn(withBluetooth, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
        #expect(membership.contexts[topic.topic]?.unlisted.isEmpty == true)
    }

    @Test("A hello that no longer lists a context means the peer left it")
    func helloLeaves() {
        var membership = membership()
        let otherSecret = Data(repeating: 9, count: 32)
        let other = KeepTalkingIrohTopic(contextID: UUID(), secret: otherSecret)
        membership.attach(other, nodeID: UUID(), secret: otherSecret)
        let presence = Presence(nodeID: alice, endpointID: id(0x10), bluetoothEndpointID: id(0xB0))
        _ = membership.learn(presence, in: topic.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)
        _ = membership.learn(presence, in: other.topic, from: .sfu(reportedID: id(0x10)), myID: me, now: start)

        // Over Bluetooth, alice lists only `topic`.
        let departures = membership.helloListed([topic.topic], from: id(0xB0))
        #expect(departures.map(\.topic) == [other.topic])
        #expect(membership.nodeID(for: id(0x10), in: topic.topic) == alice)
        #expect(membership.nodeID(for: id(0x10), in: other.topic) == nil)
        // The Bluetooth id is still used in `topic`, but nothing in `other`
        // keeps it, so the departure names it for unlinking; the host only
        // unlinks ids no context wants.
        #expect(departures.first?.unlink.contains(id(0x10)) == true)
        #expect(membership.isMember(id(0xB0)))
    }

    @Test("Forgetting one member keeps a Bluetooth id another member still uses")
    func sharedBluetoothID() {
        var context = KeepTalkingIrohMembership.Context(
            topic: topic,
            nodeID: UUID(),
            key: .init(contextID: contextID, secret: secret)
        )
        context.members = [id(0x10): alice, id(0x11): bob]
        context.bluetoothOf = [id(0x10): id(0xB0), id(0x11): id(0xB0)]
        #expect(context.forget(id(0x10)) == [id(0x10)])
        #expect(context.forget(id(0x11)) == [id(0x11), id(0xB0)])
    }
}

/// Link bookkeeping: dial turns, tokens that make late connections lose,
/// redial backoff, path loss and hello pacing.
struct IrohLinkTableTests {
    private let low = id(0x10)
    private let high = id(0xF0)

    @Test("The lower id dials on the network, the higher over Bluetooth")
    func dialTurns() {
        #expect(KeepTalkingIrohLinkTable.shouldDial(high, kind: .network, myID: low))
        #expect(!KeepTalkingIrohLinkTable.shouldDial(low, kind: .network, myID: high))
        #expect(KeepTalkingIrohLinkTable.shouldDial(low, kind: .bluetooth, myID: high))
        #expect(!KeepTalkingIrohLinkTable.shouldDial(high, kind: .bluetooth, myID: low))
    }

    @Test("A connection whose dial no longer owns the slot is refused")
    func lateDial() throws {
        var table = KeepTalkingIrohLinkTable()
        let tokenSlot = table.beginDial(to: high, kind: .network, myID: low, now: start)
        let token = try #require(tokenSlot)
        let second = table.beginDial(to: high, kind: .network, myID: low, now: start)
        #expect(second == nil)
        table.endDial(high, token: token)
        let late = table.install(
            high, kind: .network, side: .dialed, stableID: 1, token: token, now: start, latency: .zero)
        #expect(late == .refused)
        let freshSlot = table.beginDial(to: high, kind: .network, myID: low, now: start)
        let fresh = try #require(freshSlot)
        let stale = table.install(
            high, kind: .network, side: .dialed, stableID: 2, token: token, now: start, latency: .zero)
        #expect(stale == .refused)
        let current = table.install(
            high, kind: .network, side: .dialed, stableID: 2, token: fresh, now: start, latency: .zero)
        #expect(current == .installed(replaced: nil))
        #expect(table.isCarrying(high))
    }

    @Test("An accepted connection replaces the current one")
    func acceptReplaces() {
        var table = KeepTalkingIrohLinkTable()
        let first = table.install(
            low, kind: .network, side: .accepted, stableID: 1, token: nil, now: start, latency: .zero)
        #expect(first == .installed(replaced: nil))
        let second = table.install(
            low, kind: .network, side: .accepted, stableID: 2, token: nil, now: start, latency: .zero)
        #expect(second == .installed(replaced: 1))
        let stale = table.closed(low, stableID: 1, now: start, wanted: true)
        #expect(stale == nil)
        #expect(table.isCurrent(low, stableID: 2))
    }

    @Test("Short-lived connections push the redial back; long-lived ones reset it")
    func backoff() throws {
        var table = KeepTalkingIrohLinkTable()
        let tokenSlot = table.beginDial(to: high, kind: .network, myID: low, now: start)
        let token = try #require(tokenSlot)
        _ = table.install(high, kind: .network, side: .dialed, stableID: 1, token: token, now: start, latency: .zero)
        let closed = table.closed(high, stableID: 1, now: start + .seconds(1), wanted: true)
        #expect(closed == .init(redial: .network))
        let tooSoon = table.beginDial(to: high, kind: .network, myID: low, now: start + .seconds(2))
        #expect(tooSoon == nil)
        let retrySlot = table.beginDial(to: high, kind: .network, myID: low, now: start + .seconds(4))
        let retry = try #require(retrySlot)
        _ = table.install(
            high, kind: .network, side: .dialed, stableID: 2, token: retry, now: start + .seconds(4), latency: .zero)
        _ = table.closed(high, stableID: 2, now: start + .seconds(60), wanted: false)
        let afterLongLink = table.beginDial(to: high, kind: .network, myID: low, now: start + .seconds(60))
        #expect(afterLongLink != nil)
    }

    @Test("Only a dialed, still-wanted link redials")
    func redial() {
        var table = KeepTalkingIrohLinkTable()
        _ = table.install(low, kind: .network, side: .accepted, stableID: 1, token: nil, now: start, latency: .zero)
        let closed = table.closed(low, stableID: 1, now: start + .seconds(30), wanted: true)
        #expect(closed == .init(redial: nil))
    }

    @Test("A link without paths doesn't carry")
    func pathless() {
        var table = KeepTalkingIrohLinkTable()
        _ = table.install(low, kind: .network, side: .accepted, stableID: 1, token: nil, now: start, latency: .zero)
        let lost = table.setPathless(low, stableID: 1, true)
        let again = table.setPathless(low, stableID: 1, true)
        #expect(lost && !again)
        #expect(!table.isCarrying(low))
        let wrongConnection = table.setPathless(low, stableID: 9, false)
        let back = table.setPathless(low, stableID: 1, false)
        #expect(!wrongConnection && back)
        #expect(table.isCarrying(low))
    }

    @Test("Hellos are paced per link, and accepted links that never prove anything expire")
    func helloAndGrace() {
        var table = KeepTalkingIrohLinkTable()
        _ = table.install(low, kind: .bluetooth, side: .accepted, stableID: 1, token: nil, now: start, latency: .zero)
        let first = table.admitHello(low, now: start, interval: .seconds(1))
        let tooSoon = table.admitHello(low, now: start + .milliseconds(500), interval: .seconds(1))
        let later = table.admitHello(low, now: start + .seconds(2), interval: .seconds(1))
        let unknown = table.admitHello(high, now: start, interval: .seconds(1))
        #expect(first && !tooSoon && later && !unknown)
        #expect(table.unproven(now: start + .seconds(10), grace: .seconds(30), wanted: { _ in false }).isEmpty)
        #expect(table.unproven(now: start + .seconds(31), grace: .seconds(30), wanted: { _ in false }) == [low])
        #expect(table.unproven(now: start + .seconds(31), grace: .seconds(30), wanted: { _ in true }).isEmpty)
    }
}

/// Queues, route choice and the network gate.
struct IrohDeliveryTests {
    @Test("A full queue drops its oldest frames; drains come in batches")
    func outbound() {
        var outbound = KeepTalkingIrohOutbound(budget: 10)
        let key = id(1)
        #expect(outbound.enqueue(Data(count: 4), for: key) == 0)
        #expect(outbound.enqueue(Data(count: 4), for: key) == 0)
        #expect(outbound.enqueue(Data([9, 9, 9, 9]), for: key) == 1)
        #expect(outbound.bytes(for: key) == 8)
        #expect(outbound.dropped(for: key) == 1)
        #expect(!outbound.fits(4, for: key))
        outbound.prepend([Data([7])], for: key)
        #expect(outbound.drain(key, upTo: 5) == [Data([7]), Data(count: 4)])
        #expect(outbound.drain(key) == [Data([9, 9, 9, 9])])
        #expect(outbound.isEmpty(key))
        #expect(outbound.drain(key) == [])
    }

    @Test(
        "Routes follow the policy and fall back to whichever exists",
        arguments: [
            (KeepTalkingIrohDeliveryPolicy.automatic(sfuAtMembers: 4), true, 2, KeepTalkingIrohRoute.mesh),
            (.automatic(sfuAtMembers: 4), true, 4, .sfu),
            (.automatic(sfuAtMembers: 4), false, 4, .mesh),
            (.automatic(sfuAtMembers: 4), true, 0, .sfu),
            (.preferMesh, true, 1, .mesh),
            (.preferMesh, true, 0, .sfu),
            (.preferSFU, true, 3, .sfu),
            (.preferSFU, false, 3, .mesh),
        ] as [(KeepTalkingIrohDeliveryPolicy, Bool, Int, KeepTalkingIrohRoute)]
    )
    func routes(policy: KeepTalkingIrohDeliveryPolicy, sfuUsable: Bool, members: Int, route: KeepTalkingIrohRoute) {
        #expect(KeepTalkingIrohDelivery.route(policy, sfuUsable: sfuUsable, members: members) == route)
    }

    @Test("No SFU and no known member: no route")
    func noRoute() {
        #expect(KeepTalkingIrohDelivery.route(.standard, sfuUsable: false, members: 0) == nil)
    }

    @Test("The network gate opens after a sustained failure and closes after sustained health")
    func gate() {
        var gate = KeepTalkingIrohNetworkGate(openAfter: .seconds(3), closeAfter: .seconds(30))
        #expect(gate.update(failing: true, now: start) == nil)
        #expect(gate.update(failing: true, now: start + .seconds(2)) == nil)
        // A healthy blip restarts the count.
        #expect(gate.update(failing: false, now: start + .seconds(2.5)) == nil)
        #expect(gate.update(failing: true, now: start + .seconds(3)) == nil)
        #expect(gate.update(failing: true, now: start + .seconds(6)) == true)
        #expect(gate.isOpen)
        #expect(gate.update(failing: false, now: start + .seconds(7)) == nil)
        #expect(gate.update(failing: false, now: start + .seconds(36)) == nil)
        #expect(gate.update(failing: false, now: start + .seconds(37)) == false)
        #expect(!gate.isOpen)
    }
}
