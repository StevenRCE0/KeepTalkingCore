import Foundation
import Testing

@testable import KeepTalkingSDK

/// A transport that only reports what the tests tell it to.
private final class FakeTransportClient: KeepTalkingTransportClient, @unchecked Sendable {
    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onRawMessage: (@Sendable (String) -> Void)?
    var onPeerConnect: (@Sendable (UUID) -> Void)?
    var onBroadcastReady: (@Sendable () -> Void)?
    var onTransportStateChange: (@Sendable (BroadcastChannelState, KeepTalkingTransportRoute) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    private let lock = NSLock()
    private var state: BroadcastChannelState = .failed
    private var route: KeepTalkingTransportRoute = .sfu
    private var sent = 0
    private var stops = 0
    private var starts = 0
    var startError: (any Error)?
    var startGate: TestGate?

    var stopCount: Int { lock.withLock { stops } }
    var startCount: Int { lock.withLock { starts } }

    func start() throws -> Task<Void, Error> {
        if let startError { throw startError }
        lock.withLock { starts += 1 }
        let gate = startGate
        return Task { [self] in
            if let gate { await gate.wait() }
            try Task.checkCancellation()
            report(.ready, route: .sfu)
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
            state = .failed
            route = .sfu
        }
    }

    /// What `ContextTransport` does after a channel transition.
    func report(_ newState: BroadcastChannelState, route newRoute: KeepTalkingTransportRoute) {
        lock.withLock {
            state = newState
            route = newRoute
        }
        onTransportStateChange?(newState, newRoute)
    }

    func bumpSent() {
        lock.withLock { sent += 1 }
    }

    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        bumpSent()
    }

    func sendBlobData(_ data: Data, targetPeerNodeID: UUID?) throws {}

    func currentRoute() -> KeepTalkingTransportRoute {
        lock.withLock { route }
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        lock.withLock {
            KeepTalkingRuntimeStats(
                sent: sent, received: 0, outboundLabel: nil, outboundState: nil,
                inboundLabel: nil, inboundState: nil, retainedChannels: 0,
                route: route.rawValue
            )
        }
    }

    func broadcastState() -> BroadcastChannelState {
        lock.withLock { state }
    }

    func sendLivenessProbe() {}
    func requestP2PTrial() {}
    func preferReliableRoute(reason: String) {}
    func debug(_ message: String) { onLog?(message) }
}

private struct FakeStartFailure: Error {}

private struct Fixture {
    let client: KeepTalkingClient
    let transport: FakeTransportClient
    let lifecycle: SignalRecorder<KeepTalkingClientLifecycle>
    let nodeID: UUID
    let contextID: UUID

    var phases: [KeepTalkingClientLifecycle.Phase] { lifecycle.snapshot.map(\.phase) }
    var causes: [KeepTalkingClientLifecycle.Cause] { lifecycle.snapshot.map(\.cause) }
}

/// Every recorder starts with the replayed initial value:
/// `idle` / `.initial` at index 0.
private func makeFixture(startError: (any Error)? = nil, startGate: TestGate? = nil) async throws -> Fixture {
    let transport = FakeTransportClient()
    transport.startError = startError
    transport.startGate = startGate
    let nodeID = UUID()
    let contextID = UUID()
    let client = KeepTalkingClient(
        config: KeepTalkingConfig(contextID: contextID, node: nodeID),
        localStore: try await KeepTalkingInMemoryStore.make(),
        transport: transport
    )
    let lifecycle = SignalRecorder<KeepTalkingClientLifecycle>()
    client.lifecycle.observe { lifecycle.record($0) }
    await lifecycle.waitForCount(1)
    return Fixture(client: client, transport: transport, lifecycle: lifecycle, nodeID: nodeID, contextID: contextID)
}

struct ClientLifecycleSignalTests {
    @Test("connect publishes connecting then connected, with a healthy transport")
    func connectSequence() async throws {
        let fixture = try await makeFixture()

        try await fixture.client.connect()
        #expect(fixture.client.lifecycle.current.phase == .connected)

        await fixture.lifecycle.waitForCount(3)
        #expect(fixture.phases == [.idle, .connecting, .connected])
        #expect(fixture.causes == [.initial, .connectRequested, .connected])
        #expect(fixture.lifecycle.snapshot.last?.transport == .healthy)
        #expect(fixture.lifecycle.snapshot.last?.route == .sfu)
        #expect(fixture.lifecycle.snapshot[1].transport == .recovering)
        await fixture.client.disconnectAndWait()
    }

    @Test("disconnectAndWait publishes disconnecting then idle and returns idle")
    func disconnectSequence() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)

        await fixture.client.disconnectAndWait()
        #expect(fixture.client.lifecycle.current.phase == .idle)

        await fixture.lifecycle.waitForCount(5)
        #expect(fixture.phases == [.idle, .connecting, .connected, .disconnecting, .idle])
        #expect(fixture.causes.suffix(2) == [.disconnectRequested, .tornDown])
        #expect(fixture.lifecycle.snapshot.last?.transport == .down)
        #expect(fixture.transport.stopCount == 1)
    }

    @Test("a redundant disconnect stays silent, and overlapping ones publish once")
    func redundantDisconnectIsSilent() async throws {
        let fixture = try await makeFixture()

        fixture.client.disconnect()
        await fixture.client.disconnectAndWait()
        await fixture.lifecycle.settle()
        #expect(fixture.phases == [.idle])

        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)
        async let first: Void = fixture.client.disconnectAndWait()
        async let second: Void = fixture.client.disconnectAndWait()
        _ = await (first, second)
        await fixture.lifecycle.settle()
        #expect(fixture.phases == [.idle, .connecting, .connected, .disconnecting, .idle])
    }

    @Test("a transport that fails to start leaves the client idle with the failure")
    func startFailure() async throws {
        let fixture = try await makeFixture(startError: FakeStartFailure())

        await #expect(throws: FakeStartFailure.self) {
            try await fixture.client.connect()
        }

        await fixture.lifecycle.waitForCount(3)
        #expect(fixture.phases == [.idle, .connecting, .idle])
        guard case .connectFailed = fixture.causes.last else {
            Issue.record("expected connectFailed, got \(String(describing: fixture.causes.last))")
            return
        }
        #expect(fixture.transport.stopCount == 0)
    }

    @Test("cancelling a connect after the transport started tears down with the failure")
    func cancelledConnectTearsDown() async throws {
        let gate = TestGate()
        let fixture = try await makeFixture(startGate: gate)

        let connect = Task { try await fixture.client.connect() }
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.transport.startCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        connect.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) {
            try await connect.value
        }

        await fixture.lifecycle.waitForCount(4)
        #expect(fixture.phases == [.idle, .connecting, .disconnecting, .idle])
        for cause in fixture.causes.suffix(2) {
            guard case .connectFailed = cause else {
                Issue.record("expected connectFailed, got \(cause)")
                continue
            }
        }
        #expect(fixture.transport.stopCount == 1)
    }

    @Test("reestablishTransport bounces without passing through idle")
    func reestablishSkipsIdle() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)

        try await fixture.client.reestablishTransport()

        await fixture.lifecycle.waitForCount(6)
        await fixture.lifecycle.settle()
        #expect(
            fixture.phases == [.idle, .connecting, .connected, .disconnecting, .connecting, .connected]
        )
        #expect(fixture.transport.stopCount == 1)
        #expect(fixture.transport.startCount == 2)
        await fixture.client.disconnectAndWait()
    }

    @Test("transport reports move health and route while connected, and are ignored after")
    func transportChanges() async throws {
        let fixture = try await makeFixture()
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)

        fixture.transport.report(.reconnecting(attempt: 1), route: .sfu)
        await fixture.lifecycle.waitForCount(4)
        var last = try #require(fixture.lifecycle.snapshot.last)
        #expect(last.phase == .connected)
        #expect(last.transport == .recovering)
        #expect(last.cause == .transportChanged)

        fixture.transport.report(.ready, route: .p2p)
        await fixture.lifecycle.waitForCount(5)
        last = try #require(fixture.lifecycle.snapshot.last)
        #expect(last.transport == .healthy)
        #expect(last.route == .p2p)

        // Same values again: nothing to report.
        fixture.transport.report(.ready, route: .p2p)
        await fixture.lifecycle.settle()
        #expect(fixture.lifecycle.snapshot.count == 5)

        await fixture.client.disconnectAndWait()
        await fixture.lifecycle.waitForCount(7)
        fixture.transport.report(.ready, route: .sfu)
        await fixture.lifecycle.settle()
        #expect(fixture.lifecycle.snapshot.count == 7)
        #expect(fixture.client.lifecycle.current.phase == .idle)
    }

    @Test("presence follows the connect edge, the liveness sweep, and teardown")
    func presence() async throws {
        let fixture = try await makeFixture()
        let presence = SignalRecorder<KeepTalkingClientPresence>()
        fixture.client.presence.observe { presence.record($0) }
        await presence.waitForCount(1)
        try await fixture.client.connect()
        await fixture.lifecycle.waitForCount(3)

        let peer = UUID()
        let start = Date()
        _ = fixture.client.livenessState.observePresence(from: peer, echoCooldown: 0, now: start)
        fixture.transport.onPeerConnect?(peer)
        await presence.waitForCount(2)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [peer], change: .online(peer)))

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

        await fixture.client.disconnectAndWait()
        await presence.waitForCount(5)
        #expect(presence.snapshot.last == .init(onlineNodeIDs: [], change: .reset))
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

        fixture.transport.bumpSent()
        await stats.waitForCount(baseline + 1)
        #expect(stats.snapshot.last?.sent == fixture.transport.runtimeStats().sent)

        let settled = stats.snapshot.count
        try await Task.sleep(for: .seconds(1.5))
        #expect(stats.snapshot.count == settled)
        await fixture.client.disconnectAndWait()
    }

    @Test("a lifecycle values stream ends when the client is released")
    func streamEndsWithClient() async throws {
        let transport = FakeTransportClient()
        var client: KeepTalkingClient? = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: UUID(), node: UUID()),
            localStore: try await KeepTalkingInMemoryStore.make(),
            transport: transport
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
