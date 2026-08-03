import Foundation
import Testing

@testable import KeepTalkingSDK

/// Covers the suspend/observe/cancel bookkeeping on `AgentCoordinator`. A run that
/// parks on a continuation must be observable as `.suspended` by hosts listening on
/// snapshots, and cancelling it must unwind its parked continuation rather than
/// leaving the task awaiting a response that will never arrive.
///
/// Both hinge on `suspensionContinuations` being keyed by continuation-message id
/// while `suspended` is keyed by agentTurnID — the two must be bridged through
/// `continuationTurnIDs`, never indexed with each other's key.
struct AgentCoordinatorSuspensionTests {

    @Test("a run parked on a continuation is reported as .suspended")
    func parkedRunReportsSuspended() async throws {
        let coordinator = AgentCoordinator()
        let contextID = UUID()
        let agentTurnID = UUID()
        let runID = UUID()

        await coordinator.enqueue(
            id: runID,
            contextID: contextID,
            agentTurnID: agentTurnID,
            promptPreview: "parks",
            work: {
                _ = try await coordinator.awaitContinuation(
                    continuationID: UUID(),
                    agentTurnID: agentTurnID,
                    contextID: contextID
                )
            }
        )

        let state = await waitForState(of: runID, in: coordinator) { $0 == .suspended }
        #expect(state == .suspended)

        await coordinator.cancelSuspended(agentTurnID: agentTurnID)
    }

    @Test("a resumed run stops being reported as .suspended")
    func resumedRunReportsRunning() async throws {
        let coordinator = AgentCoordinator()
        let contextID = UUID()
        let agentTurnID = UUID()
        let continuationID = UUID()
        let runID = UUID()
        let release = Gate()

        await coordinator.enqueue(
            id: runID,
            contextID: contextID,
            agentTurnID: agentTurnID,
            promptPreview: "parks",
            work: {
                _ = try await coordinator.awaitContinuation(
                    continuationID: continuationID,
                    agentTurnID: agentTurnID,
                    contextID: contextID
                )
                // Stay alive past the resume so the snapshot can be inspected.
                await release.wait()
            }
        )

        let parked = await waitForState(of: runID, in: coordinator) { $0 == .suspended }
        #expect(parked == .suspended)

        await coordinator.deliverContinuationResponse(
            response(
                continuationID: continuationID,
                agentTurnID: agentTurnID,
                contextID: contextID
            )
        )

        let resumed = await waitForState(of: runID, in: coordinator) { $0 == .running }
        #expect(resumed == .running)

        release.open()
    }

    @Test("cancelling a suspended run unwinds its parked continuation")
    func cancellingSuspendedRunUnwindsContinuation() async throws {
        let coordinator = AgentCoordinator()
        let contextID = UUID()
        let agentTurnID = UUID()
        let runID = UUID()
        let outcome = OutcomeProbe()

        await coordinator.enqueue(
            id: runID,
            contextID: contextID,
            agentTurnID: agentTurnID,
            promptPreview: "parks",
            work: {
                do {
                    _ = try await coordinator.awaitContinuation(
                        continuationID: UUID(),
                        agentTurnID: agentTurnID,
                        contextID: contextID
                    )
                    outcome.settle(nil)
                } catch {
                    outcome.settle(error)
                    throw error
                }
            }
        )

        // Only cancel once the run has genuinely parked — cancelling while it is
        // still active exercises the active path (task.cancel()) instead, which
        // unwinds for an unrelated reason.
        let parked = await waitForState(of: runID, in: coordinator) { $0 == .suspended }
        try #require(parked == .suspended)

        await coordinator.cancel(runID: runID)

        await waitUntil { outcome.hasSettled }
        #expect(outcome.hasSettled)
        #expect((outcome.error as? CancellationError) != nil)

        // A cancelled run leaves no snapshot behind.
        let remaining = await coordinator.currentSnapshots.first { $0.id == runID }
        #expect(remaining == nil)
    }

    @Test("cancelling one suspended run leaves another context's parked run alone")
    func cancellingSuspendedRunIsScopedToItsTurn() async throws {
        let coordinator = AgentCoordinator()
        let survivorTurnID = UUID()
        let survivorRunID = UUID()
        let survivorOutcome = OutcomeProbe()
        let doomedTurnID = UUID()
        let doomedRunID = UUID()

        for (runID, turnID, probe) in [
            (survivorRunID, survivorTurnID, survivorOutcome),
            (doomedRunID, doomedTurnID, OutcomeProbe()),
        ] {
            let contextID = UUID()
            await coordinator.enqueue(
                id: runID,
                contextID: contextID,
                agentTurnID: turnID,
                promptPreview: "parks",
                work: {
                    do {
                        _ = try await coordinator.awaitContinuation(
                            continuationID: UUID(),
                            agentTurnID: turnID,
                            contextID: contextID
                        )
                        probe.settle(nil)
                    } catch {
                        probe.settle(error)
                        throw error
                    }
                }
            )
        }

        try #require(
            await waitForState(of: survivorRunID, in: coordinator) { $0 == .suspended }
                == .suspended
        )
        try #require(
            await waitForState(of: doomedRunID, in: coordinator) { $0 == .suspended }
                == .suspended
        )

        await coordinator.cancel(runID: doomedRunID)
        await waitUntil { false }  // settle time for any mis-targeted resume

        #expect(survivorOutcome.hasSettled == false)
        let survivor = await coordinator.currentSnapshots.first { $0.id == survivorRunID }
        #expect(survivor?.state == .suspended)

        await coordinator.cancelSuspended(agentTurnID: survivorTurnID)
    }

    // MARK: - Helpers

    /// Polls `currentSnapshots` for `runID` until `predicate` holds, then returns the
    /// matching state — or whatever the state was when the budget ran out.
    private func waitForState(
        of runID: UUID,
        in coordinator: AgentCoordinator,
        matching predicate: (KeepTalkingAgentRunSnapshot.State) -> Bool
    ) async -> KeepTalkingAgentRunSnapshot.State? {
        var latest: KeepTalkingAgentRunSnapshot.State?
        for _ in 0..<100 {
            latest = await coordinator.currentSnapshots.first { $0.id == runID }?.state
            if let latest, predicate(latest) { return latest }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return latest
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func response(
        continuationID: UUID,
        agentTurnID: UUID,
        contextID: UUID
    ) -> KeepTalkingAgentTurnContinuationResponse {
        KeepTalkingAgentTurnContinuationResponse(
            continuationMessageID: continuationID,
            agentTurnID: agentTurnID,
            contextID: contextID,
            responderNodeID: UUID(),
            originNodeID: UUID(),
            state: .fulfilled,
            encryptedPayload: Data()
        )
    }

    /// Records how a parked run's `awaitContinuation` unwound: `nil` error means it
    /// returned a response, a stored error means it threw.
    private final class OutcomeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?
        private var settled = false

        func settle(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            stored = error
            settled = true
        }

        var hasSettled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return settled
        }

        var error: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// One-shot latch used to hold a resumed run alive while its snapshot is read.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func open() { semaphore.signal() }
        func wait() async {
            while semaphore.wait(timeout: .now()) == .timedOut {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}
