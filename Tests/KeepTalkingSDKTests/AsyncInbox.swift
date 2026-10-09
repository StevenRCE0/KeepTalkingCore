import Foundation
import Testing

/// Buffers a stream's elements so a test can await them one at a time, each
/// with a deadline (a timeout records an issue and returns nil).
actor AsyncInbox<Element: Sendable> {
    private var buffer: [Element] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<Element?, Never>)?
    private var pump: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<Element>) {
        pump = Task {
            for await element in stream { self.put(element) }
        }
    }

    private func put(_ element: Element) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: element)
        } else {
            buffer.append(element)
        }
    }

    func next(within limit: Duration = .seconds(10)) async -> Element? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        let id = UUID()
        let element = await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            Task {
                try? await Task.sleep(for: limit)
                self.expire(id)
            }
        }
        if element == nil { Issue.record("timed out after \(limit)") }
        return element
    }

    private func expire(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
