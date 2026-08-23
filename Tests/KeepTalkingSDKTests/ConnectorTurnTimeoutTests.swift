import Foundation
import Testing

@testable import KeepTalkingSDK

/// `awaitTurnRequest` is the wall clock over one LLM completion request.
/// AIProxy's `secondsToWait` is only an idle timer (reset by every received
/// byte), so a slow-dripping provider can outlive it forever and hang the
/// whole agent run with no error surfaced — these pin the three outcomes:
/// fast result passes through, a stall becomes a timeout error, and a user
/// cancel stays a cancel.
struct ConnectorTurnTimeoutTests {

    @Test("a request that finishes in time passes its result through")
    func fastRequestPassesThrough() async throws {
        let value = try await awaitTurnRequest(wallClockSeconds: 5) { "done" }
        #expect(value == "done")
    }

    @Test("a stalled request fails with the timeout error, not a hang")
    func stalledRequestTimesOut() async throws {
        await #expect(throws: AIConnectorTurnTimeoutError.self) {
            try await awaitTurnRequest(wallClockSeconds: 1) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return "never"
            }
        }
    }

    @Test("parent cancellation surfaces as CancellationError, never as a timeout")
    func parentCancellationStaysACancel() async throws {
        let task = Task {
            try await awaitTurnRequest(wallClockSeconds: 60) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return "never"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
