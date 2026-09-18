import Foundation
import Testing

@testable import KeepTalkingSDK

/// Records everything a signal delivers, in order. Signals deliver
/// asynchronously, so tests wait for a count (bounded) or let the pump
/// settle before asserting on absence.
final class SignalRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    init() {}

    func record(_ value: Value) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [Value] {
        lock.withLock { values }
    }

    /// Waits until at least `count` values arrived, or `timeout` elapsed.
    func waitForCount(_ count: Int, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while snapshot.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Gives queued deliveries time to land, for "nothing more arrives" checks.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }
}

/// Parks `start()` in a fake transport until a test opens it.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Races `body` against a timeout; nil means it did not finish in time.
func withTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(5),
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
