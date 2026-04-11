import Foundation

// MARK: - Public types

public struct KeepTalkingAgentRunSnapshot: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case queued
        case running
    }

    public let id: UUID
    public let contextID: UUID
    public let promptPreview: String
    public let createdAt: Date
    public let state: State
}

// MARK: - Queue actor

/// Serial per-context run queue.  At most one AI run is active per context;
/// additional enqueues are held in order and started automatically when the
/// preceding run finishes.
actor AgentRunQueue {

    private struct RunItem {
        let id: UUID
        let contextID: UUID
        let promptPreview: String
        let createdAt: Date
        let work: @Sendable () async throws -> Void
        let onCompleted: (@Sendable (Error?) -> Void)?
    }

    /// Per-context backlog (items not yet running).
    private var queued: [UUID: [RunItem]] = [:]
    /// Per-context active run.
    private var active: [UUID: (item: RunItem, task: Task<Void, Never>)] = [:]

    /// Called on every state transition with the current flat snapshot list.
    nonisolated(unsafe) var onChanged: (@Sendable ([KeepTalkingAgentRunSnapshot]) -> Void)?

    // MARK: - Interface

    /// Enqueues a unit of work for `contextID`.  Starts immediately if the
    /// context has no active run; otherwise appends to the backlog.
    /// Returns the stable run ID so callers can cancel by ID if needed.
    @discardableResult
    func enqueue(
        id: UUID = UUID(),
        contextID: UUID,
        promptPreview: String,
        work: @escaping @Sendable () async throws -> Void,
        onCompleted: (@Sendable (Error?) -> Void)? = nil
    ) -> UUID {
        let item = RunItem(
            id: id,
            contextID: contextID,
            promptPreview: String(promptPreview.prefix(120)),
            createdAt: Date(),
            work: work,
            onCompleted: onCompleted
        )
        if active[contextID] == nil {
            start(item)
        } else {
            queued[contextID, default: []].append(item)
        }
        emit()
        return id
    }

    /// Cancels a run by ID regardless of whether it is active or queued.
    /// Cancelling an active run stops its `Task`; the prompt message already
    /// sent to chat stays, but no further AI output appears.
    /// Cancelling a queued run removes it silently (no prompt is sent).
    func cancel(runID: UUID) {
        for (_, entry) in active where entry.item.id == runID {
            entry.task.cancel()
            return
        }
        for contextID in queued.keys {
            guard
                let idx = queued[contextID]?.firstIndex(where: { $0.id == runID })
            else { continue }
            queued[contextID]?.remove(at: idx)
            if queued[contextID]?.isEmpty == true { queued[contextID] = nil }
            emit()
            return
        }
    }

    var currentSnapshots: [KeepTalkingAgentRunSnapshot] { makeSnapshots() }

    // MARK: - Private

    private func start(_ item: RunItem) {
        let task = Task {
            var workError: (any Error)? = nil
            do {
                try await item.work()
            } catch is CancellationError {
                // intentional stop — treat as clean
            } catch {
                workError = error
            }
            item.onCompleted?(workError)
            finish(contextID: item.contextID)
        }
        active[item.contextID] = (item: item, task: task)
    }

    private func finish(contextID: UUID) {
        active[contextID] = nil
        if var queue = queued[contextID], !queue.isEmpty {
            let next = queue.removeFirst()
            queued[contextID] = queue.isEmpty ? nil : queue
            start(next)
        }
        emit()
    }

    private func makeSnapshots() -> [KeepTalkingAgentRunSnapshot] {
        var result: [KeepTalkingAgentRunSnapshot] = []
        for (_, entry) in active {
            result.append(KeepTalkingAgentRunSnapshot(
                id: entry.item.id,
                contextID: entry.item.contextID,
                promptPreview: entry.item.promptPreview,
                createdAt: entry.item.createdAt,
                state: .running
            ))
        }
        for (_, items) in queued {
            for item in items {
                result.append(KeepTalkingAgentRunSnapshot(
                    id: item.id,
                    contextID: item.contextID,
                    promptPreview: item.promptPreview,
                    createdAt: item.createdAt,
                    state: .queued
                ))
            }
        }
        result.sort {
            if $0.state == .running, $1.state != .running { return true }
            if $0.state != .running, $1.state == .running { return false }
            return $0.createdAt < $1.createdAt
        }
        return result
    }

    private func emit() {
        onChanged?(makeSnapshots())
    }
}
