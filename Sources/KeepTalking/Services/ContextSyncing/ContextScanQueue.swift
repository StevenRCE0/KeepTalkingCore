import FluentKit
import Foundation
import NIOConcurrencyHelpers

/// Runs whole-context reads one at a time, at background priority — the same
/// terms semantic indexing gets for its embeddings.
///
/// A whole-context read is a sync snapshot (every message and attachment, each
/// message hashed; one per summary, tail page and chunk page on both sides of
/// every reconcile, for every peer, every heartbeat, in every context client)
/// or a thread view loading a context's full history. Nothing on screen waits
/// on either — the chat pages newest-first on its own — and a stuttering UI
/// costs more than a late sync. So they share one `.background` worker for the
/// whole process, since every context client in the app shares one store, and
/// each reads a page at a time (``readPaged(id:page:)``) so no single read
/// holds a store connection for a whole context's decode.
///
/// Callers wait on a continuation rather than awaiting the worker's `Task`, so
/// a main-actor caller never escalates the worker back up. The queue is a
/// lock, not an actor, for the same reason: an actor escalates whichever job
/// holds it when a higher-priority one is enqueued behind it.
///
/// A keyed request joins a queued scan with the same key, but never one
/// already running: that one may have read the store before the caller's last
/// write, and the reconcile re-reads its local summary right after persisting
/// a page and compares — a stale snapshot there reads as "no progress". So per
/// key there is at most one running scan and one queued.
final class KeepTalkingContextScanQueue: Sendable {
    static let shared = KeepTalkingContextScanQueue()

    /// Rows per page for ``readPaged(id:page:)``.
    static let pageSize = 256

    private struct Key: Hashable, Sendable {
        /// The requester. Its scan closure holds it, so the identifier cannot
        /// be reused while its job is queued.
        let owner: ObjectIdentifier
        let context: UUID
        /// The scan's result type, so a joining waiter always gets the type it
        /// asked for.
        let result: ObjectIdentifier
    }

    private typealias Scan = @Sendable () async throws -> any Sendable
    private typealias Waiter = CheckedContinuation<any Sendable, any Error>

    private struct Job: Sendable {
        let key: Key?
        let scan: Scan
        var waiters: [Waiter]
    }

    private struct State: Sendable {
        var queued: [Job] = []
        var isDraining = false
    }

    private let state = NIOLockedValueBox(State())

    /// Runs `scan` on the queue, on its own.
    func run<T: Sendable>(
        _ scan: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await enqueue(key: nil) { try await scan() } as! T
    }

    /// Runs `scan` on the queue, or joins a scan `owner` already queued for
    /// `context` that has not started yet.
    func run<T: Sendable>(
        for owner: AnyObject,
        context: UUID,
        _ scan: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let key = Key(
            owner: ObjectIdentifier(owner),
            context: context,
            result: ObjectIdentifier(T.self)
        )
        return try await enqueue(key: key) { try await scan() } as! T
    }

    private func enqueue(key: Key?, scan: @escaping Scan) async throws -> any Sendable {
        try await withCheckedThrowingContinuation { waiter in
            let startsWorker = state.withLockedValue { state in
                Self.enqueue(waiter, key: key, scan: scan, in: &state)
            }
            guard startsWorker else { return }
            Task.detached(priority: .background) {
                await withDatabaseLane(.background) { await self.drain() }
            }
        }
    }

    /// Adds the waiter to the queued job for `key`, or queues a new one.
    /// Returns whether the caller must start the worker.
    private static func enqueue(
        _ waiter: Waiter,
        key: Key?,
        scan: @escaping Scan,
        in state: inout State
    ) -> Bool {
        if let key, let index = state.queued.firstIndex(where: { $0.key == key }) {
            state.queued[index].waiters.append(waiter)
        } else {
            state.queued.append(Job(key: key, scan: scan, waiters: [waiter]))
        }
        guard !state.isDraining else { return false }
        state.isDraining = true
        return true
    }

    private func drain() async {
        while let job = nextJob() {
            let result: Result<any Sendable, any Error>
            do {
                result = .success(try await job.scan())
            } catch {
                result = .failure(error)
            }
            for waiter in job.waiters {
                waiter.resume(with: result)
            }
        }
    }

    /// Pops the oldest queued job, or marks the worker idle when none is left
    /// — under the lock, so an enqueue racing the last pop still starts a
    /// worker.
    private func nextJob() -> Job? {
        state.withLockedValue { state in
            guard !state.queued.isEmpty else {
                state.isDraining = false
                return nil
            }
            return state.queued.removeFirst()
        }
    }

    /// Reads a whole result set a page at a time, yielding between pages.
    ///
    /// Pages are keyed on the row id, not the timestamp: ids compare exactly
    /// in SQLite, while a `Date` does not survive the round trip bit-exactly
    /// (see `KeepTalkingContextSyncDigestPayload`), so a timestamp cursor can
    /// skip or repeat a row at a page boundary. Callers sort the result.
    static func readPaged<Row: Sendable>(
        id: (Row) -> UUID?,
        page: (_ after: UUID?, _ limit: Int) async throws -> [Row]
    ) async throws -> [Row] {
        var rows: [Row] = []
        var after: UUID?
        while true {
            let batch = try await page(after, pageSize)
            rows.append(contentsOf: batch)
            guard batch.count == pageSize, let last = batch.last.flatMap(id) else {
                return rows
            }
            after = last
            await Task.yield()
        }
    }
}
