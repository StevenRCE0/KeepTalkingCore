import Foundation

extension KeepTalkingObservable {
    /// `observe(_:)` for a host that drives UI: every value is hopped onto the
    /// main actor in its own task, so the signal's pump never waits on the
    /// main thread and `handler` may await freely. A state signal's replay
    /// arrives the same way. Hops are enqueued in emission order, but a
    /// handler that suspends lets the next value's hop overtake it — fine for
    /// "apply the latest" state, wrong for a strict FIFO consumer, which
    /// should `observe` and serialize the hop itself.
    @discardableResult
    public func observeOnMain(
        _ handler: @escaping @MainActor @Sendable (Value) async -> Void
    ) -> KeepTalkingSignalSubscription {
        observe { value in
            Task { @MainActor in await handler(value) }
        }
    }
}
