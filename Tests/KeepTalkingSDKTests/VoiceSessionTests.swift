import Foundation
import Testing

@testable import KeepTalkingSDK

/// `KeepTalkingVoiceSession` over datagrams: call presence, the sealed frame
/// header, and liveness.
struct VoiceSessionTests {
    /// Thread-safe sink for what a session sends.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var envelopes: [any KeepTalkingEnvelope] = []
        private var datagrams: [Data] = []

        func record(_ envelope: any KeepTalkingEnvelope) { lock.withLock { envelopes.append(envelope) } }
        func record(_ datagram: Data) { lock.withLock { datagrams.append(datagram) } }

        var started: [KeepTalkingVoiceCallStartedPayload] {
            lock.withLock { envelopes.compactMap { $0 as? KeepTalkingVoiceCallStartedPayload } }
        }
        var sentDatagrams: [Data] { lock.withLock { datagrams } }
    }

    private final class Inbound: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(Data, UUID)] = []
        func record(_ payload: Data, from sender: UUID) { lock.withLock { frames.append((payload, sender)) } }
        var snapshot: [(payload: Data, sender: UUID)] { lock.withLock { frames.map { ($0.0, $0.1) } } }
    }

    private static let contextID = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!

    private func makeSession(
        node: UUID = UUID(),
        secret: Data? = Data(repeating: 3, count: 32)
    ) -> (session: KeepTalkingVoiceSession, wire: Wire, inbound: Inbound) {
        let wire = Wire()
        let inbound = Inbound()
        let session = KeepTalkingVoiceSession(
            config: KeepTalkingConfig(contextID: Self.contextID, node: node),
            sendEnvelope: { wire.record($0) },
            sendDatagram: { wire.record($0) },
            frameSecret: secret
        )
        session.onInboundFrame = { inbound.record($0, from: $1) }
        return (session, wire, inbound)
    }

    private func started(_ node: UUID, session: UUID? = nil) -> KeepTalkingVoiceCallStartedPayload {
        KeepTalkingVoiceCallStartedPayload(from: node, contextID: Self.contextID, sessionID: session)
    }

    @Test("a frame broadcast by one participant opens at another, naming its sender")
    func frameRoundTrip() async throws {
        let shared = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let alice = makeSession()
        let bob = makeSession()
        try await alice.session.start()
        try await bob.session.start()
        // Converge both on one session id: the audio key depends on it.
        alice.session.receiveVoiceEnvelope(started(bob.session.localNodeID, session: shared))
        bob.session.receiveVoiceEnvelope(started(alice.session.localNodeID, session: shared))
        #expect(alice.session.sessionID == bob.session.sessionID)

        alice.session.broadcast(Data("hello".utf8))
        let datagram = try #require(alice.wire.sentDatagrams.last)
        // The sender's id travels only inside the seal.
        #expect(datagram.range(of: alice.session.localNodeID.rfc4122Bytes) == nil)

        #expect(bob.session.receiveDatagram(datagram))
        let frame = try #require(bob.inbound.snapshot.last)
        #expect(frame.payload == Data("hello".utf8))
        #expect(frame.sender == alice.session.localNodeID)
        #expect(bob.session.peers.first { $0.nodeID == alice.session.localNodeID }?.state == .receiving)
    }

    @Test("a frame whispered to one participant is ignored by the others")
    func directedFrame() async throws {
        let shared = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let alice = makeSession()
        let bob = makeSession()
        let carol = makeSession()
        for party in [alice, bob, carol] {
            try await party.session.start()
            for other in [alice, bob, carol] where other.session !== party.session {
                party.session.receiveVoiceEnvelope(started(other.session.localNodeID, session: shared))
            }
        }

        alice.session.send(Data("psst".utf8), to: bob.session.localNodeID)
        let datagram = try #require(alice.wire.sentDatagrams.last)
        #expect(bob.session.receiveDatagram(datagram))
        #expect(carol.session.receiveDatagram(datagram))
        #expect(bob.inbound.snapshot.count == 1)
        #expect(carol.inbound.snapshot.isEmpty)
    }

    @Test("a datagram sealed for another call doesn't open")
    func foreignDatagram() async throws {
        let alice = makeSession(secret: Data(repeating: 1, count: 32))
        let bob = makeSession(secret: Data(repeating: 2, count: 32))
        try await alice.session.start()
        try await bob.session.start()
        alice.session.receiveVoiceEnvelope(started(bob.session.localNodeID))
        alice.session.broadcast(Data("x".utf8))
        let datagram = try #require(alice.wire.sentDatagrams.last)
        #expect(!bob.session.receiveDatagram(datagram))
        #expect(bob.inbound.snapshot.isEmpty)
    }

    @Test("audio from someone who never announced joins them")
    func audioJoins() async throws {
        let alice = makeSession(secret: nil)
        let bob = makeSession(secret: nil)
        try await alice.session.start()
        try await bob.session.start()
        alice.session.receiveVoiceEnvelope(started(bob.session.localNodeID))
        alice.session.broadcast(Data("hi".utf8))

        #expect(bob.session.receiveDatagram(try #require(alice.wire.sentDatagrams.last)))
        #expect(bob.session.peers.map(\.nodeID) == [alice.session.localNodeID])
    }

    @Test("nobody in the call: broadcast sends nothing")
    func broadcastAlone() async throws {
        let alice = makeSession()
        try await alice.session.start()
        alice.session.broadcast(Data("x".utf8))
        #expect(alice.wire.sentDatagrams.isEmpty)
    }

    @Test("participants converge on the lowest session id")
    func sessionConvergence() async throws {
        let alice = makeSession()
        try await alice.session.start()
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        alice.session.receiveVoiceEnvelope(started(UUID(), session: lower))
        #expect(alice.session.sessionID == lower)
        #expect(alice.wire.started.last?.sessionID == lower)
    }

    @Test("heartbeat evicts a silent participant and allows a rejoin")
    func heartbeatEvictsAndRejoins() async throws {
        let alice = makeSession()
        try await alice.session.start()
        let peer = UUID()
        alice.session.receiveVoiceEnvelope(started(peer))
        #expect(alice.session.peers.count == 1)

        for _ in 0..<3 { alice.session.heartbeatTick() }
        #expect(alice.session.peers.isEmpty)

        alice.session.receiveVoiceEnvelope(started(peer))
        #expect(alice.session.peers.count == 1)
    }

    @Test("a participant's heartbeat keeps it in the call")
    func heartbeatKeepsAlive() async throws {
        let alice = makeSession()
        try await alice.session.start()
        let peer = UUID()
        alice.session.receiveVoiceEnvelope(started(peer))
        for _ in 0..<5 {
            alice.session.heartbeatTick()
            alice.session.receiveVoiceEnvelope(started(peer))
        }
        #expect(alice.session.peers.count == 1)
    }

    @Test("the frame header survives a round trip")
    func frameCodec() {
        let frame = KeepTalkingVoiceSession.Frame(sender: UUID(), target: UUID(), payload: Data([1, 2, 3]))
        #expect(KeepTalkingVoiceSession.Frame(decoding: frame.encoded) == frame)
        let everyone = KeepTalkingVoiceSession.Frame(sender: UUID(), target: nil, payload: Data())
        #expect(KeepTalkingVoiceSession.Frame(decoding: everyone.encoded) == everyone)
        #expect(KeepTalkingVoiceSession.Frame(decoding: Data([0x4B, 0x54])) == nil)
    }
}
