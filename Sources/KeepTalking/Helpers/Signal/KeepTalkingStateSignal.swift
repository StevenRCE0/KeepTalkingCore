import Foundation
import NIOConcurrencyHelpers
import Observation

/// An event signal with a synchronously readable current value.
///
/// Subscribing replays `current` before any later emission. The value is the
/// one place a lock survives: an actor cannot offer a synchronous read, so an
/// `NIOLockedValueBox` guards it — and `send` writes the value and yields
/// the emission inside the same critical section, so replay, emissions and
/// `current` can never disagree about order.
///
/// The signal is also `Observable`: reading ``current`` inside a SwiftUI body
/// or a `withObservationTracking` closure registers a dependency, and every
/// `send` that changes the value invalidates it. Observation sees only the
/// *latest* value — it is the right seam for "render the current state", while
/// ``observe(_:)`` and ``values`` remain the seam for "every transition, in
/// order".
public final class KeepTalkingStateSignal<Value: Sendable>: KeepTalkingObservable, Observable, Sendable {
    public typealias Subscription = KeepTalkingSignalSubscription

    private let signal = KeepTalkingSignal<Value>()
    private let state: NIOLockedValueBox<Value>
    private let registrar = ObservationRegistrar()

    public init(_ initial: Value) {
        state = NIOLockedValueBox(initial)
    }

    /// The last value sent (or the initial one). Observation-tracked.
    public var current: Value {
        registrar.access(self, keyPath: \.current)
        return state.withLockedValue { $0 }
    }

    /// Tells Observation that `current` changed. Called *after* the lock is
    /// released, never inside it: an observer's `onChange` runs inline on the
    /// producer's thread, and host code there must be free to read `current`
    /// (or call back into the client) without deadlocking on the box. A
    /// notification that lands a beat after the write loses nothing — every
    /// Observation consumer re-reads `current` rather than receiving a value.
    private func notifyObservers() {
        registrar.willSet(self, keyPath: \.current)
        registrar.didSet(self, keyPath: \.current)
    }

    @discardableResult
    public func observe(
        _ handler: @escaping @Sendable (Value) -> Void
    ) -> Subscription {
        state.withLockedValue { current in
            signal.register(
                .init(id: UUID(), handler: handler, finish: nil, replay: current)
            )
        }
    }

    public var values: AsyncStream<Value> {
        state.withLockedValue { current in
            signal.makeStream(replay: current)
        }
    }

    /// Replaces `current` and emits it. SDK producers only.
    func send(_ value: Value) {
        state.withLockedValue { current in
            current = value
            signal.send(value)
        }
        notifyObservers()
    }
}

extension KeepTalkingStateSignal where Value: Equatable {
    /// Emits only when `value` differs from `current`. Returns whether it did.
    @discardableResult
    func send(ifChanged value: Value) -> Bool {
        let changed: Bool = state.withLockedValue { current in
            guard current != value else { return false }
            current = value
            signal.send(value)
            return true
        }
        if changed { notifyObservers() }
        return changed
    }
}
