import Foundation
import Testing

@testable import KeepTalkingSDK

struct KeyedCoalescerTests {
    @Test("callers that arrive while a run is queued share it; while one runs they get the next")
    func joinsQueuedRunOnly() async throws {
        let coalescer = KeepTalkingKeyedCoalescer<String>()
        let starts = SignalRecorder<Int>()
        let release = TestGate()

        let first = Task {
            try await coalescer.run("k") {
                starts.record(1)
                await release.wait()
                return 1
            }
        }
        await starts.waitForCount(1)
        // Running now: these two must see a run that starts after their call.
        let second = Task {
            try await coalescer.run("k") {
                starts.record(2)
                return 2
            }
        }
        let third = Task {
            try await coalescer.run("k") {
                starts.record(3)
                return 3
            }
        }
        await starts.settle()
        await release.open()

        #expect(try await first.value == 1)
        let joined = try await second.value
        #expect([2, 3].contains(joined))
        #expect(try await third.value == joined)
        #expect(starts.snapshot == [1, joined])
    }

    @Test("different keys run independently")
    func keysAreIndependent() async throws {
        let coalescer = KeepTalkingKeyedCoalescer<Int>()
        let inFlight = OverlapCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in 0..<4 {
                group.addTask {
                    try await coalescer.run(key) {
                        inFlight.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        inFlight.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(inFlight.maximum == 4)
    }

    @Test("a minimum interval holds the next run until it is due")
    func minimumIntervalIsHonoured() async throws {
        let coalescer = KeepTalkingKeyedCoalescer<String>()
        let starts = SignalRecorder<ContinuousClock.Instant>()
        let interval: Duration = .milliseconds(120)

        _ = try await coalescer.run("k", minimumInterval: interval) { starts.record(.now) }
        _ = try await coalescer.run("k", minimumInterval: interval) { starts.record(.now) }

        let times = starts.snapshot
        #expect(times.count == 2)
        #expect(times[1] - times[0] >= interval - .milliseconds(5))
    }

    @Test("the run binds the requested lane and does not inherit the caller's priority")
    func runBindsLane() async throws {
        let coalescer = KeepTalkingKeyedCoalescer<String>()
        let seen = try await Task(priority: .userInitiated) {
            try await coalescer.run("k", lane: .background) {
                (KeepTalkingDatabaseLane.current, Task.currentPriority)
            }
        }.value
        #expect(seen.0 == .background)
        #expect(seen.1 == .background)
    }

    @Test("a failure reaches every joined caller, and the key keeps working")
    func failurePropagates() async throws {
        struct Boom: Error {}
        let coalescer = KeepTalkingKeyedCoalescer<String>()
        let release = TestGate()
        let blocker = Task { try await coalescer.run("k") { await release.wait() } }
        try? await Task.sleep(for: .milliseconds(20))
        let a = Task { try await coalescer.run("k") { throw Boom() } }
        let b = Task { try await coalescer.run("k") { throw Boom() } }
        try? await Task.sleep(for: .milliseconds(20))
        await release.open()
        try await blocker.value
        await #expect(throws: Boom.self) { try await a.value }
        await #expect(throws: Boom.self) { try await b.value }
        #expect(try await coalescer.run("k") { 5 } == 5)
    }
}

private final class OverlapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0
    func enter() {
        lock.withLock {
            current += 1
            maximum = max(maximum, current)
        }
    }
    func leave() { lock.withLock { current -= 1 } }
}
