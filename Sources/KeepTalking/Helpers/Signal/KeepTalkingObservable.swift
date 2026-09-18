import Foundation

/// Anything a host can `observe` or iterate: `KeepTalkingSignal` and
/// `KeepTalkingStateSignal`.
public protocol KeepTalkingObservable: Sendable {
    associatedtype Value: Sendable

    /// Registers `handler` for every value emitted from now on (a state
    /// signal also replays its current value first). Handlers run one at a
    /// time, in emission order, on the signal's own task — never inline on
    /// the producer — so they may be slow-ish but must not block.
    @discardableResult
    func observe(_ handler: @escaping @Sendable (Value) -> Void) -> KeepTalkingSignalSubscription

    /// The same values as an `AsyncStream`. A new stream per access; it ends
    /// when the consuming task is cancelled or the signal's owner is released.
    var values: AsyncStream<Value> { get }
}
