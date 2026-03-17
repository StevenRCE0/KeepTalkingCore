import Foundation

final class KeepTalkingContextLivenessState: @unchecked Sendable {
    enum Source {
        case presence
        case p2p
    }

    struct PresenceObservation {
        let confirmedCurrentWave: Bool
        let shouldEcho: Bool
    }

    private let localNode: UUID
    private let queue = DispatchQueue(
        label: "KeepTalking.context-liveness"
    )

    private var currentWave = UUID()
    private var lastWaveStartedAt: Date = .distantPast
    private var confirmedPeers = Set<UUID>()
    private var notifiedPresencePeers = Set<UUID>()
    private var notifiedP2PPeers = Set<UUID>()
    private var lastEchoAtByPeer: [UUID: Date] = [:]
    private var lastSeenAtByPeer: [UUID: Date] = [:]

    init(localNode: UUID) {
        self.localNode = localNode
    }

    @discardableResult
    func beginHeartbeatWave(
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) -> UUID {
        queue.sync {
            guard
                now.timeIntervalSince(lastWaveStartedAt) >= minimumInterval
            else {
                return currentWave
            }

            currentWave = UUID()
            lastWaveStartedAt = now
            confirmedPeers.removeAll()
            notifiedPresencePeers.removeAll()
            notifiedP2PPeers.removeAll()
            return currentWave
        }
    }

    func observePresence(
        from node: UUID,
        echoCooldown: TimeInterval,
        now: Date = Date()
    ) -> PresenceObservation {
        queue.sync {
            lastSeenAtByPeer[node] = max(
                lastSeenAtByPeer[node] ?? .distantPast,
                now
            )

            let confirmedCurrentWave = confirmedPeers.insert(node).inserted
            let shouldEcho =
                now.timeIntervalSince(
                    lastEchoAtByPeer[node] ?? .distantPast
                ) >= echoCooldown

            if shouldEcho {
                lastEchoAtByPeer[node] = now
            }

            return PresenceObservation(
                confirmedCurrentWave: confirmedCurrentWave,
                shouldEcho: shouldEcho
            )
        }
    }

    func shouldNotifyPeerConnect(_ node: UUID, source: Source) -> Bool {
        guard node != localNode else {
            return false
        }

        return queue.sync {
            guard confirmedPeers.contains(node) else {
                return false
            }

            switch source {
                case .presence:
                    return notifiedPresencePeers.insert(node).inserted
                case .p2p:
                    return notifiedP2PPeers.insert(node).inserted
            }
        }
    }

    func isNodeOnline(_ node: UUID) -> Bool {
        guard node != localNode else {
            return true
        }

        return queue.sync {
            confirmedPeers.contains(node)
        }
    }

    func onlineNodeIDs() -> Set<UUID> {
        queue.sync {
            confirmedPeers.union([localNode])
        }
    }

    func lastSeenAt(for node: UUID) -> Date? {
        guard node != localNode else {
            return Date()
        }

        return queue.sync {
            lastSeenAtByPeer[node]
        }
    }

    func reset() {
        queue.sync {
            confirmedPeers.removeAll()
            notifiedPresencePeers.removeAll()
            notifiedP2PPeers.removeAll()
            lastEchoAtByPeer.removeAll()
            lastSeenAtByPeer.removeAll()
            lastWaveStartedAt = .distantPast
        }
    }
}
