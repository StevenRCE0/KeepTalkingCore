import FluentKit
import NIOConcurrencyHelpers
import NIOCore
import SQLKit

/// Whether any Fluent operation is running, across every store in the process.
///
/// iOS kills (`0xdead10cc`), rather than suspends, a process that holds a
/// lock on a file in an App Group container, and a SQLite statement holds one
/// for as long as it runs. Holding off suspension takes a platform assertion
/// the SDK cannot make, so the SDK reports when database work starts and
/// stops, and the host holds an assertion across the busy spans.
///
/// Only granted operations count: one waiting on its lane's gate holds no
/// lock yet. See `DatabaseGate`.
public enum KeepTalkingDatabaseActivity {
    private struct State: Sendable {
        var inFlight = 0
        var observer: (@Sendable () -> Void)?
    }

    private static let state = NIOLockedValueBox(State())

    /// Whether an operation is running right now.
    public static var isBusy: Bool {
        state.withLockedValue { $0.inFlight > 0 }
    }

    /// Installs `observer`, called whenever ``isBusy`` flips, synchronously on
    /// the thread that flipped it, so an idle→busy call lands before the
    /// operation starts. The observer must not wait on another thread: the main
    /// thread may be blocked on the operation, as it is during launch migration.
    /// It carries no value: calls from racing threads can arrive out of order,
    /// so the observer reads ``isBusy`` instead.
    public static func observe(_ observer: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.observer = observer }
    }

    static func begin() {
        let observer = state.withLockedValue { state in
            state.inFlight += 1
            return state.inFlight == 1 ? state.observer : nil
        }
        observer?()
    }

    static func end() {
        let observer = state.withLockedValue { state in
            state.inFlight -= 1
            return state.inFlight == 0 ? state.observer : nil
        }
        observer?()
    }
}

/// The `Database` every store hands out: each operation takes a permit on its
/// lane's gate first — see `DatabaseGate` and ``KeepTalkingDatabaseLane`` —
/// and is reported to ``KeepTalkingDatabaseActivity`` while it holds one.
///
/// A transaction, `withConnection` or `withSession` block is one operation
/// holding one permit (and the writer slot) for the whole block. Its closure
/// receives the underlying database, so the queries inside never queue behind
/// the block itself; code that reaches this wrapper again from inside the
/// block runs on the held permit instead (`DatabaseGateContext`).
///
/// It is an `SQLDatabase` too, and must stay one: FluentKit decides how to
/// write a row by asking `database is any SQLDatabase`. Against a plain
/// `Database` it inserts only the fields that changed since the row was last
/// read, so a row that was fetched, deleted and saved again comes back with
/// every untouched column NULL. Against an `SQLDatabase` it inserts them all.
struct ActivityReportingDatabase: Database, SQLDatabase {
    let base: any Database & SQLDatabase
    let gate: DatabaseGate

    /// Waits and holds past this are logged in debug builds — a lane wedged
    /// behind a transaction that awaits something else, or a scan that
    /// should have paged.
    private static let watchdogThreshold: Duration = .seconds(5)

    // MARK: Database

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        gated(isWrite: Self.isWrite(query.action)) { base.execute(query: query, onOutput: onOutput) }
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        gated(isWrite: true) { base.execute(schema: schema) }
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        gated(isWrite: true) { base.execute(enum: `enum`) }
    }

    func transaction<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        gated(isWrite: true) { base.transaction(closure) }
    }

    func withConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        gated(isWrite: true) { base.withConnection(closure) }
    }

    // MARK: SQLDatabase

    var dialect: any SQLDialect { base.dialect }
    var version: (any SQLDatabaseReportedVersion)? { base.version }
    var queryLogLevel: Logger.Level? { base.queryLogLevel }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        gated(isWrite: !(query is SQLSelect)) { base.execute(sql: query, onRow) }
    }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) async throws {
        try await gated(isWrite: !(query is SQLSelect)) { try await base.execute(sql: query, onRow) }
    }

    func withSession<R>(
        _ closure: @escaping @Sendable (any SQLDatabase) async throws -> R
    ) async throws -> R {
        try await gated(isWrite: true) { try await base.withSession(closure) }
    }

    // MARK: - Gating

    private static func isWrite(_ action: DatabaseQuery.Action) -> Bool {
        switch action {
            case .read, .aggregate: false
            case .create, .update, .delete, .custom: true
        }
    }

    private func gated<T>(
        isWrite: Bool,
        _ operation: @escaping @Sendable () -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        if DatabaseGateContext.isHoldingPermit {
            return bypassing(isWrite: isWrite, operation)
        }
        let lane = KeepTalkingDatabaseLane.current
        if let permit = gate.tryAcquire(lane: lane, isWrite: isWrite) {
            return DatabaseGateContext.$isHoldingPermit.withValue(true) { operation() }
                .always { _ in release(permit) }
        }
        // The task inherits the caller's task-locals and priority; the wait
        // itself parks on a continuation, so nothing is escalated.
        return base.eventLoop.makeFutureWithTask {
            let permit = await gate.acquire(lane: lane, isWrite: isWrite)
            noteWait(permit)
            defer { release(permit) }
            return try await DatabaseGateContext.$isHoldingPermit.withValue(true) {
                UnsafeSendableBox(try await operation().get())
            }
        }.map(\.value)
    }

    private func gated<T>(
        isWrite: Bool,
        _ operation: () async throws -> T
    ) async throws -> T {
        if DatabaseGateContext.isHoldingPermit {
            #if DEBUG
            if isWrite { logBypassedWrite() }
            #endif
            return try await operation()
        }
        let permit = await gate.acquire(lane: .current, isWrite: isWrite)
        noteWait(permit)
        defer { release(permit) }
        return try await DatabaseGateContext.$isHoldingPermit.withValue(true) {
            try await operation()
        }
    }

    private func bypassing<T>(
        isWrite: Bool,
        _ operation: () -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        #if DEBUG
        if isWrite { logBypassedWrite() }
        #endif
        return operation()
    }

    private func release(_ permit: DatabaseGate.Permit) {
        #if DEBUG
        let held = ContinuousClock.now - permit.grantedAt
        if held > Self.watchdogThreshold {
            base.logger.warning(
                "database permit held \(held) lane=\(permit.lane) write=\(permit.isWrite) \(gate.snapshot())"
            )
        }
        #endif
        gate.release(permit)
    }

    private func noteWait(_ permit: DatabaseGate.Permit) {
        #if DEBUG
        if permit.waited > Self.watchdogThreshold {
            base.logger.warning(
                "database permit waited \(permit.waited) lane=\(permit.lane) write=\(permit.isWrite) \(gate.snapshot())"
            )
        }
        #endif
    }

    #if DEBUG
    /// A write issued through the outer database from inside a held block
    /// runs on that block's permit. Against SQLite it also contends with the
    /// block's own write lock, so it is worth knowing about.
    private func logBypassedWrite() {
        base.logger.debug("database write inside a held block bypassed the gate")
    }
    #endif
}

/// Carries a non-`Sendable` result across `makeFutureWithTask`, which requires
/// one. Fluent's `transaction<T>` puts no bound on `T`; the value crosses no
/// isolation the caller had not already crossed.
private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
