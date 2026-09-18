import Foundation

/// A multicast event signal — the client's push surface.
///
/// One unbounded `AsyncStream` hub receives every command (`emit`,
/// `subscribe`, `unsubscribe`) in arrival order, and one pump task drains it,
/// keeping the subscriber table as its own local state. That gives total
/// FIFO delivery with no lock in the primitive: `send` is a synchronous,
/// non-blocking `yield`, so a producer may emit while holding its own locks
/// and no handler can ever re-enter it. Handlers run on the pump task, never
/// on the producer. Releasing the signal finishes the hub; the pump drains
/// what is queued and then ends every live `values` stream.
public final class KeepTalkingSignal<Value: Sendable>: KeepTalkingObservable, Sendable {
    public typealias Subscription = KeepTalkingSignalSubscription

    struct Subscriber: Sendable {
        let id: UUID
        let handler: @Sendable (Value) -> Void
        /// Set for `values` streams: ends the stream when the signal is
        /// released.
        let finish: (@Sendable () -> Void)?
        /// Delivered first, before any later emission (state signals only).
        let replay: Value?
    }

    enum Command: Sendable {
        case emit(Value)
        case subscribe(Subscriber)
        case unsubscribe(UUID)
    }

    private let hub: AsyncStream<Command>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream<Command>.makeStream(
            bufferingPolicy: .unbounded
        )
        hub = continuation
        Task.detached(priority: .userInitiated) {
            await Self.pump(stream)
        }
    }

    deinit {
        hub.finish()
    }

    /// The single consumer of the hub. Captures nothing but the stream, so
    /// the signal can be released while the pump is parked.
    private static func pump(_ stream: AsyncStream<Command>) async {
        var subscribers: [UUID: Subscriber] = [:]
        var order: [UUID] = []
        for await command in stream {
            switch command {
                case .emit(let value):
                    for id in order {
                        subscribers[id]?.handler(value)
                    }
                case .subscribe(let subscriber):
                    subscribers[subscriber.id] = subscriber
                    order.append(subscriber.id)
                    if let replay = subscriber.replay {
                        subscriber.handler(replay)
                    }
                case .unsubscribe(let id):
                    if subscribers.removeValue(forKey: id) != nil {
                        order.removeAll { $0 == id }
                    }
            }
        }
        for id in order {
            subscribers[id]?.finish?()
        }
    }

    @discardableResult
    public func observe(
        _ handler: @escaping @Sendable (Value) -> Void
    ) -> Subscription {
        register(Subscriber(id: UUID(), handler: handler, finish: nil, replay: nil))
    }

    public var values: AsyncStream<Value> {
        makeStream(replay: nil)
    }

    /// Emits `value` to every subscriber, in order. SDK producers only.
    func send(_ value: Value) {
        hub.yield(.emit(value))
    }

    func register(_ subscriber: Subscriber) -> Subscription {
        hub.yield(.subscribe(subscriber))
        let hub = self.hub
        let id = subscriber.id
        return Subscription { hub.yield(.unsubscribe(id)) }
    }

    func makeStream(replay: Value?) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let subscription = register(
                Subscriber(
                    id: UUID(),
                    handler: { continuation.yield($0) },
                    finish: { continuation.finish() },
                    replay: replay
                )
            )
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}
