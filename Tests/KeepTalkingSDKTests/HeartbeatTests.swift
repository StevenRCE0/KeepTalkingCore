import Foundation
import Testing

@testable import KeepTalkingSDK

struct HeartbeatTests {
    @Test("presence is edge-triggered: connect once, stay online, no per-beat spam")
    func edgeTriggeredOnlineAndEcho() {
        let local = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!
        let t0 = Date(timeIntervalSince1970: 100)
        // Small online window so the offline transition is easy to drive.
        let liveness = KeepTalkingContextLivenessState(
            localNode: local,
            onlineTimeout: 5
        )

        #expect(!liveness.isNodeOnline(peer, now: t0))

        // First presence = the connect edge: new connection + echo once.
        let first = liveness.observePresence(from: peer, echoCooldown: 1, now: t0)
        #expect(first.isNewConnection)
        #expect(first.shouldEcho)
        #expect(liveness.isNodeOnline(peer, now: t0))
        #expect(liveness.onlineNodeIDs(now: t0) == Set([local, peer]))

        // Subsequent presence while still online: NOT a new edge, NO echo — this
        // is the per-beat spam the edge model exists to suppress.
        let beat2 = liveness.observePresence(
            from: peer, echoCooldown: 1, now: t0.addingTimeInterval(2))
        #expect(!beat2.isNewConnection)
        #expect(!beat2.shouldEcho)

        // Still online shortly after the last beat (seen at t0+2, window 5).
        #expect(liveness.isNodeOnline(peer, now: t0.addingTimeInterval(4)))
        // Falls offline once the window elapses since last-seen (t0+2 → t0+8 = 6s).
        #expect(!liveness.isNodeOnline(peer, now: t0.addingTimeInterval(8)))
        #expect(liveness.onlineNodeIDs(now: t0.addingTimeInterval(8)) == Set([local]))

        // Presence after going offline = a fresh connect edge (+ echo) again.
        let reconnect = liveness.observePresence(
            from: peer, echoCooldown: 1, now: t0.addingTimeInterval(9))
        #expect(reconnect.isNewConnection)
        #expect(reconnect.shouldEcho)
    }

    @Test("peer reconnect re-fires the edge only after it actually went offline")
    func reconnectAfterOffline() {
        let local = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!
        let liveness = KeepTalkingContextLivenessState(
            localNode: local,
            onlineTimeout: 5
        )
        let t0 = Date(timeIntervalSince1970: 10)

        #expect(liveness.observePresence(from: peer, echoCooldown: 1, now: t0).isNewConnection)

        // A beat within the window does not re-fire (peer never went offline).
        #expect(
            !liveness.observePresence(
                from: peer, echoCooldown: 1, now: t0.addingTimeInterval(3)
            ).isNewConnection
        )

        // After a gap longer than the window, the peer is offline → reconnect edge.
        #expect(
            liveness.observePresence(
                from: peer, echoCooldown: 1, now: t0.addingTimeInterval(20)
            ).isNewConnection
        )
    }

    @Test("separate liveness states track presence independently")
    func livenessIsolation() {
        let local = UUID(uuidString: "CCCCCCCC-2222-2222-2222-222222222222")!
        let peer = UUID(uuidString: "DDDDDDDD-3333-3333-3333-333333333333")!
        let first = KeepTalkingContextLivenessState(localNode: local, onlineTimeout: 5)
        let second = KeepTalkingContextLivenessState(localNode: local, onlineTimeout: 5)
        let t0 = Date(timeIntervalSince1970: 100)

        _ = first.observePresence(from: peer, echoCooldown: 1, now: t0)
        #expect(first.isNodeOnline(peer, now: t0))
        #expect(!second.isNodeOnline(peer, now: t0))

        _ = second.observePresence(
            from: peer, echoCooldown: 1, now: t0.addingTimeInterval(1))
        #expect(second.isNodeOnline(peer, now: t0.addingTimeInterval(1)))

        // first saw peer at t0, second at t0+1 — at t0+5.5 only first has aged out.
        #expect(!first.isNodeOnline(peer, now: t0.addingTimeInterval(5.5)))
        #expect(second.isNodeOnline(peer, now: t0.addingTimeInterval(5.5)))
    }

    @Test("reset clears liveness so the next presence is a fresh edge")
    func resetClearsState() {
        let local = UUID(uuidString: "EEEEEEEE-4444-4444-4444-444444444444")!
        let peer = UUID(uuidString: "FFFFFFFF-5555-5555-5555-555555555555")!
        let liveness = KeepTalkingContextLivenessState(localNode: local, onlineTimeout: 5)
        let t0 = Date(timeIntervalSince1970: 100)

        _ = liveness.observePresence(from: peer, echoCooldown: 1, now: t0)
        #expect(liveness.isNodeOnline(peer, now: t0))

        liveness.reset()
        #expect(!liveness.isNodeOnline(peer, now: t0))
        #expect(
            liveness.observePresence(
                from: peer, echoCooldown: 1, now: t0.addingTimeInterval(0.1)
            ).isNewConnection
        )
    }
}
