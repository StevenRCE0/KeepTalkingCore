import Foundation

final class KeepTalkingContextSyncSingleFlight: @unchecked Sendable {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var flights: [UUID: Flight] = [:]
    private var draining: [UUID: Flight] = [:]
    private var isOpen = true
    private var activeGeneration: UInt64?

    func run(
        for peer: UUID,
        generation: UInt64? = nil,
        operation: @escaping @Sendable () async -> Void
    ) async {
        guard
            let flight = lock.withLock({ () -> Flight? in
                guard
                    isOpen,
                    generation == nil || generation == activeGeneration
                else { return nil }
                if let flight = flights[peer] {
                    return flight
                }
                let predecessor = draining.removeValue(forKey: peer)?.task
                let flight = Flight(
                    id: UUID(),
                    task: Task {
                        if let predecessor {
                            await predecessor.value
                        }
                        guard !Task.isCancelled else { return }
                        await operation()
                    }
                )
                flights[peer] = flight
                return flight
            })
        else { return }

        await flight.task.value
        lock.withLock {
            if flights[peer]?.id == flight.id {
                flights[peer] = nil
            }
            if draining[peer]?.id == flight.id {
                draining[peer] = nil
            }
        }
    }

    func open(generation: UInt64? = nil) {
        lock.withLock {
            activeGeneration = generation
            isOpen = true
        }
    }

    func cancelAll() {
        let tasks = lock.withLock {
            isOpen = false
            activeGeneration = nil
            let tasks = flights.values.map(\.task)
            for (peer, flight) in flights {
                draining[peer] = flight
            }
            flights.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }
}
