import Foundation
import Testing

@testable import KeepTalkingSDK

/// Covers transport-mode reconciliation in `KeepTalkingVoiceSession`: a P2P
/// session that hears a peer announce SFU must converge to SFU so the call
/// can't half-open (one side relayed-and-"live", the other stuck doing ICE
/// against a peer that only relays).
struct VoiceSessionTransportReconcileTests {

    /// Thread-safe sink for envelopes the session emits via `sendEnvelope`.
    private final class SentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var envelopes: [any KeepTalkingEnvelope] = []
        private var blobs: [Data] = []
        func record(_ envelope: any KeepTalkingEnvelope) {
            lock.lock()
            defer { lock.unlock() }
            envelopes.append(envelope)
        }
        func recordBlob(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            blobs.append(data)
        }
        var started: [KeepTalkingVoiceCallStartedPayload] {
            lock.lock()
            defer { lock.unlock() }
            return envelopes.compactMap { $0 as? KeepTalkingVoiceCallStartedPayload }
        }
        var sentBlobs: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return blobs
        }
    }

    private final class InboundBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSender: UUID?
        private var storedPayload: Data?

        func record(_ payload: Data, from sender: UUID) {
            lock.lock()
            defer { lock.unlock() }
            storedSender = sender
            storedPayload = payload
        }

        var snapshot: (sender: UUID?, payload: Data?) {
            lock.lock()
            defer { lock.unlock() }
            return (storedSender, storedPayload)
        }
    }

    private func makeSession(
        node: UUID,
        mode: KeepTalkingVoiceSession.TransportMode
    ) -> (session: KeepTalkingVoiceSession, sent: SentBox, context: UUID) {
        let contextID = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
        let config = KeepTalkingConfig(contextID: contextID, node: node)
        let sent = SentBox()
        let session = KeepTalkingVoiceSession(
            config: config,
            sendEnvelope: { envelope in sent.record(envelope) },
            sendBlobData: { data, _ in sent.recordBlob(data) },
            mode: mode
        )
        return (session, sent, contextID)
    }

    @Test("p2p session converges to SFU when a peer announces SFU")
    func convergesToSFUOnMismatch() async throws {
        // Local is the *higher* node id so it's the answerer — it won't try
        // to spin up a real ICE agent before reconciliation runs.
        let local = UUID(uuidString: "ff000000-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "11000000-0000-0000-0000-000000000000")!
        let (session, _, context) = makeSession(node: local, mode: .p2p)
        try await session.start()
        #expect(session.effectiveTransport == .p2p)

        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer,
                contextID: context,
                effectiveTransport: "sfu"
            )
        )

        #expect(session.effectiveTransport == .sfu)
        #expect(session.autoStickySFU)
        let peerStates = session.peers
        #expect(peerStates.count == 1)
        #expect(peerStates.first?.state == .sfuRelay)
    }

    @Test("p2p session stays p2p when the peer is also p2p")
    func staysP2POnMatch() async throws {
        let local = UUID(uuidString: "ff000000-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "11000000-0000-0000-0000-000000000000")!
        let (session, _, context) = makeSession(node: local, mode: .p2p)
        try await session.start()

        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer,
                contextID: context,
                effectiveTransport: "p2p"
            )
        )

        #expect(session.effectiveTransport == .p2p)
        #expect(!session.autoStickySFU)
        // Local is the answerer here, so it parks at `.discovering` waiting
        // for the offer rather than building an ICE agent.
        #expect(session.peers.first?.state == .discovering)
    }

    @Test("a started with no transport is treated as p2p (legacy peer)")
    func legacyStartedDoesNotConverge() async throws {
        let local = UUID(uuidString: "ff000000-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "11000000-0000-0000-0000-000000000000")!
        let (session, _, context) = makeSession(node: local, mode: .p2p)
        try await session.start()

        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(from: peer, contextID: context)
        )

        #expect(session.effectiveTransport == .p2p)
        #expect(!session.autoStickySFU)
    }

    @Test("broadcastStarted stamps the session's effective transport")
    func startedStampsTransport() async throws {
        let local = UUID(uuidString: "02000000-0000-0000-0000-000000000000")!
        let (session, sent, _) = makeSession(node: local, mode: .sfu)
        try await session.start()

        let started = sent.started
        #expect(!started.isEmpty)
        #expect(started.allSatisfy { $0.effectiveTransport == "sfu" })
    }

    @Test("heartbeat evicts stale peer and allows rejoin")
    func heartbeatEvictsAndRejoin() async throws {
        let local = UUID(uuidString: "ff000000-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "11000000-0000-0000-0000-000000000000")!
        let (session, sent, context) = makeSession(node: local, mode: .sfu)
        try await session.start()

        // Peer joins.
        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer, contextID: context, effectiveTransport: "sfu"
            )
        )
        #expect(session.peers.count == 1)

        // Peer disappears — voice.ended lost. Simulate heartbeat ticks
        // with no inbound voice.started from the peer. Threshold is 3
        // ticks (6 s at 2 s intervals).
        session.heartbeatTick()  // tick 1
        session.heartbeatTick()  // tick 2
        #expect(session.peers.count == 1)
        session.heartbeatTick()  // tick 3 — hits threshold, evicted
        #expect(session.peers.isEmpty)

        // Peer reconnects and sends a fresh voice.started.
        let sentCountBefore = sent.started.count
        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer, contextID: context, effectiveTransport: "sfu"
            )
        )
        #expect(session.peers.count == 1)
        #expect(session.peers.first?.state == .sfuRelay)
        #expect(sent.started.count > sentCountBefore)
    }

    @Test("heartbeat re-broadcast keeps peer alive")
    func heartbeatEchoResetsFreshness() async throws {
        let local = UUID(uuidString: "ff000000-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "11000000-0000-0000-0000-000000000000")!
        let (session, _, context) = makeSession(node: local, mode: .sfu)
        try await session.start()

        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer, contextID: context, effectiveTransport: "sfu"
            )
        )
        // Tick once — peer ages to 1.
        session.heartbeatTick()
        #expect(session.peers.count == 1)

        // Peer's heartbeat echo arrives — resets the counter.
        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(
                from: peer, contextID: context, effectiveTransport: "sfu"
            )
        )

        // Another tick — peer is at 1 again, not 2. Still alive.
        session.heartbeatTick()
        #expect(session.peers.count == 1)
    }

    @Test("sfu audio broadcast emits one relayed voice frame")
    func sfuBroadcastWrapsFrameOnce() async throws {
        let local = UUID(uuidString: "22000000-0000-0000-0000-000000000000")!
        let peerA = UUID(uuidString: "33000000-0000-0000-0000-000000000000")!
        let peerB = UUID(uuidString: "44000000-0000-0000-0000-000000000000")!
        let (session, sent, context) = makeSession(node: local, mode: .sfu)
        try await session.start()

        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(from: peerA, contextID: context, effectiveTransport: "sfu")
        )
        session.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(from: peerB, contextID: context, effectiveTransport: "sfu")
        )

        session.broadcast(Data("pcm".utf8))

        #expect(sent.sentBlobs.count == 1)
    }

    @Test("sfu relayed voice frame restores sender and payload")
    func sfuRelayedFrameRestoresSender() async throws {
        let sender = UUID(uuidString: "55000000-0000-0000-0000-000000000000")!
        let receiver = UUID(uuidString: "66000000-0000-0000-0000-000000000000")!
        let contextID = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
        let senderSent = SentBox()
        let senderSession = KeepTalkingVoiceSession(
            config: KeepTalkingConfig(contextID: contextID, node: sender),
            sendEnvelope: { _ in },
            sendBlobData: { data, _ in senderSent.recordBlob(data) },
            mode: .sfu
        )
        let receiverSession = KeepTalkingVoiceSession(
            config: KeepTalkingConfig(contextID: contextID, node: receiver),
            sendEnvelope: { _ in },
            sendBlobData: { _, _ in },
            mode: .sfu
        )

        try await senderSession.start()
        try await receiverSession.start()
        senderSession.receiveVoiceEnvelope(
            KeepTalkingVoiceCallStartedPayload(from: receiver, contextID: contextID, effectiveTransport: "sfu")
        )

        senderSession.broadcast(Data("voice-payload".utf8))
        let relayed = try #require(senderSent.sentBlobs.first)

        let inbound = InboundBox()
        receiverSession.onInboundFrame = { payload, sender in
            inbound.record(payload, from: sender)
        }

        #expect(receiverSession.receiveRelayedFrame(relayed))
        let snapshot = inbound.snapshot
        #expect(snapshot.sender == sender)
        #expect(snapshot.payload == Data("voice-payload".utf8))
    }
}
