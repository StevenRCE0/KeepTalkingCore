import Foundation

/// Edge-triggered peer liveness.
///
/// A peer is **online** while we've seen its presence within `onlineTimeout`, and
/// it transitions **offline→online** (a "connect edge") when presence resumes
/// after a gap. Online-ness is purely time-based (last-seen), so a continuously
/// present peer (presence every ~13s) stays online and produces the connect edge
/// exactly once.
///
/// This replaces the old per-heartbeat "wave" model, which cleared the confirmed
/// set every interval and so *re-discovered* every still-present peer each wave —
/// re-firing connect-notify, presence echo, and (via the node controller) a full
/// node-status rebroadcast on a stable peer every ~13s. Callers now key those
/// reactions off `isNewConnection` instead.
final class KeepTalkingContextLivenessState: @unchecked Sendable {
    struct PresenceObservation {
        /// True only on an offline→online transition — the real connect edge.
        let isNewConnection: Bool
        /// True when we should echo our presence back (once per edge, rate-limited
        /// by `echoCooldown`).
        let shouldEcho: Bool
    }

    private let localNode: UUID
    /// A peer counts as online if seen within this window. Must comfortably exceed
    /// the transport's presence heartbeat (~13s) so a single missed/late beat
    /// doesn't flap the peer offline→online (which would resurrect the churn this
    /// model exists to kill). ~3 heartbeats.
    private let onlineTimeout: TimeInterval
    private let queue = DispatchQueue(label: "KeepTalking.context-liveness")

    private var lastSeenAtByPeer: [UUID: Date] = [:]
    private var lastEchoAtByPeer: [UUID: Date] = [:]

    init(localNode: UUID, onlineTimeout: TimeInterval = 40) {
        self.localNode = localNode
        self.onlineTimeout = onlineTimeout
    }

    /// Record a presence from `node`. Returns whether this is a connect edge (was
    /// offline, now online) and whether to echo our presence back. Both call sites
    /// (SFU presence + p2p) feed this; whichever observes first while offline wins
    /// the edge, so `onPeerConnect` fires once across sources.
    func observePresence(
        from node: UUID,
        echoCooldown: TimeInterval,
        now: Date = Date()
    ) -> PresenceObservation {
        queue.sync {
            let wasOnline = isOnlineLocked(node, now: now)
            lastSeenAtByPeer[node] = max(lastSeenAtByPeer[node] ?? .distantPast, now)

            let isNewConnection = !wasOnline
            let shouldEcho =
                isNewConnection
                && now.timeIntervalSince(lastEchoAtByPeer[node] ?? .distantPast)
                    >= echoCooldown
            if shouldEcho {
                lastEchoAtByPeer[node] = now
            }
            return PresenceObservation(
                isNewConnection: isNewConnection,
                shouldEcho: shouldEcho
            )
        }
    }

    func isNodeOnline(_ node: UUID, now: Date = Date()) -> Bool {
        guard node != localNode else { return true }
        return queue.sync { isOnlineLocked(node, now: now) }
    }

    func onlineNodeIDs(now: Date = Date()) -> Set<UUID> {
        queue.sync {
            var online: Set<UUID> = [localNode]
            for (node, seen) in lastSeenAtByPeer
            where now.timeIntervalSince(seen) < onlineTimeout {
                online.insert(node)
            }
            return online
        }
    }

    func reset() {
        queue.sync {
            lastSeenAtByPeer.removeAll()
            lastEchoAtByPeer.removeAll()
        }
    }

    /// Online == seen within `onlineTimeout`. Caller must hold `queue`.
    private func isOnlineLocked(_ node: UUID, now: Date) -> Bool {
        guard let seen = lastSeenAtByPeer[node] else { return false }
        return now.timeIntervalSince(seen) < onlineTimeout
    }
}
