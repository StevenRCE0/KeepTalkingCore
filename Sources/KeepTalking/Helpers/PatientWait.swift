import Foundation

/// Awaits `operation` with *patience* instead of a hard deadline.
///
/// For the first `graceSeconds` the wait is silent and unconditional. If the
/// operation has not finished by then, the wait stops counting down and starts
/// *polling*: every `pollSeconds` it asks `isAlive` whether the thing being
/// waited on is still around. As long as it is, the wait continues
/// indefinitely. The wait ends only when one of the following happens:
///
/// 1. `operation` returns or throws — its outcome is propagated as-is.
/// 2. `isAlive` reports the target has died — `onDeath()` is thrown and the
///    in-flight `operation` is cancelled.
/// 3. The surrounding task is cancelled — both the operation and the watchdog
///    unwind and `CancellationError` propagates.
///
/// - Important: `operation` MUST be cancellation-aware. For continuation-based
///   waits, wrap the continuation in `withTaskCancellationHandler` so a
///   cancelled parent resumes it; otherwise the group can hang on a leaked
///   continuation during teardown.
/// - Parameter onPoll: Optional hook invoked once per poll (after the grace
///   period) with the elapsed seconds. When provided it replaces the default
///   "still waiting" log line — use it to surface progress (e.g. tail a
///   redirected output file) or run a custom liveness side-effect.
func patientWait<T: Sendable>(
    label: String,
    graceSeconds: TimeInterval = 10,
    pollSeconds: TimeInterval = 5,
    log: (@Sendable (String) -> Void)? = nil,
    isAlive: @escaping @Sendable () async -> Bool,
    onDeath: @escaping @Sendable () -> Error,
    onPoll: (@Sendable (TimeInterval) async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            // Grace period: wait quietly before we start fussing about it.
            try await Task.sleep(nanoseconds: patientWaitNanos(graceSeconds))
            var waited = graceSeconds
            while true {
                try Task.checkCancellation()
                guard await isAlive() else {
                    throw onDeath()
                }
                if let onPoll {
                    await onPoll(waited)
                } else {
                    log?("[patient] \(label) still waiting after \(Int(waited))s")
                }
                try await Task.sleep(nanoseconds: patientWaitNanos(pollSeconds))
                waited += pollSeconds
            }
        }

        // Whichever finishes first wins. The watchdog never *returns* — it only
        // throws (death or cancellation) — so a returned value is always the
        // operation's result. A thrown error (from either child) propagates and
        // `withThrowingTaskGroup` cancels + drains the remaining child.
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return first
    }
}

private func patientWaitNanos(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(seconds, 0) * 1_000_000_000)
}
