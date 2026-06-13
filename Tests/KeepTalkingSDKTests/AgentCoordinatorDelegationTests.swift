import Foundation
import Testing

@testable import KeepTalkingSDK

/// Exercises the delegation primitives on `AgentCoordinator` — cancel-only runs
/// that a node executes on behalf of a caller (provider-side ACT). Pure: no LLM,
/// no subprocess, just the queue/await/cancel mechanics.
struct AgentCoordinatorDelegationTests {

    private struct SampleError: Error, Equatable {}

    @Test("runDelegated awaits and returns the work's typed result")
    func returnsResult() async throws {
        let coordinator = AgentCoordinator()
        let value = try await coordinator.runDelegated(
            contextID: UUID(), label: "compute"
        ) {
            7 * 6
        }
        #expect(value == 42)
    }

    @Test("runDelegated propagates a thrown error")
    func propagatesError() async throws {
        let coordinator = AgentCoordinator()
        await #expect(throws: SampleError.self) {
            _ = try await coordinator.runDelegated(
                contextID: UUID(), label: "boom"
            ) {
                throw SampleError()
            }
        }
    }

    @Test("a failed delegated run is NOT parked as retryable (no double-resume)")
    func failedDelegatedRunNotRetryable() async throws {
        let coordinator = AgentCoordinator()
        let runID = UUID()
        await #expect(throws: SampleError.self) {
            _ = try await coordinator.runDelegated(
                runID: runID, contextID: UUID(), label: "boom"
            ) {
                throw SampleError()
            }
        }
        // A delegated run already unwound its one-shot continuation when it threw;
        // it must NOT be parked in `failed`, or retry() would re-run it and fire
        // that continuation a second time (fatal). retry must report nothing to do.
        let retried = await coordinator.retry(runID: runID)
        #expect(retried == false)
    }

    @Test("cancelling a QUEUED delegated run unwinds it (no hang)")
    func cancellingQueuedRunUnwinds() async throws {
        let coordinator = AgentCoordinator()
        let contextID = UUID()

        // Occupy the context's active slot with a long blocker.
        let blockerID = UUID()
        let blocker = Task {
            try? await coordinator.runDelegated(
                runID: blockerID, contextID: contextID, label: "blocker"
            ) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
        }
        // Let the blocker take the active slot.
        try await Task.sleep(nanoseconds: 150_000_000)

        // This second run for the same context queues behind the blocker.
        let queuedID = UUID()
        let queued = Task {
            try await coordinator.runDelegated(
                runID: queuedID, contextID: contextID, label: "queued"
            ) {
                99
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        // Cancelling a still-queued run must resume its awaiter with cancellation
        // — the path that previously dropped the item without firing onCompleted.
        await coordinator.cancel(runID: queuedID)
        await #expect(throws: CancellationError.self) {
            _ = try await queued.value
        }
        blocker.cancel()
    }

    @Test("cancelling an ACTIVE delegated run unwinds it")
    func cancellingActiveRunUnwinds() async throws {
        let coordinator = AgentCoordinator()
        let contextID = UUID()
        let runID = UUID()
        let run = Task {
            try await coordinator.runDelegated(
                runID: runID, contextID: contextID, label: "long"
            ) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await coordinator.cancel(runID: runID)
        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
    }

    @Test("detached delegated run reports completion via the callback")
    func detachedRunReportsCompletion() async throws {
        let coordinator = AgentCoordinator()
        let box = ResultProbe()
        await coordinator.runDelegatedDetached(
            contextID: UUID(), label: "detached",
            work: { 123 },
            onComplete: { result in box.store(result) }
        )
        // Poll briefly for the async completion callback.
        for _ in 0..<50 {
            if box.value != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.value == 123)
    }

    private final class ResultProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int?
        var value: Int? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        func store(_ result: Result<Int, Error>) {
            lock.lock()
            defer { lock.unlock() }
            stored = try? result.get()
        }
    }
}
