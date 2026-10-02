import Foundation
import Testing

@testable import KeepTalkingSDK

private struct FakeAttachFailure: Error {}

private struct Fixture {
    let client: KeepTalkingClient
    let multiplexer: FakeMultiplexer
    let lifecycle: SignalRecorder<KeepTalkingClientLifecycle>
    let nodeID: UUID
    let contextID: UUID

    var phases: [KeepTalkingClientLifecycle.Phase] { lifecycle.snapshot.map(\.phase) }
    var causes: [KeepTalkingClientLifecycle.Cause] { lifecycle.snapshot.map(\.cause) }
    var attachment: FakeAttachment? { multiplexer.current }
}

/// Every recorder starts with the replayed initial value:
/// `idle` / `.initial` at index 0.
private func makeFixture(
    multiplexer: FakeMultiplexer = FakeMultiplexer()
) async throws -> Fixture {
    let nodeID = UUID()
    let contextID = UUID()
    let client = KeepTalkingClient(
        config: KeepTalkingConfig(contextID: contextID, node: nodeID),
        transport: multiplexer.transport,
        localStore: try await KeepTalkingInMemoryStore.make()
    )
    let lifecycle = SignalRecorder<KeepTalkingClientLifecycle>()
    client.lifecycle.observe { lifecycle.record($0) }
    await lifecycle.waitForCount(1)
    return Fixture(client: client, multiplexer: multiplexer, lifecycle: lifecycle, nodeID: nodeID, contextID: contextID)
}

private let ready = KeepTalkingTransportStatus(state: .ready, path: .sfu)

struct ClientLifecycleSignalTests {
    @Test("connect attaches the context's room and publishes connecting then connected")
    func connectSequence() async throws {
        let fixture = try await makeFixture()

        try await fixture.client.connect()
        #expect(fixture.client.lifecycle.current.phase == .connected)

        await fixture.lifecycle.waitForCount(3)
        #expect(fixture.phases == [.idle, .connecting, .connected])
        #expect(fixture.causes == [.initial, .connectRequested, .connected])
        #expect(fixture.lifecycle.snapshot[1].transport.state == .connecting)
        #expect(fixture.lifecycle.snapshot.last?.transport == ready)

        let room = try #require(fixture.attachment?.room)
        #expect(room.contextID == fixture.contextID)
        #expect(room.nodeID == fixture.nodeID)
        // The room is addressed by the context's own secret.
        #expect(room.secret == (try await fixture.client.loadGroupChatSecret(for: fixture.contextID)))
        fixture.client.disconnect()
    }

    @Test("a second connect while connected is refused")
    func connectTwice() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await #expect(throws: KeepTalkingClientError.self) {
            try await fixture.client.connect()
        }
        #expect(fixture.multiplexer.attachCount == 1)
        fixture.client.disconnect()
    }

    @Test("a client without a transport refuses to connect and stays idle")
    func unavailableTransport() async throws {
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: UUID(), node: UUID()),
            localStore: try await KeepTalkingInMemoryStore.make()
        )
        await #expect(throws: KeepTalkingTransportError.unavailable) {
            try await client.connect()
        }
        #expect(client.lifecycle.current.phase == .idle)
        #expect(throws: KeepTalkingTransportError.unavailable) {
            try client.sendEnvelope(KeepTalkingP2PPresencePayload(node: UUID()))
        }
    }

    @Test("disconnect detaches at once and reads disconnecting then idle")
    func disconnectSequence() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)

        fixture.client.disconnect()
        #expect(fixture.client.lifecycle.current.phase == .idle)
        #expect(fixture.attachment?.detachCount == 1)

        await fixture.lifecycle.waitForCount(5)
        #expect(fixture.phases == [.idle, .connecting, .connected, .disconnecting, .idle])
        #expect(fixture.causes.suffix(2) == [.disconnectRequested, .tornDown])
        #expect(fixture.lifecycle.snapshot.last?.transport == .offline)
        #expect(throws: KeepTalkingTransportError.notAttached) {
            try fixture.client.sendEnvelope(KeepTalkingP2PPresencePayload(node: UUID()))
        }
    }

    @Test("a redundant disconnect stays silent")
    func redundantDisconnectIsSilent() async throws {
        let fixture = try await makeFixture()

        fixture.client.disconnect()
        await fixture.lifecycle.settle()
        #expect(fixture.phases == [.idle])

        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        fixture.client.disconnect()
        fixture.client.disconnect()
        await fixture.lifecycle.settle()
        #expect(fixture.phases == [.idle, .connecting, .connected, .disconnecting, .idle])
        #expect(fixture.attachment?.detachCount == 1)
    }

    @Test("a failed attach leaves the client idle with the failure")
    func attachFailure() async throws {
        let multiplexer = FakeMultiplexer()
        multiplexer.attachError = FakeAttachFailure()
        let fixture = try await makeFixture(multiplexer: multiplexer)

        await #expect(throws: FakeAttachFailure.self) {
            try await fixture.client.connect()
        }

        await fixture.lifecycle.waitForCount(4)
        #expect(fixture.phases == [.idle, .connecting, .disconnecting, .idle])
        guard case .connectFailed = fixture.causes.last else {
            Issue.record("expected connectFailed, got \(String(describing: fixture.causes.last))")
            return
        }
    }

    @Test("an attach that lands after the connect was cancelled is detached")
    func cancelledConnectDetaches() async throws {
        let gate = TestGate()
        let multiplexer = FakeMultiplexer()
        multiplexer.attachGate = gate
        let fixture = try await makeFixture(multiplexer: multiplexer)

        let connect = Task { try await fixture.client.connect() }
        let deadline = ContinuousClock.now + .seconds(5)
        while multiplexer.attachCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        fixture.client.disconnect()
        await gate.open()
        await #expect(throws: (any Error).self) {
            try await connect.value
        }
        #expect(fixture.client.lifecycle.current.phase == .idle)
        // The attach finished after the disconnect: what it returned is
        // detached, and nothing stays attached.
        let attachment = try #require(multiplexer.current)
        #expect(attachment.detachCount == 1)
        #expect(throws: KeepTalkingTransportError.notAttached) {
            try fixture.client.sendEnvelope(KeepTalkingP2PPresencePayload(node: UUID()))
        }
    }

    @Test("a new secret moves a live client to its new room without passing through idle")
    func secretChangeReattaches() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let first = try #require(fixture.attachment)

        let secret = Data(repeating: 7, count: 32)
        try await fixture.client.setGroupChatSecret(secret, for: fixture.contextID)

        await fixture.lifecycle.waitForCount(5)
        await fixture.lifecycle.settle()
        #expect(fixture.phases == [.idle, .connecting, .connected, .connecting, .connected])
        #expect(first.detachCount == 1)
        #expect(fixture.multiplexer.attachCount == 2)
        #expect(fixture.attachment?.room.secret == secret)
        fixture.client.disconnect()
    }

    @Test("status reports move the lifecycle while connected, and are ignored after")
    func statusChanges() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let attachment = try #require(fixture.attachment)

        let degraded = KeepTalkingTransportStatus(state: .degraded, path: .relay)
        attachment.report(degraded)
        await fixture.lifecycle.waitForCount(4)
        var last = try #require(fixture.lifecycle.snapshot.last)
        #expect(last.phase == .connected)
        #expect(last.transport == degraded)
        #expect(last.cause == .transportChanged)

        let direct = KeepTalkingTransportStatus(state: .ready, path: .direct)
        attachment.report(direct)
        await fixture.lifecycle.waitForCount(5)
        last = try #require(fixture.lifecycle.snapshot.last)
        #expect(last.transport == direct)

        // Same status again: nothing to report.
        attachment.report(direct)
        await fixture.lifecycle.settle()
        #expect(fixture.lifecycle.snapshot.count == 5)

        fixture.client.disconnect()
        await fixture.lifecycle.waitForCount(7)
        attachment.report(ready)
        await fixture.lifecycle.settle()
        #expect(fixture.lifecycle.snapshot.count == 7)
        #expect(fixture.client.lifecycle.current.phase == .idle)
    }

    @Test("presence follows reachability edges, the liveness sweep, and disconnect")
    func presence() async throws {
        let fixture = try await makeFixture()
        let presence = SignalRecorder<KeepTalkingClientPresence>()
        fixture.client.presence.observe { presence.record($0) }
        await presence.waitForCount(1)
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let attachment = try #require(fixture.attachment)

        let peer = UUID()
        let start = Date()
        attachment.emit(.peerConnected(peer))
        await presence.waitForCount(2)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [peer], change: .online(peer)))
        #expect(fixture.client.isNodeOnline(peer))

        // Aged out of the liveness window: the sweep reports offline.
        fixture.client.connection.sweepPresence(now: start.addingTimeInterval(41))
        await presence.waitForCount(3)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [], change: .offline(peer)))

        // Seen again without an edge: the sweep reports online.
        let later = start.addingTimeInterval(60)
        _ = fixture.client.livenessState.observePresence(from: peer, echoCooldown: 0, now: later)
        fixture.client.connection.sweepPresence(now: later)
        await presence.waitForCount(4)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [peer], change: .online(peer)))

        fixture.client.disconnect()
        await presence.waitForCount(5)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [], change: .reset))
        #expect(!fixture.client.isNodeOnline(peer))
    }

    @Test("a heartbeat from a member counts as reachability; our own heartbeat goes out on ready")
    func presenceHeartbeats() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let attachment = try #require(fixture.attachment)

        let peer = UUID()
        attachment.emit(.envelope(KeepTalkingP2PPresencePayload(node: peer), from: nil))
        let deadline = ContinuousClock.now + .seconds(5)
        while !fixture.client.isNodeOnline(peer), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.client.isNodeOnline(peer))

        attachment.emit(.readyToSend)
        let ours = attachment.envelopes.compactMap { $0 as? KeepTalkingP2PPresencePayload }
        #expect(ours.contains { $0.node == fixture.nodeID })
        fixture.client.disconnect()
    }

    @Test("events from a detached attachment are dropped")
    func staleEventsDropped() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let attachment = try #require(fixture.attachment)
        fixture.client.disconnect()

        let peer = UUID()
        attachment.emit(.peerConnected(peer))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.client.isNodeOnline(peer))
    }

    @Test("transport stats are sampled while connected and published only on change")
    func transportStatsSampling() async throws {
        let fixture = try await makeFixture()
        let stats = SignalRecorder<KeepTalkingRuntimeStats>()
        fixture.client.transportStats.observe { stats.record($0) }
        await stats.waitForCount(1)
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        let baseline = stats.snapshot.count

        try fixture.client.sendEnvelope(KeepTalkingP2PPresencePayload(node: UUID()))
        await stats.waitForCount(baseline + 1)
        #expect(stats.snapshot.last?.envelopesSent == fixture.attachment?.envelopes.count)

        let settled = stats.snapshot.count
        try await Task.sleep(for: .seconds(1.5))
        #expect(stats.snapshot.count == settled)
        fixture.client.disconnect()
    }

    @Test("a lifecycle values stream ends when the client is released")
    func streamEndsWithClient() async throws {
        var client: KeepTalkingClient? = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: UUID(), node: UUID()),
            transport: FakeMultiplexer().transport,
            localStore: try await KeepTalkingInMemoryStore.make()
        )
        let stream = client!.lifecycle.values
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        client = nil

        #expect(await withTimeout { await consumer.value } == 1)
    }
}
