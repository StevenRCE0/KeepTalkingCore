import Foundation

/// Transport-level deduplication for sequenced envelopes received across multiple channels.
/// Uses a bounded set with FIFO eviction to prevent unbounded growth.
public final class KeepTalkingEnvelopeDedup: @unchecked Sendable {
    private struct Key: Hashable {
        let sender: UUID
        let sequence: UInt64
    }

    private var seen = Set<Key>()
    private var order = [Key]()
    private let lock = NSLock()
    private let capacity: Int

    public init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    /// Returns `true` if this (sender, sequence) pair has already been seen.
    /// If not seen, records it and returns `false`.
    public func checkAndRecord(sender: UUID, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let key = Key(sender: sender, sequence: sequence)
        guard seen.insert(key).inserted else {
            return true
        }

        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }

        return false
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        seen.removeAll()
        order.removeAll()
    }
}
