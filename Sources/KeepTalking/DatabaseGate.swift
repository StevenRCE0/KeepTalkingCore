import Foundation
import NIOConcurrencyHelpers

/// How urgent a database operation is. Every query takes a permit on a lane
/// before it runs — see `ActivityReportingDatabase` — so a burst of sync or
/// reconcile work never starves the read a user is waiting on.
///
/// Set explicitly with ``withDatabaseLane(_:_:)``; otherwise derived
/// from the task's priority, so main-actor work is interactive and
/// `Task.detached(priority: .background)` work is background on its own —
/// until something more urgent awaits that task, which escalates it. Work
/// that must stay below the UI sets its lane explicitly.
public enum KeepTalkingDatabaseLane: Int, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    /// Something on screen is waiting: a page, a lookup, a user's write.
    case interactive = 0
    /// Refreshes driven by signals, polls and timers.
    case utility = 1
    /// Sync, reconciliation, reclamation — nothing waits on it.
    case background = 2

    @TaskLocal static var explicit: KeepTalkingDatabaseLane?

    public init(priority: TaskPriority) {
        if priority >= .userInitiated {
            self = .interactive
        } else if priority <= .background {
            self = .background
        } else {
            self = .utility
        }
    }

    /// The lane an operation issued right now takes: the explicit one, or the
    /// one the task's priority implies.
    public static var current: Self {
        explicit ?? Self(priority: Task.currentPriority)
    }

    /// The task priority that maps back onto this lane.
    public var taskPriority: TaskPriority {
        switch self {
            case .interactive: .userInitiated
            case .utility: .utility
            case .background: .background
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
            case .interactive: "interactive"
            case .utility: "utility"
            case .background: "background"
        }
    }
}

/// Runs `body` with every database operation it issues on `lane`. Nested
/// calls override; child tasks inherit; detached tasks do not.
public nonisolated(nonsending) func withDatabaseLane<T>(
    _ lane: KeepTalkingDatabaseLane,
    _ body: nonisolated(nonsending) () async throws -> T
) async rethrows -> T {
    try await KeepTalkingDatabaseLane.$explicit.withValue(lane, operation: body)
}

/// Lane widths for one store's gate. Anything left nil is derived from the
/// store's connection count `C`: interactive `C`, utility `max(1, C/2)`,
/// background 1, and utility + background together at most `max(1, C−1)`,
/// so interactive always has a connection to itself.
public struct KeepTalkingDatabaseGateConfiguration: Sendable, Equatable {
    public var interactive: Int?
    public var utility: Int?
    public var background: Int?
    /// Cap on utility + background running together.
    public var nonInteractive: Int?
    /// How long a waiter sits before it is ordered as if one lane more urgent.
    /// Ordering only — it never takes a slot its own lane could not.
    public var aging: Duration = .milliseconds(250)

    public static let automatic = Self()

    public init(
        interactive: Int? = nil,
        utility: Int? = nil,
        background: Int? = nil,
        nonInteractive: Int? = nil,
        aging: Duration = .milliseconds(250)
    ) {
        self.interactive = interactive
        self.utility = utility
        self.background = background
        self.nonInteractive = nonInteractive
        self.aging = aging
    }

    func resolved(connections: Int) -> DatabaseGate.Limits {
        let c = max(1, connections)
        return DatabaseGate.Limits(
            total: c,
            perLane: [
                max(1, interactive ?? c),
                max(1, utility ?? max(1, c / 2)),
                max(1, background ?? 1),
            ],
            nonInteractive: max(1, nonInteractive ?? max(1, c - 1)),
            aging: aging
        )
    }
}

/// Task-local state the gate reads on entry.
enum DatabaseGateContext {
    /// Set for the whole of a granted operation, so a transaction's closure —
    /// or anything it awaits — that reaches the outer database again runs on
    /// the permit already held instead of queuing behind itself.
    @TaskLocal static var isHoldingPermit = false
}

/// Admission for one store: at most `total` operations at once, each lane
/// capped, one writer at a time, and waiters granted most-urgent-first.
///
/// A lock, not an actor: an actor would escalate whichever job holds it when
/// a more urgent one queues behind it. Waiters park on continuations so a
/// main-actor caller never lifts a background worker's priority either.
///
/// `KeepTalkingDatabaseActivity` is told at grant and at release — never for a
/// waiter, which holds no lock — and a successor is granted before its
/// predecessor ends, so the busy flag never flickers across a handoff.
final class DatabaseGate: Sendable {
    struct Limits: Sendable, Equatable {
        var total: Int
        /// Indexed by `KeepTalkingDatabaseLane.rawValue`.
        var perLane: [Int]
        var nonInteractive: Int
        var aging: Duration
    }

    struct Permit: Sendable {
        let id: UInt64
        let lane: KeepTalkingDatabaseLane
        let isWrite: Bool
        let waited: Duration
        let grantedAt: ContinuousClock.Instant
    }

    struct Snapshot: Sendable, Equatable {
        var running: [Int]
        var waiting: Int
        var writerHeld: Bool
    }

    /// Where grants and releases are reported. The process-wide
    /// ``KeepTalkingDatabaseActivity`` by default; a test supplies its own.
    struct Activity: Sendable {
        var begin: @Sendable () -> Void
        var end: @Sendable () -> Void

        static let global = Activity(
            begin: { KeepTalkingDatabaseActivity.begin() },
            end: { KeepTalkingDatabaseActivity.end() }
        )
    }

    private struct Waiter {
        let id: UInt64
        let lane: KeepTalkingDatabaseLane
        let isWrite: Bool
        let enqueuedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Permit, Never>

        /// The lane this waiter is ordered as, after aging.
        func orderingLane(at now: ContinuousClock.Instant, aging: Duration) -> Int {
            guard aging > .zero else { return lane.rawValue }
            let waited = now - enqueuedAt
            var steps = 0
            var remaining = waited
            while remaining >= aging, steps < lane.rawValue {
                remaining -= aging
                steps += 1
            }
            return lane.rawValue - steps
        }
    }

    private struct State {
        var running: [Int]
        var writerHeld = false
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
    }

    let limits: Limits
    private let activity: Activity
    private let state: NIOLockedValueBox<State>

    init(limits: Limits, activity: Activity = .global) {
        self.limits = limits
        self.activity = activity
        self.state = .init(State(running: Array(repeating: 0, count: limits.perLane.count)))
    }

    convenience init(
        configuration: KeepTalkingDatabaseGateConfiguration,
        connections: Int,
        activity: Activity = .global
    ) {
        self.init(limits: configuration.resolved(connections: connections), activity: activity)
    }

    func snapshot() -> Snapshot {
        state.withLockedValue {
            Snapshot(running: $0.running, waiting: $0.waiters.count, writerHeld: $0.writerHeld)
        }
    }

    /// A permit right now, or nil when the caller must wait.
    ///
    /// Waiters never hold a newcomer back on their own: anything eligible was
    /// granted at the last release, so what is queued is what cannot run —
    /// a writer behind the writer slot, a lane at its width — and a request
    /// that can run passes it. Within a lane that still leaves arrival order,
    /// since a lane at its width refuses newcomers too.
    func tryAcquire(lane: KeepTalkingDatabaseLane, isWrite: Bool) -> Permit? {
        let permit = state.withLockedValue { state -> Permit? in
            guard canRun(lane: lane, isWrite: isWrite, in: state) else { return nil }
            return grant(lane: lane, isWrite: isWrite, waited: .zero, in: &state)
        }
        if permit != nil {
            activity.begin()
        }
        return permit
    }

    func acquire(lane: KeepTalkingDatabaseLane, isWrite: Bool) async -> Permit {
        if let permit = tryAcquire(lane: lane, isWrite: isWrite) {
            return permit
        }
        let permit = await withCheckedContinuation { continuation in
            let granted = state.withLockedValue { state -> Permit? in
                // Re-check under the lock: a release may have landed since.
                if canRun(lane: lane, isWrite: isWrite, in: state) {
                    return grant(lane: lane, isWrite: isWrite, waited: .zero, in: &state)
                }
                state.nextID &+= 1
                state.waiters.append(
                    Waiter(
                        id: state.nextID, lane: lane, isWrite: isWrite,
                        enqueuedAt: .now, continuation: continuation
                    )
                )
                return nil
            }
            if let granted {
                activity.begin()
                continuation.resume(returning: granted)
            }
        }
        return permit
    }

    func release(_ permit: Permit) {
        let grants = state.withLockedValue { state -> [(Waiter, Permit)] in
            state.running[permit.lane.rawValue] -= 1
            if permit.isWrite { state.writerHeld = false }
            return grantWaiters(in: &state)
        }
        // Successors begin before this permit ends: no busy→idle→busy blip.
        for _ in grants { activity.begin() }
        for (waiter, granted) in grants {
            waiter.continuation.resume(returning: granted)
        }
        activity.end()
    }

    // MARK: - Under the lock

    private func canRun(lane: KeepTalkingDatabaseLane, isWrite: Bool, in state: State) -> Bool {
        let total = state.running.reduce(0, +)
        guard total < limits.total else { return false }
        guard state.running[lane.rawValue] < limits.perLane[lane.rawValue] else { return false }
        if lane != .interactive {
            let nonInteractive = state.running.dropFirst().reduce(0, +)
            guard nonInteractive < limits.nonInteractive else { return false }
        }
        if isWrite, state.writerHeld { return false }
        return true
    }

    private func grant(
        lane: KeepTalkingDatabaseLane,
        isWrite: Bool,
        waited: Duration,
        in state: inout State
    ) -> Permit {
        state.running[lane.rawValue] += 1
        if isWrite { state.writerHeld = true }
        state.nextID &+= 1
        return Permit(id: state.nextID, lane: lane, isWrite: isWrite, waited: waited, grantedAt: .now)
    }

    /// Grants every waiter that fits, most urgent (after aging) and oldest
    /// first, until the next in line cannot run.
    private func grantWaiters(in state: inout State) -> [(Waiter, Permit)] {
        var granted: [(Waiter, Permit)] = []
        let now = ContinuousClock.now
        while !state.waiters.isEmpty {
            let ordered = state.waiters.indices.sorted { lhs, rhs in
                let l = state.waiters[lhs]
                let r = state.waiters[rhs]
                let lLane = l.orderingLane(at: now, aging: limits.aging)
                let rLane = r.orderingLane(at: now, aging: limits.aging)
                if lLane != rLane { return lLane < rLane }
                return l.enqueuedAt < r.enqueuedAt
            }
            // Skip past waiters that cannot run to one that can, so a blocked
            // writer at the head never holds up the readers behind it.
            guard
                let index = ordered.first(where: {
                    canRun(lane: state.waiters[$0].lane, isWrite: state.waiters[$0].isWrite, in: state)
                })
            else { break }
            let waiter = state.waiters.remove(at: index)
            let permit = grant(
                lane: waiter.lane, isWrite: waiter.isWrite,
                waited: now - waiter.enqueuedAt, in: &state
            )
            granted.append((waiter, permit))
        }
        return granted
    }
}

/// Single-flight per key with trailing coalescing: callers that arrive while
/// a run is queued join it; callers that arrive while one is running get the
/// next run, which starts once the current one finishes — and, with
/// `minimumInterval`, no sooner than that after the last start.
///
/// A caller always gets the result of a run that began after its call, so a
/// refresh requested after a write sees the write. Runs go on a detached task
/// at the lane's priority with the lane bound explicitly, so a main-actor
/// caller neither escalates the run nor loses the lane across the detach.
public final class KeepTalkingKeyedCoalescer<Key: Hashable & Sendable>: Sendable {
    private typealias Work = @Sendable () async throws -> any Sendable
    private typealias Waiter = CheckedContinuation<any Sendable, any Error>

    private struct Pending {
        var lane: KeepTalkingDatabaseLane
        var notBefore: ContinuousClock.Instant?
        var work: Work
        var waiters: [Waiter]
    }

    private struct Entry {
        var isRunning = false
        var isScheduled = false
        var lastStarted: ContinuousClock.Instant?
        var queued: Pending?
    }

    private let entries = NIOLockedValueBox<[Key: Entry]>([:])

    public init() {}

    public func run<T: Sendable>(
        _ key: Key,
        lane: KeepTalkingDatabaseLane = .utility,
        minimumInterval: Duration? = nil,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let result = try await withCheckedThrowingContinuation { (waiter: Waiter) in
            let schedules = entries.withLockedValue { entries -> Bool in
                var entry = entries[key] ?? Entry()
                if var queued = entry.queued {
                    queued.waiters.append(waiter)
                    queued.lane = min(queued.lane, lane)
                    entry.queued = queued
                    entries[key] = entry
                    return false
                }
                var notBefore: ContinuousClock.Instant?
                if let minimumInterval, let last = entry.lastStarted,
                    ContinuousClock.now - last < minimumInterval
                {
                    notBefore = last + minimumInterval
                }
                entry.queued = Pending(
                    lane: lane, notBefore: notBefore,
                    work: { try await work() }, waiters: [waiter]
                )
                let schedules = !entry.isRunning && !entry.isScheduled
                if schedules { entry.isScheduled = true }
                entries[key] = entry
                return schedules
            }
            if schedules { schedule(key) }
        }
        return result as! T
    }

    /// Starts the queued run for `key` once it is due, then whatever queued
    /// behind it. Called with `isScheduled` already set.
    private func schedule(_ key: Key) {
        let notBefore = entries.withLockedValue { $0[key]?.queued?.notBefore }
        let priority = entries.withLockedValue { $0[key]?.queued?.lane.taskPriority } ?? .utility
        Task.detached(priority: priority) { [self] in
            if let notBefore, notBefore > .now {
                try? await Task.sleep(until: notBefore)
            }
            let pending = entries.withLockedValue { entries -> Pending? in
                guard var entry = entries[key], let queued = entry.queued else {
                    entries[key]?.isScheduled = false
                    return nil
                }
                entry.queued = nil
                entry.isScheduled = false
                entry.isRunning = true
                entry.lastStarted = .now
                entries[key] = entry
                return queued
            }
            guard let pending else { return }
            let result: Result<any Sendable, any Error>
            do {
                result = .success(try await withDatabaseLane(pending.lane) { try await pending.work() })
            } catch {
                result = .failure(error)
            }
            for waiter in pending.waiters {
                waiter.resume(with: result)
            }
            let schedulesNext = entries.withLockedValue { entries -> Bool in
                guard var entry = entries[key] else { return false }
                entry.isRunning = false
                let next = entry.queued != nil && !entry.isScheduled
                if next { entry.isScheduled = true }
                entries[key] = entry
                return next
            }
            if schedulesNext { schedule(key) }
        }
    }
}
