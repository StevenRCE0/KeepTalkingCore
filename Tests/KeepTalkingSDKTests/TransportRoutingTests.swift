import Foundation
import Testing

@testable import KeepTalkingSDK

struct TransportRoutingTests {
    @Test("untargeted chat fans out over ready direct channels and broadcast")
    func untargetedMessageFansOutOverDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "41000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeMessageEnvelope(
            contextID: harness.config.contextID,
            senderNodeID: harness.config.node
        )

        try harness.transport.sendEnvelope(envelope)

        // The direct leg is the point of the change: chat used to be
        // structurally unable to take it, because an untargeted envelope
        // resolved no channel.
        #expect(direct.sentEnvelopes.count == 1)
        // Broadcast still goes out to cover peers with no direct channel. The
        // duplicate this creates for `remote` is absorbed at persistence.
        #expect(harness.broadcast.sentEnvelopes.count == 1)
        let sentEnvelope = try #require(harness.broadcast.sentEnvelopes.first)
        guard let message = sentEnvelope.message else {
            Issue.record("expected chat message on broadcast channel")
            return
        }
        #expect(message.content == "hello over broadcast")
    }

    @Test("a peer with no ready direct channel is covered by broadcast alone")
    func untargetedChatFallsBackToBroadcastWhenNoDirectIsReady() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "42000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: false)
        let envelope = makeMessageEnvelope(
            contextID: harness.config.contextID,
            senderNodeID: harness.config.node
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentEnvelopes.isEmpty)
        #expect(harness.broadcast.sentEnvelopes.count == 1)
    }

    @Test("non-fan-out-eligible kinds never take the direct fan-out path")
    func ineligibleKindsStayOnBroadcast() {
        // The two kinds that break on redelivery must not be direct-capable,
        // which is what keeps them off the fan-out path entirely.
        #expect(!KeepTalkingEnvelopeKind.voiceCallSignal.allowsDirect)
        #expect(!KeepTalkingEnvelopeKind.trustRequest.allowsDirect)

        // Everything direct-capable is either fan-out eligible or carries a
        // target, so the untargeted fan-out arm only ever sees safe kinds.
        for kind in [
            KeepTalkingEnvelopeKind.message,
            .attachment,
            .voiceCallTranscriptLine,
        ] {
            #expect(kind.allowsDirect)
            #expect(kind.isFanOutEligible)
        }
        for kind in [
            KeepTalkingEnvelopeKind.actionCallRequest,
            .requestAck,
            .actionCallResult,
        ] {
            #expect(kind.allowsDirect)
            #expect(!kind.isFanOutEligible)
        }
    }

    @Test("context sync envelopes use the membership-gated SFU")
    func contextSyncUsesSFUOnly() {
        let envelope = makeContextSyncEnvelope(
            contextID: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            requester: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
            recipient: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!
        )

        #expect(!envelope.allowsDirect)
    }

    @Test("context sync metadata identifies its directed peer")
    func contextSyncTargetsRecipientAndRequester() {
        let context = UUID()
        let requester = UUID()
        let recipient = UUID()
        let request = KeepTalkingContextSyncSummaryRequest(
            context: context,
            requester: requester,
            recipient: recipient
        )
        let summary = KeepTalkingContextSyncMetadata(
            messageCount: 0,
            senders: [],
            chunks: []
        )
        let result = KeepTalkingContextSyncSummaryResult(
            request: request.request,
            context: context,
            requester: requester,
            responder: recipient,
            summary: summary
        )

        #expect(KeepTalkingContextSyncEnvelope.summaryRequest(request).targetPeerNodeID == recipient)
        #expect(KeepTalkingContextSyncEnvelope.summaryResult(result).targetPeerNodeID == requester)
        #expect(
            KeepTalkingContextSyncEnvelope.failureResult(
                KeepTalkingContextSyncFailureResult(
                    request: request.request,
                    context: context,
                    requester: requester,
                    responder: recipient,
                    message: "unavailable"
                )
            ).targetPeerNodeID == requester
        )
        #expect(
            KeepTalkingContextSyncEnvelope.attachmentRequest(
                KeepTalkingContextSyncAttachmentRequest(
                    context: context,
                    requester: requester,
                    hashes: []
                )
            ).targetPeerNodeID == nil
        )
    }

    @Test("presence upgrades direct channel without trust gating")
    func presenceCreatesDirectChannelAndAttemptsUpgrade() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
        harness.broadcast.simulateReceive(
            KeepTalkingP2PPresencePayload(node: remote))

        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)
    }

    @Test("repeated presence does not re-upgrade an established direct channel")
    func repeatedPresenceDoesNotRestormUpgrade() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "41500000-0000-0000-0000-000000000000")!

        // First presence is the connect edge → create the channel, upgrade once.
        harness.deliverPresence(from: remote)
        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)

        // Further heartbeats from a still-online peer must NOT re-attempt the
        // upgrade — that per-beat prod was the SDP-gathering storm, and it reset
        // the channel's backoff/failure budget every beat. Upgrade stays at 1 and
        // retrial is never forced for a peer that simply keeps being present.
        harness.deliverPresence(from: remote)
        harness.deliverPresence(from: remote)
        #expect(direct.attemptUpgradeCount == 1)
        #expect(direct.retrialCount == 0)
    }

    @Test("the mesh cap tears down the mesh and refuses the peer that trips it")
    func meshCapTearsDownAndRefuses() async throws {
        let harness = makeHarness(maxDirectMeshSize: 2)
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let peers = [
            UUID(uuidString: "51500000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "51500000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "51500000-0000-0000-0000-000000000002")!,
        ]
        for peer in peers.prefix(2) {
            harness.deliverPresence(from: peer)
        }
        #expect(harness.registry.channel(for: peers[0])?.attemptUpgradeCount == 1)
        #expect(harness.registry.channel(for: peers[1])?.attemptUpgradeCount == 1)

        // The third peer projects to 3 > 2: the whole mesh comes down and the
        // peer that tripped it is refused rather than stored.
        harness.deliverPresence(from: peers[2])
        #expect(harness.registry.channel(for: peers[0])?.teardownCount == 1)
        #expect(harness.registry.channel(for: peers[1])?.teardownCount == 1)
        #expect(harness.registry.channel(for: peers[2])?.teardownCount == 1)
        #expect(harness.registry.channel(for: peers[2])?.attemptUpgradeCount == 0)
    }

    @Test("a disabled mesh stops allocating a channel on every presence beat")
    func disabledMeshDoesNotReallocatePerBeat() async throws {
        let harness = makeHarness(maxDirectMeshSize: 2)
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let peers = [
            UUID(uuidString: "52500000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "52500000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "52500000-0000-0000-0000-000000000002")!,
        ]
        for peer in peers {
            harness.deliverPresence(from: peer)
        }
        let allocationsAtTrip = harness.registry.makeChannelCalls

        // Once the cap has tripped no peer has a channel, so the join backstop
        // has nothing to suppress it but the disabled flag itself. Without that
        // check every beat from every peer allocated a channel, bound its
        // callbacks, had the cap refuse it, and fired a spurious `.joined`.
        for _ in 0..<5 {
            for peer in peers {
                harness.deliverPresence(from: peer)
            }
        }
        #expect(harness.registry.makeChannelCalls == allocationsAtTrip)
    }

    @Test("a network environment change re-arms the mesh cap")
    func environmentChangeReArmsMeshCap() async throws {
        let harness = makeHarness(maxDirectMeshSize: 2)
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let peers = [
            UUID(uuidString: "53500000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "53500000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "53500000-0000-0000-0000-000000000002")!,
        ]
        for peer in peers {
            harness.deliverPresence(from: peer)
        }
        let allocationsAtTrip = harness.registry.makeChannelCalls

        // Same environment: the cap's verdict still stands.
        harness.transport.reconcileNetworkEnvironment()
        harness.deliverPresence(from: peers[0])
        #expect(harness.registry.makeChannelCalls == allocationsAtTrip)

        // Moved networks: the verdict was about the old vantage point, so the
        // backstop is allowed to rebuild the mesh from scratch.
        harness.environment.move(to: "net-b")
        harness.transport.reconcileNetworkEnvironment()
        harness.deliverPresence(from: peers[0])
        #expect(harness.registry.makeChannelCalls > allocationsAtTrip)
        #expect(harness.registry.channel(for: peers[0])?.attemptUpgradeCount == 2)
    }

    @Test("a network environment change retries a channel that gave up")
    func environmentChangeRetriesAbandonedChannel() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "54500000-0000-0000-0000-000000000000")!
        harness.deliverPresence(from: remote)
        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)

        // The channel exhausts its failure budget. A still-online peer produces
        // no reachability edge, so nothing else would ever revive it.
        direct.state = .abandoned
        harness.transport.reconcileNetworkEnvironment()
        #expect(direct.retrialCount == 0)

        harness.environment.move(to: "net-b")
        harness.transport.reconcileNetworkEnvironment()
        #expect(direct.retrialCount == 1)
        #expect(direct.attemptUpgradeCount == 2)
    }

    @Test("a ready channel is left alone when the environment changes")
    func environmentChangeLeavesReadyChannelAlone() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "55500000-0000-0000-0000-000000000000")!
        harness.deliverPresence(from: remote)
        let direct = try #require(harness.registry.channel(for: remote))
        direct.state = .ready
        direct.isReady = true

        harness.environment.move(to: "net-b")
        harness.transport.reconcileNetworkEnvironment()
        #expect(direct.retrialCount == 0)
        #expect(direct.attemptUpgradeCount == 1)
    }

    @Test("context sync stays on SFU when a direct channel is ready")
    func contextSyncUsesSFUWhenDirectIsReady() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "50000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeContextSyncEnvelope(
            contextID: harness.config.contextID,
            requester: harness.config.node,
            recipient: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentEnvelopes.isEmpty)
        let sentEnvelope = try #require(harness.broadcast.sentEnvelopes.first)
        guard case .summaryRequest(let request) = sentEnvelope.contextSync else {
            Issue.record("expected context sync summary request on broadcast channel")
            return
        }
        #expect(request.recipient == remote)
        #expect(harness.broadcast.sentEnvelopes.count == 1)
    }

    @Test("directed context sync never uses direct channels")
    func contextSyncSkipsDirectChannels() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let recipient = UUID(uuidString: "51000000-0000-0000-0000-000000000000")!
        let unrelated = UUID(uuidString: "52000000-0000-0000-0000-000000000000")!
        let recipientChannel = harness.registerPeer(recipient, isReady: false)
        let unrelatedChannel = harness.registerPeer(unrelated, isReady: true)

        try harness.transport.sendEnvelope(
            makeContextSyncEnvelope(
                contextID: harness.config.contextID,
                requester: harness.config.node,
                recipient: recipient
            )
        )

        #expect(recipientChannel.sentEnvelopes.isEmpty)
        #expect(unrelatedChannel.sentEnvelopes.isEmpty)
        #expect(harness.broadcast.sentEnvelopes.count == 1)
    }

    @Test("presence reannounces on SFU peer join and reconnect")
    func presenceReannouncesOnMembershipEvents() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        #expect(harness.broadcast.sentPresenceCount == 1)

        harness.broadcast.simulatePeerJoin()
        #expect(harness.broadcast.sentPresenceCount == 2)

        harness.broadcast.simulateState(.reconnecting(attempt: 1))
        harness.broadcast.simulateState(.ready)
        #expect(harness.broadcast.sentPresenceCount == 3)
    }

    @Test("liveness probe uses an acknowledged SFU probe")
    func livenessProbeDelegatesToBroadcast() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        harness.transport.sendLivenessProbe()

        #expect(harness.broadcast.livenessProbeCount == 1)
        #expect(harness.broadcast.sentPresenceCount == 2)
    }

    @Test("a stopped transport cannot finish an older start")
    func stopInvalidatesPendingStart() async {
        let harness = makeHarness()
        let gate = TestStartGate()
        let readyCount = ThreadSafeCounter()
        harness.broadcast.startGate = gate
        harness.transport.onBroadcastReady = { readyCount.increment() }

        let start = Task { try await harness.transport.start().value }
        await gate.waitUntilBlocked()
        harness.transport.stop()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(readyCount.value == 0)
        #expect(harness.broadcast.sentPresenceCount == 0)
    }

    @Test("prefer-direct envelopes fall back to broadcast when direct send fails")
    func preferDirectEnvelopeFallsBackToBroadcast() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "60000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        direct.sendError = KeepTalkingTransportError.allChannelsUnavailable
        let envelope = makeActionCallRequestEnvelope(
            contextID: harness.config.contextID,
            caller: harness.config.node,
            target: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentEnvelopes.count == 1)
        #expect(harness.broadcast.sentEnvelopes.count == 1)
        let sentEnvelope = try #require(harness.broadcast.sentEnvelopes.first)
        guard let request = sentEnvelope.actionCallRequest else {
            Issue.record("expected action call request on broadcast channel")
            return
        }
        #expect(request.targetNodeID == remote)
    }

    @Test("action call requests route through a ready direct channel")
    func actionCallRequestRoutesThroughDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "65000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let envelope = makeActionCallRequestEnvelope(
            contextID: harness.config.contextID,
            caller: harness.config.node,
            target: remote
        )

        try harness.transport.sendEnvelope(envelope)

        #expect(direct.sentEnvelopes.count == 1)
        let sentEnvelope = try #require(direct.sentEnvelopes.first)
        guard let request = sentEnvelope.actionCallRequest else {
            Issue.record("expected action call request on direct channel")
            return
        }
        #expect(request.targetNodeID == remote)
        #expect(harness.broadcast.sentEnvelopes.isEmpty)
    }

    @Test("trusted envelopes are encrypted before transport routing")
    func trustedEnvelopeEncryptsBeforeRouting() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
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
                            throw
                                KeepTalkingTrustedEnvelopeCryptorError
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

        #expect(direct.sentEnvelopes.count == 1)
        let sentEnvelope = try #require(direct.sentEnvelopes.first)
        let encryptedRequest = try #require(sentEnvelope.encryptedActionCallRequest)
        #expect(encryptedRequest.recipientNodeID == remote)
        #expect(encryptedRequest.ciphertext == Data("ciphertext".utf8))
        #expect(harness.broadcast.sentEnvelopes.isEmpty)
    }

    @Test("blob bytes use direct when the target peer is ready")
    func blobDataRoutesThroughDirectWhenAvailable() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
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
        try await harness.transport.start().value
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
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "81000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        direct.blobSendError = KeepTalkingTransportError.allChannelsUnavailable
        let blob = Data("blob-fallback".utf8)

        try harness.transport.sendBlobData(blob, targetPeerNodeID: remote)

        #expect(direct.sentBlob == [blob])
        #expect(harness.broadcast.sentBlob == [blob])
    }

    @Test("broadcast blob send bypasses ready direct channels")
    func broadcastBlobBypassesReadyDirect() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "81200000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let blob = Data("voice-sfu-frame".utf8)

        try harness.transport.sendBlobDataViaBroadcast(blob)

        #expect(direct.sentBlob.isEmpty)
        #expect(harness.broadcast.sentBlob == [blob])
    }

    @Test("realtime bytes stay on the SFU realtime channel")
    func realtimeBytesUseBroadcastOnly() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "81300000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: true)
        let frame = Data("voice-realtime-frame".utf8)

        try harness.transport.sendRealtimeDataViaBroadcast(frame)

        #expect(direct.sentBlob.isEmpty)
        #expect(harness.broadcast.sentBlob.isEmpty)
        #expect(harness.broadcast.sentRealtime == [frame])
    }

    @Test("broadcast send failures stay at the transport layer")
    func broadcastSendFailureDoesNotLeakDataChannelErrors() async throws {
        let harness = makeHarness()
        harness.broadcast.sendError = KeepTalkingTransportError.allChannelsUnavailable
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "81500000-0000-0000-0000-000000000000")!
        _ = harness.registerPeer(remote, isReady: false)
        let envelope = makeContextSyncEnvelope(
            contextID: harness.config.contextID,
            requester: harness.config.node,
            recipient: remote
        )

        do {
            try harness.transport.sendEnvelope(envelope)
            Issue.record("expected transport-level unavailability error")
        } catch let error as KeepTalkingTransportError {
            guard case .allChannelsUnavailable = error else {
                Issue.record("unexpected transport error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(harness.broadcast.sentEnvelopes.count == 1)
        #expect(harness.broadcast.state == .reconnecting(attempt: 1))
    }

    @Test("incoming p2p signals create a direct channel and forward the signal")
    func p2pSignalCreatesChannelAndForwardsSignal() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
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

        harness.broadcast.simulateReceive(signal)

        let direct = try #require(harness.registry.channel(for: remote))
        #expect(direct.attemptUpgradeCount == 1)
        #expect(direct.receivedSignals.count == 1)
        let forwardedSignal = try #require(direct.receivedSignals.first)
        #expect(forwardedSignal.from == remote)
        #expect(forwardedSignal.to == harness.config.node)
        #expect(forwardedSignal.data.kind == "sdp")
    }

    @Test("request p2p trial retries an existing unavailable direct channel")
    func requestP2PTrialRetriesExistingUnavailableDirectChannel() async throws {
        let harness = makeHarness()
        try await harness.transport.start().value
        defer { harness.transport.stop() }

        let remote = UUID(uuidString: "83000000-0000-0000-0000-000000000000")!
        let direct = harness.registerPeer(remote, isReady: false)

        harness.transport.requestP2PTrial()

        #expect(direct.retrialCount == 1)
        #expect(direct.attemptUpgradeCount == 2)
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

    @Test("initial degradation does not remain falsely recovering")
    func broadcastInitialDegradationFails() {
        var machine = BroadcastChannelStateMachine()

        #expect(machine.handle(.transportDegraded) == .none)
        #expect(machine.state == .failed)
    }

    @Test("broadcast state machine can recover after being stopped")
    func broadcastRecoversAfterStop() {
        var machine = BroadcastChannelStateMachine()

        #expect(machine.handle(.channelsOpened) == .none)
        #expect(machine.state == .ready)
        #expect(machine.handle(.stopped) == .none)
        #expect(machine.state == .failed)
        #expect(machine.handle(.channelsOpened) == .none)
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

    @Test("direct state machine enters failure path on iceFailed while ready")
    func directIceFailedWhileReadyDoesNotStick() {
        var machine = DirectChannelStateMachine()

        // Drive to .ready
        #expect(machine.handle(.upgradeRequested) == .beginHandshake)
        #expect(machine.handle(.iceConnected) == .none)
        #expect(machine.state == .ready)

        // H2 keepalive fires iceFailed while the state machine is .ready.
        // Before the fix this fell to `default: .none` and the channel
        // stayed .ready forever, pinning the dead peer "online".
        let effect = machine.handle(.iceFailed)
        #expect(machine.state != .ready, "iceFailed must leave .ready")
        // First failure → backoff (not abandoned yet).
        #expect(machine.failureCount == 1)
        guard case .scheduleBackoff = effect else {
            Issue.record("expected scheduleBackoff, got \(effect)")
            return
        }
    }

    @Test("direct state machine allows forced retry during backoff")
    func directRetryBreaksOutOfBackoff() {
        var machine = DirectChannelStateMachine()

        #expect(machine.handle(.upgradeRequested) == .beginHandshake)
        #expect(machine.handle(.iceFailed) == .scheduleBackoff(seconds: 2))
        #expect(machine.handle(.retryRequested) == .cleanup)
        #expect(machine.state == .idle)
        #expect(machine.failureCount == 0)
        #expect(machine.handle(.upgradeRequested) == .beginHandshake)
        #expect(machine.state == .negotiating)
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
        content: "hello over broadcast"
    )
    return message
}

struct SFUJuiceLifecycleTests {
    @Test("only a matching roster snapshot confirms context membership")
    func matchingRosterConfirmsMembership() {
        let context = UUID()
        let localKey = Data(repeating: 1, count: 32)

        #expect(
            !KeepTalkingSFUJuiceClient.confirmsContextMembership(
                .joined(context: context, pubkey: localKey),
                contextID: context,
                publicKey: localKey
            )
        )
        #expect(
            !KeepTalkingSFUJuiceClient.confirmsContextMembership(
                .snapshot(context: UUID(), peers: [localKey]),
                contextID: context,
                publicKey: localKey
            )
        )
        #expect(
            !KeepTalkingSFUJuiceClient.confirmsContextMembership(
                .snapshot(context: context, peers: []),
                contextID: context,
                publicKey: localKey
            )
        )
        #expect(
            KeepTalkingSFUJuiceClient.confirmsContextMembership(
                .snapshot(context: context, peers: [localKey]),
                contextID: context,
                publicKey: localKey
            )
        )
        #expect(
            KeepTalkingSFUJuiceClient.rejectsContextMembership(
                .snapshot(context: context, peers: []),
                contextID: context,
                publicKey: localKey
            )
        )
        #expect(
            !KeepTalkingSFUJuiceClient.rejectsContextMembership(
                .snapshot(context: context, peers: [localKey]),
                contextID: context,
                publicKey: localKey
            )
        )
    }

    @Test("stopping during connection cancels start without degradation")
    func stopCancelsPendingStart() async {
        let config = KeepTalkingConfig(
            contextID: UUID(),
            node: UUID(),
            sfuEndpoint: .init(host: "192.0.2.1", port: 9701)
        )
        let client = KeepTalkingSFUJuiceClient(
            config: config,
            sfuHost: "192.0.2.1",
            sfuPort: 9701
        )
        let degraded = ThreadSafeFlag()
        let (logs, logContinuation) = AsyncStream.makeStream(of: String.self)
        client.onLog = { logContinuation.yield($0) }
        client.onTransportDegraded = { _ in degraded.set() }

        let start = Task { try await client.start().value }
        for await log in logs where log.contains("connecting host=") {
            break
        }

        client.stop()
        logContinuation.finish()
        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(!degraded.value)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private actor TestStartGate {
    private var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !isWaiting { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
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

private func makeHarness(
    maxDirectMeshSize: Int = 4,
    environment: FakeNetworkEnvironment = FakeNetworkEnvironment("net-a")
) -> TransportHarness {
    let config = KeepTalkingConfig(
        contextID: UUID(uuidString: "01000000-0000-0000-0000-000000000000")!,
        node: UUID(uuidString: "02000000-0000-0000-0000-000000000000")!,
        sfuEndpoint: .init(host: "127.0.0.1", port: 9701),
        maxDirectMeshSize: maxDirectMeshSize
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
        },
        environmentDigest: { environment.current }
    )
    return TransportHarness(
        config: config,
        transport: transport,
        broadcast: broadcast,
        registry: registry,
        environment: environment
    )
}

/// Mutable stand-in for `KeepTalkingNetworkEnvironment.digest()`.
final class FakeNetworkEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    var current: String { lock.withLock { value } }

    func move(to newValue: String) {
        lock.withLock { value = newValue }
    }
}

private struct TransportHarness {
    let config: KeepTalkingConfig
    let transport: KeepTalkingContextTransport
    let broadcast: FakeBroadcastChannel
    let registry: FakePeerRegistry
    let environment: FakeNetworkEnvironment

    @discardableResult
    func registerPeer(_ peerNodeID: UUID, isReady: Bool) -> FakePeerChannel {
        deliverPresence(from: peerNodeID)
        let channel = registry.channel(for: peerNodeID) ?? registry.makeChannel(peerNodeID: peerNodeID)
        channel.isReady = isReady
        return channel
    }

    /// Simulate one inbound presence heartbeat from `peerNodeID`.
    func deliverPresence(from peerNodeID: UUID) {
        broadcast.simulateReceive(
            KeepTalkingP2PPresencePayload(node: peerNodeID))
    }
}

private final class FakePeerRegistry: @unchecked Sendable {
    private var channels: [UUID: FakePeerChannel] = [:]
    /// Counts factory invocations, not distinct channels — the storm the mesh
    /// cap can cause shows up here as repeated allocation for the same peer.
    private(set) var makeChannelCalls = 0

    func makeChannel(peerNodeID: UUID) -> FakePeerChannel {
        makeChannelCalls += 1
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
    var onReceive: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerJoined: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    var state: BroadcastChannelState = .ready

    var sentEnvelopes: [any KeepTalkingEnvelope] = []
    var sentRaw: [any KeepTalkingEnvelope] = []
    var sentBlob: [Data] = []
    var sentRealtime: [Data] = []
    var sendError: Error?
    var rawSendError: Error?
    var blobSendError: Error?
    var realtimeSendError: Error?
    var livenessProbeCount = 0
    var startGate: TestStartGate?

    var sentPresenceCount: Int {
        sentRaw.filter { $0.kind == .p2pPresence }.count
    }

    func start() throws -> Task<Void, Error> {
        Task {
            if let startGate { await startGate.wait() }
            state = .ready
            onStateChange?()
        }
    }

    func stop() {
        state = .failed
    }

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        sentEnvelopes.append(envelope)
        if let sendError {
            state = .reconnecting(attempt: 1)
            throw sendError
        }
    }

    func sendBlobData(_ data: Data) throws {
        sentBlob.append(data)
        if let blobSendError {
            state = .reconnecting(attempt: 1)
            throw blobSendError
        }
    }

    func sendRealtimeData(_ data: Data) throws {
        sentRealtime.append(data)
        if let realtimeSendError {
            state = .reconnecting(attempt: 1)
            throw realtimeSendError
        }
    }

    func sendRawEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        sentRaw.append(envelope)
        if let rawSendError {
            state = .reconnecting(attempt: 1)
            throw rawSendError
        }
    }

    func sendLivenessProbe() {
        livenessProbeCount += 1
    }

    func runtimeStats() -> KeepTalkingRuntimeStats {
        KeepTalkingRuntimeStats(
            sent: sentEnvelopes.count + sentBlob.count + sentRealtime.count,
            received: 0,
            outboundLabel: nil,
            outboundState: isReady ? 1 : 0,
            inboundLabel: nil,
            inboundState: nil,
            retainedChannels: 1,
            route: "sfu"
        )
    }

    func simulateReceive(_ envelope: any KeepTalkingEnvelope) {
        onReceive?(envelope)
    }

    func simulatePeerJoin() {
        onPeerJoined?()
    }

    func simulateState(_ newState: BroadcastChannelState) {
        state = newState
        onStateChange?()
    }
}

private final class FakePeerChannel: KeepTalkingPeerTransportChannel, @unchecked Sendable {
    let route: KeepTalkingTransportRoute = .p2p
    let peerNodeID: UUID

    var isReady = false
    var onReceive: (@Sendable (any KeepTalkingEnvelope) -> Void)?
    var onBlobData: KeepTalkingTransportBlobDataHandler?
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler?
    var onStateChange: (@Sendable () -> Void)?
    var onPeerAlive: (@Sendable (UUID) -> Void)?
    var onSignalOutput: (@Sendable (KeepTalkingP2PSignalPayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    var state: DirectChannelState = .idle

    var attemptUpgradeCount = 0
    var teardownCount = 0
    var retrialCount = 0
    var sentEnvelopes: [any KeepTalkingEnvelope] = []
    var sentBlob: [Data] = []
    var receivedSignals: [KeepTalkingP2PSignalPayload] = []
    var sendError: Error?
    var blobSendError: Error?

    init(peerNodeID: UUID) {
        self.peerNodeID = peerNodeID
    }

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        sentEnvelopes.append(envelope)
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
