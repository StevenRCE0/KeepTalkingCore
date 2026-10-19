import Foundation

extension KeepTalkingObservable {
    /// `observe(_:)` for a host that drives UI: every value is hopped onto the
    /// main actor in its own task, so the signal's pump never waits on the
    /// main thread and `handler` may await freely. A state signal's replay
    /// arrives the same way. Hops are enqueued in emission order, but a
    /// handler that suspends lets the next value's hop overtake it — fine for
    /// "apply the latest" state, wrong for a strict FIFO consumer, which
    /// should `observe` and serialize the hop itself.
    ///
    /// Database work the handler does runs on `lane` — `.utility` unless
    /// said otherwise, since a signal-driven refresh is never what the user
    /// is waiting on.
    @discardableResult
    public func observeOnMain(
        lane: KeepTalkingDatabaseLane = .utility,
        _ handler: @escaping @MainActor @Sendable (Value) async -> Void
    ) -> KeepTalkingSignalSubscription {
        observe { value in
            // The lane is bound around creating the task, which inherits it,
            // rather than inside: the async `withValue` suspends before the
            // handler starts, and on Linux that alone let later values
            // overtake earlier ones.
            KeepTalkingDatabaseLane.$explicit.withValue(lane) {
                _ = Task { @MainActor () -> Void in await handler(value) }
            }
        }
    }
}
