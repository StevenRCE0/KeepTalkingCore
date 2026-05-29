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
        func record(_ envelope: any KeepTalkingEnvelope) {
            lock.lock()
            defer { lock.unlock() }
            envelopes.append(envelope)
        }
        var started: [KeepTalkingVoiceCallStartedPayload] {
            lock.lock()
            defer { lock.unlock() }
            return envelopes.compactMap { $0 as? KeepTalkingVoiceCallStartedPayload }
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
            sendBlobData: { _, _ in },
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
}
