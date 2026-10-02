import Foundation

/// Where a publish goes. Receivers accept both routes, so senders never have
/// to agree on a mode.
@_spi(TransportLab)
public enum KeepTalkingIrohDeliveryPolicy: Sendable, Hashable {
    /// The SFU once the room has at least `sfuAtMembers` other members, the
    /// mesh below that; whichever route is up when the other isn't.
    case automatic(sfuAtMembers: Int)
    /// Mesh; the SFU only while no member is known.
    case preferMesh
    /// SFU; the mesh only while the SFU is down.
    case preferSFU

    public static let standard = KeepTalkingIrohDeliveryPolicy.automatic(sfuAtMembers: 4)
}

@_spi(TransportLab)
public enum KeepTalkingIrohRoute: String, Sendable {
    case mesh
    case sfu
}

enum KeepTalkingIrohDelivery {
    /// The policy's pick for a broadcast to a room with `members` known
    /// members, falling back to whichever route exists. The mesh counts
    /// every known member, connected or not: each has a queue its next
    /// link drains, relay or direct, so the mesh never waits on paths.
    static func route(
        _ policy: KeepTalkingIrohDeliveryPolicy,
        sfuUsable: Bool,
        members: Int
    ) -> KeepTalkingIrohRoute? {
        let mesh = members > 0
        let preferSFU: Bool
        switch policy {
            case .automatic(let threshold): preferSFU = members >= threshold
            case .preferMesh: preferSFU = false
            case .preferSFU: preferSFU = true
        }
        if preferSFU { return sfuUsable ? .sfu : (mesh ? .mesh : nil) }
        return mesh ? .mesh : (sfuUsable ? .sfu : nil)
    }
}

/// Byte-bounded FIFO queues of encoded frames, one per destination: a
/// member's network id (drained by whichever link carries that member), a
/// link's own id (frames for that link only, like hellos), and the SFU.
///
/// A full member queue drops its oldest frames: the member is unreachable or
/// slow, and the resync when it comes back covers the gap.
struct KeepTalkingIrohOutbound: Sendable {
    let budget: Int
    private var queues: [Data: Queue] = [:]

    private struct Queue: Sendable {
        var frames: [Data] = []
        var bytes = 0
        var dropped = 0
    }

    init(budget: Int) {
        self.budget = budget
    }

    /// Queues `frame`, dropping the oldest to stay within budget; returns how
    /// many frames were dropped.
    @discardableResult
    mutating func enqueue(_ frame: Data, for key: Data) -> Int {
        var queue = queues[key] ?? Queue()
        queue.frames.append(frame)
        queue.bytes += frame.count
        var dropped = 0
        while queue.bytes > budget, queue.frames.count > 1 {
            queue.bytes -= queue.frames.removeFirst().count
            dropped += 1
        }
        queue.dropped += dropped
        queues[key] = queue
        return dropped
    }

    /// Puts `frames` ahead of what's queued (e.g. re-subscribing before
    /// queued publishes), regardless of budget.
    mutating func prepend(_ frames: [Data], for key: Data) {
        guard !frames.isEmpty else { return }
        var queue = queues[key] ?? Queue()
        queue.frames.insert(contentsOf: frames, at: 0)
        queue.bytes += frames.reduce(0) { $0 + $1.count }
        queues[key] = queue
    }

    func fits(_ bytes: Int, for key: Data) -> Bool {
        (queues[key]?.bytes ?? 0) + bytes <= budget
    }

    /// Takes frames off the front, at least one and up to `maxBytes`.
    mutating func drain(_ key: Data, upTo maxBytes: Int = 512 * 1024) -> [Data] {
        guard var queue = queues[key], !queue.frames.isEmpty else { return [] }
        var taken = 0
        var bytes = 0
        for frame in queue.frames {
            if taken > 0, bytes + frame.count > maxBytes { break }
            taken += 1
            bytes += frame.count
        }
        let batch = Array(queue.frames.prefix(taken))
        queue.frames.removeFirst(taken)
        queue.bytes -= bytes
        queues[key] = queue.frames.isEmpty && queue.dropped == 0 ? nil : queue
        return batch
    }

    mutating func remove(_ key: Data) {
        queues[key] = nil
    }

    func bytes(for key: Data) -> Int { queues[key]?.bytes ?? 0 }
    func isEmpty(_ key: Data) -> Bool { queues[key]?.frames.isEmpty ?? true }
    func dropped(for key: Data) -> Int { queues[key]?.dropped ?? 0 }
}

/// Hysteresis over "the network is failing us": opens once that has held for
/// `openAfter`, closes once the network has worked for `closeAfter`. Runs on
/// a suspending clock, so time the app spends suspended doesn't count.
struct KeepTalkingIrohNetworkGate: Sendable {
    typealias Instant = SuspendingClock.Instant

    let openAfter: Duration
    let closeAfter: Duration
    private(set) var isOpen = false
    private var flipSince: Instant?

    init(openAfter: Duration, closeAfter: Duration) {
        self.openAfter = openAfter
        self.closeAfter = closeAfter
    }

    /// Feeds whether the network is failing now; returns the new state when
    /// the gate flips.
    mutating func update(failing: Bool, now: Instant) -> Bool? {
        guard failing != isOpen else {
            flipSince = nil
            return nil
        }
        let since = flipSince ?? now
        flipSince = since
        guard now - since >= (failing ? openAfter : closeAfter) else { return nil }
        isOpen = failing
        flipSince = nil
        return isOpen
    }
}

/// A token bucket: `rate` units a second, up to `burst` saved up. The SFU
/// drops what a client sends over its limits (publishes and announces:
/// 4 MiB/s and 200 frames/s, with bursts), so the client paces itself below
/// them instead of losing frames it thinks it sent.
struct KeepTalkingIrohPacer: Sendable {
    typealias Instant = SuspendingClock.Instant

    let rate: Double
    let burst: Double
    private var tokens: Double
    private var updatedAt: Instant?

    init(rate: Double, burst: Double) {
        self.rate = rate
        self.burst = burst
        self.tokens = burst
    }

    /// Takes `cost` units; returns how long to wait before sending.
    mutating func take(_ cost: Double, now: Instant) -> Duration {
        if let updatedAt {
            let elapsed = now - updatedAt
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            tokens = min(burst, tokens + seconds * rate)
        }
        updatedAt = now
        tokens -= cost
        guard tokens < 0 else { return .zero }
        return .seconds(-tokens / rate)
    }
}
