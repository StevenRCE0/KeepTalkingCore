import Foundation
import Testing

@testable import KeepTalkingSDK

struct HeartbeatTests {
    @Test("heartbeat waves confirm peers per context and allow one p2p resync")
    func heartbeatWaveTracking() {
        let local = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let peer = UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!
        let now = Date(timeIntervalSince1970: 10)
        let liveness = KeepTalkingContextLivenessState(
            localNode: local
        )

        let firstWave = liveness.beginHeartbeatWave(
            minimumInterval: 5,
            now: now
        )
        #expect(firstWave == liveness.beginHeartbeatWave(
            minimumInterval: 5,
            now: now.addingTimeInterval(1)
        ))
        #expect(!liveness.shouldNotifyPeerConnect(peer, source: .p2p))
        #expect(!liveness.isNodeOnline(peer))

        let firstPresence = liveness.observePresence(
            from: peer,
            echoCooldown: 1,
            now: now.addingTimeInterval(0.1)
        )
        #expect(firstPresence.confirmedCurrentWave)
        #expect(firstPresence.shouldEcho)
        #expect(
            liveness.shouldNotifyPeerConnect(peer, source: .presence)
        )
        #expect(
            !liveness.shouldNotifyPeerConnect(peer, source: .presence)
        )
        #expect(
            liveness.shouldNotifyPeerConnect(peer, source: .p2p)
        )
        #expect(
            !liveness.shouldNotifyPeerConnect(peer, source: .p2p)
        )
        #expect(liveness.isNodeOnline(peer))
        #expect(liveness.onlineNodeIDs() == Set([local, peer]))

        let duplicatePresence = liveness.observePresence(
            from: peer,
            echoCooldown: 1,
            now: now.addingTimeInterval(0.2)
        )
        #expect(!duplicatePresence.confirmedCurrentWave)
        #expect(!duplicatePresence.shouldEcho)

        let secondWave = liveness.beginHeartbeatWave(
            minimumInterval: 5,
            now: now.addingTimeInterval(6)
        )
        #expect(secondWave != firstWave)
        #expect(!liveness.isNodeOnline(peer))

        let secondPresence = liveness.observePresence(
            from: peer,
            echoCooldown: 1,
            now: now.addingTimeInterval(6.1)
        )
        #expect(secondPresence.confirmedCurrentWave)
        #expect(secondPresence.shouldEcho)
        #expect(
            liveness.shouldNotifyPeerConnect(peer, source: .presence)
        )
    }

    @Test("separate context liveness states advance independently")
    func contextLivenessIsolation() {
        let local = UUID(uuidString: "CCCCCCCC-2222-2222-2222-222222222222")!
        let peer = UUID(uuidString: "DDDDDDDD-3333-3333-3333-333333333333")!
        let first = KeepTalkingContextLivenessState(localNode: local)
        let second = KeepTalkingContextLivenessState(localNode: local)

        _ = first.beginHeartbeatWave(
            minimumInterval: 5,
            now: Date(timeIntervalSince1970: 5)
        )
        _ = second.beginHeartbeatWave(
            minimumInterval: 5,
            now: Date(timeIntervalSince1970: 6)
        )
        _ = first.observePresence(
            from: peer,
            echoCooldown: 1,
            now: Date(timeIntervalSince1970: 5.1)
        )

        #expect(first.isNodeOnline(peer))
        #expect(!second.isNodeOnline(peer))

        _ = second.observePresence(
            from: peer,
            echoCooldown: 1,
            now: Date(timeIntervalSince1970: 6.1)
        )

        #expect(second.isNodeOnline(peer))

        _ = first.beginHeartbeatWave(
            minimumInterval: 5,
            now: Date(timeIntervalSince1970: 12)
        )

        #expect(!first.isNodeOnline(peer))
        #expect(second.isNodeOnline(peer))
    }
}
