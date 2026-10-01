import FluentKit
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SQLKit
import SQLiteKit
import Testing

@testable import KeepTalkingSDK

/// Drives the gate through the real wrapper over a database whose queries
/// finish only when the test says so.
@Suite(.serialized)
struct DatabaseGateTests {
    @Test("each lane runs at most its width, and a waiter is granted on release")
    func laneWidths() async throws {
        let harness = try Harness(connections: 4)
        defer { harness.tearDown() }
        // interactive 4, utility 2, background 1, non-interactive ≤ 3.
        let utility = (0..<3).map { _ in harness.read(lane: .utility) }
        await harness.settle()
        #expect(harness.gate.snapshot() == .init(running: [0, 2, 0], waiting: 1, writerHeld: false))

        harness.finishOne()
        await harness.waitUntil { harness.gate.snapshot().waiting == 0 }
        #expect(harness.gate.snapshot().running == [0, 2, 0])

        harness.finishAll()
        for future in utility { try await future.get() }
        #expect(harness.gate.snapshot() == .init(running: [0, 0, 0], waiting: 0, writerHeld: false))
    }

    @Test("utility and background together never take the last connection")
    func interactiveSlotIsReserved() async throws {
        let harness = try Harness(connections: 2)
        defer { harness.tearDown() }
        // interactive 2, utility 1, background 1, non-interactive ≤ 1.
        let utility = harness.read(lane: .utility)
        let background = harness.read(lane: .background)
        await harness.settle()
        #expect(harness.gate.snapshot() == .init(running: [0, 1, 0], waiting: 1, writerHeld: false))

        let interactive = harness.read(lane: .interactive)
        await harness.settle()
        #expect(harness.gate.snapshot().running == [1, 1, 0])

        harness.finishAll()
        await harness.waitUntil { harness.gate.snapshot().waiting == 0 }
        harness.finishAll()
        for future in [utility, background, interactive] { try await future.get() }
    }

    @Test("waiters on one lane are granted in arrival order")
    func fifoWithinLane() async throws {
        let harness = try Harness(connections: 1)
        defer { harness.tearDown() }
        let order = SignalRecorder<Int>()
        let first = harness.read(lane: .interactive)
        await harness.settle()
        let rest = (1...3).map { index in
            harness.read(lane: .interactive).map { order.record(index) }
        }
        await harness.waitUntil { harness.gate.snapshot().waiting == 3 }

        for _ in 0..<4 {
            harness.finishOne()
            await harness.waitUntil { harness.pending == 1 || harness.gate.snapshot().waiting == 0 }
        }
        harness.finishAll()
        try await first.get()
        for future in rest { try await future.get() }
        #expect(order.snapshot == [1, 2, 3])
    }

    @Test("a more urgent waiter is granted before an earlier, less urgent one")
    func urgencyBeatsArrival() async throws {
        let harness = try Harness(connections: 1)
        defer { harness.tearDown() }
        let order = SignalRecorder<String>()
        let first = harness.read(lane: .interactive)
        await harness.settle()
        let background = harness.read(lane: .background).map { order.record("background") }
        await harness.waitUntil { harness.gate.snapshot().waiting == 1 }
        let interactive = harness.read(lane: .interactive).map { order.record("interactive") }
        await harness.waitUntil { harness.gate.snapshot().waiting == 2 }

        for _ in 0..<3 {
            harness.finishOne()
            await harness.waitUntil { harness.pending == 1 || harness.gate.snapshot().waiting == 0 }
        }
        harness.finishAll()
        try await first.get()
        try await background.get()
        try await interactive.get()
        #expect(order.snapshot == ["interactive", "background"])
    }

    @Test("only one writer runs at a time, and readers pass a blocked writer")
    func singleWriter() async throws {
        let harness = try Harness(connections: 4)
        defer { harness.tearDown() }
        let write1 = harness.write(lane: .interactive)
        await harness.settle()
        let write2 = harness.write(lane: .interactive)
        await harness.waitUntil { harness.gate.snapshot().waiting == 1 }
        let read = harness.read(lane: .interactive)
        await harness.settle()
        // The read was not queued behind the waiting writer.
        #expect(harness.gate.snapshot() == .init(running: [2, 0, 0], waiting: 1, writerHeld: true))

        harness.finishAll()
        await harness.waitUntil { harness.gate.snapshot().waiting == 0 }
        harness.finishAll()
        for future in [write1, write2, read] { try await future.get() }
    }

    @Test("a waiter that has aged is ordered as a more urgent one")
    func agingReorders() async throws {
        let harness = try Harness(connections: 1, aging: .milliseconds(20))
        defer { harness.tearDown() }
        let order = SignalRecorder<String>()
        let first = harness.read(lane: .interactive)
        await harness.settle()
        let background = harness.read(lane: .background).map { order.record("background") }
        await harness.waitUntil { harness.gate.snapshot().waiting == 1 }
        // Two aging steps: background orders as interactive from here on.
        try await Task.sleep(for: .milliseconds(60))
        let interactive = harness.read(lane: .interactive).map { order.record("interactive") }
        await harness.waitUntil { harness.gate.snapshot().waiting == 2 }

        for _ in 0..<3 {
            harness.finishOne()
            await harness.waitUntil { harness.pending == 1 || harness.gate.snapshot().waiting == 0 }
        }
        harness.finishAll()
        try await first.get()
        try await background.get()
        try await interactive.get()
        #expect(order.snapshot == ["background", "interactive"])
    }

    @Test("queries inside a transaction run on its permit")
    func transactionIsReentrant() async throws {
        let harness = try Harness(connections: 1)
        defer { harness.tearDown() }
        let database = harness.database
        // Width 1: an inner query that queued behind the block would deadlock.
        let result = try await database.transaction { _ -> EventLoopFuture<Int> in
            #expect(DatabaseGateContext.isHoldingPermit)
            let inner = database.execute(query: harness.readQuery, onOutput: { _ in })
            harness.finishAll()
            return inner.map { 7 }
        }.get()
        #expect(result == 7)
        #expect(harness.gate.snapshot() == .init(running: [0, 0, 0], waiting: 0, writerHeld: false))
    }

    @Test("the lane follows the task's priority unless set explicitly")
    func laneFromPriority() async throws {
        // Observed without awaiting the task, which would escalate it.
        let seen = SignalRecorder<KeepTalkingDatabaseLane>()
        Task.detached(priority: .background) { seen.record(KeepTalkingDatabaseLane.current) }
        await seen.waitForCount(1)
        #expect(seen.snapshot == [.background])
        let urgent = await Task.detached(priority: .userInitiated) { KeepTalkingDatabaseLane.current }.value
        #expect(urgent == .interactive)
        let explicit = await Task.detached(priority: .userInitiated) {
            await withDatabaseLane(.background) { KeepTalkingDatabaseLane.current }
        }.value
        #expect(explicit == .background)
        let child = await Task.detached(priority: .userInitiated) {
            await withDatabaseLane(.utility) {
                await withTaskGroup(of: KeepTalkingDatabaseLane.self) { group in
                    group.addTask { KeepTalkingDatabaseLane.current }
                    return await group.next()!
                }
            }
        }.value
        #expect(child == .utility)
    }

    @Test("activity counts granted operations only, without a blip at handoff")
    func activityCountsGrantedOnly() async throws {
        let harness = try Harness(connections: 1)
        defer { harness.tearDown() }
        let flips = harness.activity.flips

        let first = harness.read(lane: .interactive)
        await harness.settle()
        let second = harness.read(lane: .interactive)
        await harness.waitUntil { harness.gate.snapshot().waiting == 1 }
        #expect(flips.snapshot == [true])

        harness.finishOne()
        await harness.waitUntil { harness.gate.snapshot().waiting == 0 }
        try await first.get()
        #expect(flips.snapshot == [true])

        harness.finishAll()
        try await second.get()
        await flips.waitForCount(2)
        #expect(flips.snapshot == [true, false])
    }

    @Test("a mixed burst on a real store all completes")
    func stressOnStore() async throws {
        let store = try await KeepTalkingInMemoryStore.make(
            gate: .init(interactive: 2, utility: 1, background: 1, nonInteractive: 1))
        let database = store.database
        try await KeepTalkingContext(id: UUID()).save(on: database)
        let lanes = KeepTalkingDatabaseLane.allCases

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                let lane = lanes[index % lanes.count]
                group.addTask {
                    try await withDatabaseLane(lane) {
                        if index % 5 == 0 {
                            try await KeepTalkingContext(id: UUID()).save(on: database)
                        } else {
                            _ = try await KeepTalkingContext.query(on: database).count()
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await KeepTalkingContext.query(on: database).count() == 101)
        await store.shutdown()
    }
}

// MARK: - Harness

/// A wrapper over `ManualDatabase`: every query returns a promise the test
/// completes with `finishOne` / `finishAll`.
private final class Harness: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let manual: ManualDatabase
    let activity = ActivityRecorder()
    let gate: DatabaseGate
    let database: ActivityReportingDatabase

    /// `DatabaseQuery`'s initializer is internal to FluentKit; a builder's
    /// query is the public way to one.
    var readQuery: DatabaseQuery {
        KeepTalkingContext.query(on: database).query
    }
    var writeQuery: DatabaseQuery {
        var query = readQuery
        query.action = .create
        return query
    }

    init(connections: Int, aging: Duration = .zero) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        manual = ManualDatabase(eventLoop: group.next())
        gate = DatabaseGate(
            configuration: .init(aging: aging),
            connections: connections,
            activity: activity.hooks
        )
        database = ActivityReportingDatabase(base: manual, gate: gate)
    }

    func tearDown() {
        manual.failAll()
        try? group.syncShutdownGracefully()
    }

    var pending: Int { manual.pending }

    func read(lane: KeepTalkingDatabaseLane) -> EventLoopFuture<Void> {
        KeepTalkingDatabaseLane.$explicit.withValue(lane) {
            database.execute(query: readQuery, onOutput: { _ in })
        }
    }

    func write(lane: KeepTalkingDatabaseLane) -> EventLoopFuture<Void> {
        KeepTalkingDatabaseLane.$explicit.withValue(lane) {
            database.execute(query: writeQuery, onOutput: { _ in })
        }
    }

    func finishOne() { manual.finishOne() }
    func finishAll() { manual.finishAll() }

    /// Lets queued grants and future callbacks land.
    func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A private stand-in for the process-wide activity counter, so a suite
/// running alongside others sees only its own gate's grants.
final class ActivityRecorder: @unchecked Sendable {
    let flips = SignalRecorder<Bool>()
    private let inFlight = NIOLockedValueBox(0)

    var isBusy: Bool { inFlight.withLockedValue { $0 > 0 } }

    var hooks: DatabaseGate.Activity {
        DatabaseGate.Activity(
            begin: { [self] in
                if inFlight.withLockedValue({
                    $0 += 1
                    return $0
                }) == 1 {
                    flips.record(true)
                }
            },
            end: { [self] in
                if inFlight.withLockedValue({
                    $0 -= 1
                    return $0
                }) == 0 {
                    flips.record(false)
                }
            }
        )
    }
}

private struct ManualConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    func makeDriver(for databases: Databases) -> any DatabaseDriver { fatalError("unused") }
}

/// Every operation is a promise; nothing completes until told to.
private final class ManualDatabase: Database, SQLDatabase, @unchecked Sendable {
    let eventLoop: any EventLoop
    let context: DatabaseContext
    let inTransaction = false
    private let promises = NIOLockedValueBox<[EventLoopPromise<Void>]>([])

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
        self.context = DatabaseContext(
            configuration: ManualConfiguration(),
            logger: Logger(label: "manual"),
            eventLoop: eventLoop
        )
    }

    var pending: Int { promises.withLockedValue { $0.count } }

    func finishOne() {
        let promise = promises.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }
        promise?.succeed(())
    }

    func finishAll() {
        let all = promises.withLockedValue { promises in
            defer { promises.removeAll() }
            return promises
        }
        for promise in all { promise.succeed(()) }
    }

    func failAll() {
        let all = promises.withLockedValue { promises in
            defer { promises.removeAll() }
            return promises
        }
        struct TornDown: Error {}
        for promise in all { promise.fail(TornDown()) }
    }

    private func pendingFuture() -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        promises.withLockedValue { $0.append(promise) }
        return promise.futureResult
    }

    // Database
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<
        Void
    > {
        pendingFuture()
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { pendingFuture() }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { pendingFuture() }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }

    // SQLDatabase
    var dialect: any SQLDialect { SQLiteDialect() }
    var version: (any SQLDatabaseReportedVersion)? { nil }
    var queryLogLevel: Logger.Level? { nil }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<
        Void
    > {
        pendingFuture()
    }
}
