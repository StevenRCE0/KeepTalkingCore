import Foundation
import Testing

@testable import KeepTalkingSDK

struct ContextScanQueueTests {
    private struct ScanFailure: Error {}

    @Test("a request joins a queued scan, never one already running")
    func joinsQueuedScanOnly() async throws {
        let queue = KeepTalkingContextScanQueue()
        let context = UUID()
        let starts = SignalRecorder<Int>()
        let firstRelease = TestGate()

        let first = Task {
            try await queue.run(
                for: queue, context: context,
                Self.taggedScan(1, starts: starts, release: firstRelease))
        }
        await starts.waitForCount(1)
        // Scan 1 is running and may have read the store before these two
        // callers wrote — they must get a scan of their own.
        let second = Task {
            try await queue.run(for: queue, context: context, Self.taggedScan(2, starts: starts))
        }
        let third = Task {
            try await queue.run(for: queue, context: context, Self.taggedScan(3, starts: starts))
        }
        await starts.settle()
        await firstRelease.open()

        // Whichever of the two enqueued first supplied the shared scan.
        let joined = try await second.value
        #expect(try await first.value == 1)
        #expect([2, 3].contains(joined))
        #expect(try await third.value == joined)
        #expect(starts.snapshot == [1, joined])
    }

    @Test("unkeyed scans never join each other")
    func unkeyedScansRunSeparately() async throws {
        let queue = KeepTalkingContextScanQueue()
        let starts = SignalRecorder<Int>()
        let firstRelease = TestGate()

        let first = Task {
            try await queue.run(Self.taggedScan(1, starts: starts, release: firstRelease))
        }
        await starts.waitForCount(1)
        let second = Task { try await queue.run(Self.taggedScan(2, starts: starts)) }
        let third = Task { try await queue.run(Self.taggedScan(3, starts: starts)) }
        await starts.settle()
        await firstRelease.open()

        #expect(try await first.value == 1)
        #expect(Set([try await second.value, try await third.value]) == [2, 3])
        #expect(starts.snapshot.count == 3)
    }

    @Test("scans run one at a time")
    func scansNeverOverlap() async throws {
        let queue = KeepTalkingContextScanQueue()
        let tracker = OverlapTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                let context = UUID()
                group.addTask {
                    try await queue.run(for: queue, context: context) {
                        tracker.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        tracker.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(tracker.maximum == 1)
        #expect(tracker.total == 8)
    }

    @Test("a high-priority caller does not lift the scan's priority")
    func scanRunsAtBackgroundPriority() async throws {
        let queue = KeepTalkingContextScanQueue()

        let priority = try await Task(priority: .userInitiated) {
            try await queue.run { Task.currentPriority }
        }.value

        #expect(priority == .background)
    }

    @Test("a failed scan fails everyone waiting on it, and the queue keeps draining")
    func failureReachesEveryWaiter() async throws {
        let queue = KeepTalkingContextScanQueue()
        let context = UUID()
        let starts = SignalRecorder<Int>()
        let firstRelease = TestGate()

        let first = Task {
            try await queue.run(
                for: queue, context: context,
                Self.taggedScan(1, starts: starts, release: firstRelease))
        }
        await starts.waitForCount(1)
        let failing: @Sendable () async throws -> Int = { throw ScanFailure() }
        let second = Task { try await queue.run(for: queue, context: context, failing) }
        let third = Task { try await queue.run(for: queue, context: context, failing) }
        await starts.settle()
        await firstRelease.open()

        _ = try await first.value
        await #expect(throws: ScanFailure.self) { try await second.value }
        await #expect(throws: ScanFailure.self) { try await third.value }

        let after = await withTimeout {
            try? await queue.run(for: queue, context: context, Self.taggedScan(4, starts: starts))
        }
        #expect(after == 4)
    }

    @Test("a paged read returns every row exactly once across page boundaries")
    func pagedReadCoversEveryRow() async throws {
        let pageSize = KeepTalkingContextScanQueue.pageSize
        let ids = (0..<(pageSize * 2 + 3)).map { _ in UUID() }.sorted {
            $0.uuidString < $1.uuidString
        }
        let pages = SignalRecorder<Int>()

        let rows = try await KeepTalkingContextScanQueue.readPaged(id: { $0 }) {
            after, limit in
            pages.record(limit)
            let rest = after.map { cursor in ids.drop { $0.uuidString <= cursor.uuidString } }
            return Array((rest ?? ids[...]).prefix(limit))
        }

        #expect(rows == ids)
        #expect(pages.snapshot.count == 3)
    }

    // MARK: - Helpers

    /// Stands in for scan `number`, returning the number so a caller can tell
    /// which scan it got.
    private static func taggedScan(
        _ number: Int,
        starts: SignalRecorder<Int>,
        release: TestGate? = nil
    ) -> @Sendable () async throws -> Int {
        {
            starts.record(number)
            await release?.wait()
            return number
        }
    }
}

/// Counts scans in flight and the most ever in flight at once.
private final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0
    private(set) var total = 0

    func enter() {
        lock.withLock {
            current += 1
            total += 1
            maximum = max(maximum, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}
