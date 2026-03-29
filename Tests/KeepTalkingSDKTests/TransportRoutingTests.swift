import Foundation
import Testing

@testable import KeepTalkingSDK

struct TransportRoutingTests {
    @Test("message envelopes route through a ready direct channel")
    func messageEnvelopeRoutesThroughDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "41000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeMessageEnvelope(
            contextID: harness.config.contextID,
            senderNodeID: harness.config.node
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentSequenced.count == 1)
        let sentEnvelope = try #require(direct.sentSequenced.first?.envelope)
        guard let message = sentEnvelope.message else {
            Issue.record("expected chat message on direct channel")
            return
        }
        #expect(message.content == "hello over direct")
        #expect(harness.broadcast.sentSequenced.isEmpty)
    }

    @Test("context sync envelopes prefer p2p before sfu")
    func contextSyncPrefersDirectBeforeBroadcast() {
        let envelope = makeContextSyncEnvelope(
            contextID: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            requester: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
            recipient: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        )

        #expect(envelope.preferredRoutes == [.p2p, .sfu])
    }

    @Test("presence upgrades direct channel without trust gating")
    func presenceCreatesDirectChannelAndAttemptsUpgrade() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
        harness.broadcast.simulateReceive(
            KeepTalkingSequencedEnvelope(
                senderNode: remote,
                sequence: 1,
                envelope: KeepTalkingP2PPresencePayload(node: remote)
            )
        )

        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)
    }

    @Test("service envelopes route through a ready direct channel")
    func serviceEnvelopeRoutesThroughDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeContextSyncEnvelope(
            contextID: harness.config.contextID,
            requester: harness.config.node,
            recipient: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentSequenced.count == 1)
        let sentEnvelope = try #require(direct.sentSequenced.first?.envelope)
        guard case .summaryRequest(let request) = sentEnvelope.contextSync else {
            Issue.record("expected context sync summary request on direct channel")
            return
        }
        #expect(request.recipient == remote)
        #expect(harness.broadcast.sentSequenced.isEmpty)
    }

    @Test("service envelopes fall back to broadcast when direct send fails")
    func serviceEnvelopeFallsBackToBroadcast() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "60000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        direct.sendError = KeepTalkingTransportError.allChannelsUnavailable
        let envelope = makeContextSyncEnvelope(
            contextID: harness.config.contextID,
            requester: harness.config.node,
            recipient: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentSequenced.count == 1)
        #expect(harness.broadcast.sentSequenced.count == 1)
        let sentEnvelope = try #require(harness.broadcast.sentSequenced.first?.envelope)
        guard case .summaryRequest(let request) = sentEnvelope.contextSync else {
            Issue.record("expected context sync summary request on broadcast channel")
            return
        }
        #expect(request.recipient == remote)
    }

    @Test("action call requests route through a ready direct channel")
    func actionCallRequestRoutesThroughDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "65000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeActionCallRequestEnvelope(
            contextID: harness.config.contextID,
            caller: harness.config.node,
            target: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentSequenced.count == 1)
        let sentEnvelope = try #require(direct.sentSequenced.first?.envelope)
        guard let request = sentEnvelope.actionCallRequest else {
            Issue.record("expected action call request on direct channel")
            return
        }
        #expect(request.targetNodeID == remote)
        #expect(harness.broadcast.sentSequenced.isEmpty)
    }

    @Test("trusted envelopes are encrypted before transport routing")
    func trustedEnvelopeEncryptsBeforeRouting() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "65500000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeActionCallRequestEnvelope(
            contextID: harness.config.contextID,
            caller: harness.config.node,
            target: remote
        )

        try await harness.transport.sendTrustedEnvelope(
            envelope,
            cryptorSource: { _ in
                KeepTalkingTrustedEnvelopeCryptor(
                    encrypt: { plainEnvelope in
                        guard let request = plainEnvelope.actionCallRequest else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .unsupportedEnvelope(plainEnvelope.kind)
                        }
                        return KeepTalkingEncryptedActionCallRequestEnvelope(
                            KeepTalkingAsymmetricCipherEnvelope(
                                senderNodeID: request.callerNodeID,
                                recipientNodeID: request.targetNodeID,
                                ciphertext: Data("ciphertext".utf8)
                            )
                        )
                    },
                    decrypt: { encryptedEnvelope in
                        encryptedEnvelope
                    }
                )
            }
        )

        #expect(direct.sentSequenced.count == 1)
        let sentEnvelope = try #require(direct.sentSequenced.first?.envelope)
        let encryptedRequest = try #require(sentEnvelope.encryptedActionCallRequest)
        #expect(encryptedRequest.recipientNodeID == remote)
        #expect(encryptedRequest.ciphertext == Data("ciphertext".utf8))
        #expect(harness.broadcast.sentSequenced.isEmpty)
    }

    @Test("blob bytes use direct when the target peer is ready")
    func blobDataRoutesThroughDirectWhenAvailable() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "70000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let blob = Data("blob-direct".utf8)

        try harness.transport.sendBlobData(blob, targetPeerNodeID: remote)

        #expect(direct.sentBlob == [blob])
        #expect(harness.broadcast.sentBlob.isEmpty)
    }

    @Test("blob bytes fall back to broadcast when direct is unavailable")
    func blobDataFallsBackToBroadcast() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "80000000-0000-0000-0000-000000000000")!
        _ = harness.registerPeer(remote, isReady: false)
        let blob = Data("blob-broadcast".utf8)

        try harness.transport.sendBlobData(blob, targetPeerNodeID: remote)

        #expect(harness.broadcast.sentBlob == [blob])
    }

    @Test("blob bytes fall back to broadcast when direct send fails")
    func blobDataFallsBackToBroadcastAfterDirectFailure() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "81000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        direct.blobSendError = KeepTalkingTransportError.allChannelsUnavailable
        let blob = Data("blob-fallback".utf8)

        try harness.transport.sendBlobData(blob, targetPeerNodeID: remote)

        #expect(direct.sentBlob == [blob])
        #expect(harness.broadcast.sentBlob == [blob])
    }

    @Test("incoming p2p signals create a direct channel and forward the signal")
    func p2pSignalCreatesChannelAndForwardsSignal() async throws {
        let harness = makeHarness()
        try await harness.transport.start()
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "82000000-0000-0000-0000-000000000000")!
        let signal = KeepTalkingP2PSignalPayload(
            from: remote,
            to: harness.config.node,
            data: KeepTalkingP2PSignalData(
                kind: "sdp",
                type: "offer",
                sdp: "v=0",
                candidate: nil,
                sdpMid: nil,
                sdpMLineIndex: nil
            )
        )

        harness.broadcast.simulateReceive(
            KeepTalkingSequencedEnvelope(
                senderNode: remote,
                sequence: 2,
                envelope: signal
            )
        )

        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)
        #expect(direct.receivedSignals.count == 1)
        let forwardedSignal = try #require(direct.receivedSignals.first)
        #expect(forwardedSignal.from == remote)
        #expect(forwardedSignal.to == harness.config.node)
        #expect(forwardedSignal.data.kind == "sdp")
    }
}

struct ChannelStateMachineTests {
    @Test("broadcast state machine reconnects and recovers")
    func broadcastReconnectsAndRecovers() {
        var machine = BroadcastChannelStateMachine()

        #expect(machine.handle(.channelsOpened) == .none)
        #expect(machine.state == .ready)
        #expect(machine.handle(.transportDegraded) == .startReconnect(attempt: 1))
        #expect(machine.state == .reconnecting(attempt: 1))
        #expect(machine.handle(.reconnectFailed) == .startReconnect(attempt: 2))
        #expect(machine.state == .reconnecting(attempt: 2))
        #expect(machine.handle(.reconnectSucceeded) == .none)
        #expect(machine.state == .ready)
    }

    @Test("direct state machine backs off and abandons after repeated failures")
    func directBackoffAndAbandonment() {
        var machine = DirectChannelStateMachine()

        #expect(machine.handle(.upgradeRequested) == .beginHandshake)
        #expect(machine.state == .negotiating)
        #expect(machine.handle(.iceFailed) == .scheduleBackoff(seconds: 2))

        let firstBackoff = machine.state
        #expect(machine.failureCount == 1)
        #expect(machine.handle(.backoffExpired) == .beginHandshake)
        #expect(machine.state == .negotiating)
        #expect(machine.handle(.handshakeTimeout) == .scheduleBackoff(seconds: 4))
        #expect(machine.failureCount == 2)
        #expect(machine.handle(.backoffExpired) == .beginHandshake)
        #expect(machine.state == .negotiating)
        #expect(machine.handle(.iceFailed) == .cleanup)
        #expect(machine.state == .abandoned)
        #expect(machine.failureCount == 3)

        guard case .backingOff = firstBackoff else {
            Issue.record("expected first failure to enter backingOff")
            return
        }
    }
}

private func makeContextSyncEnvelope(
    contextID: UUID,
    requester: UUID,
    recipient: UUID
) -> any KeepTalkingEnvelope {
    KeepTalkingContextSyncEnvelope.summaryRequest(
        KeepTalkingContextSyncSummaryRequest(
            context: contextID,
            requester: requester,
            recipient: recipient
        )
    )
}

private func makeMessageEnvelope(
    contextID: UUID,
    senderNodeID: UUID
) -> any KeepTalkingEnvelope {
    let context = KeepTalkingContext(id: contextID)
    let message = KeepTalkingContextMessage(
        context: context,
        sender: .node(node: senderNodeID),
        content: "hello over direct"
    )
    return message
}

private func makeActionCallRequestEnvelope(
    contextID: UUID,
    caller: UUID,
    target: UUID
) -> any KeepTalkingEnvelope {
    KeepTalkingActionCallRequest(
        contextID: contextID,
        callerNodeID: caller,
        targetNodeID: target,
        call: KeepTalkingActionCall(action: UUID())
    )
}

private func makeHarness() -> TransportHarness {
    let config = KeepTalkingConfig(
        signalURL: URL(string: "ws://127.0.0.1")!,
        contextID: UUID(uuidString: "01000000-0000-0000-0000-000000000000")!,
        node: UUID(uuidString: "02000000-0000-0000-0000-000000000000")!
    )
    let livenessState = KeepTalkingContextLivenessState(localNode: config.node)
    let broadcast = FakeBroadcastChannel()
    let registry = FakePeerRegistry()
    let transport = KeepTalkingContextTransport(
        config: config,
        livenessState: livenessState,
        broadcast: broadcast,
        directChannelFactory: { peerNodeID in
            registry.makeChannel(peerNodeID: peerNodeID)
        }
    )
    return TransportHarness(
        config: config,
        transport: transport,
        broadcast: broadcast,
        registry: registry
    )
}

private struct TransportHarness {
    let config: KeepTalkingConfig
    let transport: KeepTalkingContextTransport
    let broadcast: FakeBroadcastChannel
    let registry: FakePeerRegistry

    @discardableResult
    func registerPeer(_ peerNodeID: UUID, isReady: Bool) -> FakePeerChannel {
        broadcast.simulateReceive(
            KeepTalkingSequencedEnvelope(
                senderNode: peerNodeID,
                sequence: UInt64.random(in: 1...UInt64.max),
                envelope: KeepTalkingP2PPresencePayload(node: peerNodeID)
            )
        )
        let channel = registry.channel(for: peerNodeID) ?? registry.makeChannel(peerNodeID: peerNodeID)
        channel.isReady = isReady
        return channel
    }
}

private final class FakePeerRegistry: @unchecked Sendable {
    private var channels: [UUID: FakePeerChannel] = [:]

    func makeChannel(peerNodeID: UUID) -> FakePeerChannel {
        if let existing = channels[peerNodeID] {
            return existing
        }
        let channel = FakePeerChannel(peerNodeID: peerNodeID)
        channels[peerNodeID] = channel
        return channel
    }

    func channel(for peerNodeID: UUID) -> FakePeerChannel? {
        channels[peerNodeID]
    }
}

private final class FakeBroadcastChannel: KeepTalkingBroadcastTransportChannel, @unchecked Sendable {
    var isReady: Bool { state == .ready }
    let route: KeepTalkingTransportRoute = .sfu
    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    var state: BroadcastChannelState = .ready

    var sentSequenced: [KeepTalkingSequencedEnvelope] = []
    var sentRaw: [any KeepTalkingEnvelope] = []
    var sentBlob: [Data] = []

    func start() async throws {
        state = .ready
    }

    func stop() {
        state = .failed
    }

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        sentSequenced.append(sequenced)
    }

    func sendBlobData(_ data: Data) throws {
        sentBlob.append(data)
    }

    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        sentRaw.append(envelope)
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        KeepTalkingRuntimeStats(
            sent: sentSequenced.count + sentBlob.count,
            received: 0,
            outboundLabel: nil,
            outboundState: isReady ? 1 : 0,
            inboundLabel: nil,
            inboundState: nil,
            retainedChannels: 1,
            route: "sfu"
        )
    }

    func simulateReceive(_ sequenced: KeepTalkingSequencedEnvelope) {
        onReceive?(sequenced)
    }
}

private final class FakePeerChannel: KeepTalkingPeerTransportChannel, @unchecked Sendable {
    let route: KeepTalkingTransportRoute = .p2p
    let peerNodeID: UUID

    var isReady = false
    var onReceive: (@Sendable (KeepTalkingSequencedEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerAlive: (@Sendable (UUID) -> Void)?
    var onSignalOutput: (@Sendable (KeepTalkingP2PSignalPayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?

    var attemptUpgradeCount = 0
    var teardownCount = 0
    var retrialCount = 0
    var sentSequenced: [KeepTalkingSequencedEnvelope] = []
    var sentBlob: [Data] = []
    var receivedSignals: [KeepTalkingP2PSignalPayload] = []
    var sendError: Error?
    var blobSendError: Error?

    init(peerNodeID: UUID) {
        self.peerNodeID = peerNodeID
    }

    func send(_ sequenced: KeepTalkingSequencedEnvelope) throws {
        sentSequenced.append(sequenced)
        if let sendError {
            throw sendError
        }
    }

    func sendBlobData(_ data: Data) throws {
        sentBlob.append(data)
        if let blobSendError {
            throw blobSendError
        }
    }

    func receiveSignal(_ signal: KeepTalkingP2PSignalPayload) {
        receivedSignals.append(signal)
    }

    func attemptUpgrade() {
        attemptUpgradeCount += 1
    }

    func teardown() {
        teardownCount += 1
    }

    func requestRetrial() {
        retrialCount += 1
    }
}
