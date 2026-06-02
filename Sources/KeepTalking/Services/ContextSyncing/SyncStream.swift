import Foundation

/// A sliceable, summarizable stream that the context-sync reconcile operates on.
///
/// Both message sync and transcript-line sync are the same algorithm over a
/// different table: build per-sender metadata (summary), then serve the tail
/// (items past a per-sender cursor) and any diverging chunk. Conforming the two
/// snapshots to this lets the reconcile driver treat them uniformly.
protocol KeepTalkingContextSyncStream: Sendable {
    associatedtype Item

    /// Per-sender counts + chunk digests for this stream's items.
    var summary: KeepTalkingContextSyncMetadata { get }

    /// Items past each sender's tail cursor (append-only delta).
    func items(after cursors: [KeepTalkingContextSyncTailCursor]) -> [Item]

    /// Items from each diverging chunk onward (mid-stream repair).
    func items(in chunks: [KeepTalkingContextSyncChunkCursor]) -> [Item]
}

/// The requester-side three-phase reconcile, parameterized over a stream's
/// request/result types. Both message sync and transcript-line sync build one of
/// these and call `runSyncReconcile` — so the summary→tail→chunk control flow
/// lives in exactly one place. The closures supply the stream-specific bits
/// (which snapshot, which envelope, how to persist); the `make*` closures reuse
/// the shared `…TailRequest.init?(local:remote:)` / `…ChunkRequest.init?` diff math.
struct KeepTalkingSyncReconcile<TailRequest, ChunkRequest, Result> {
    /// Our current metadata (re-read between phases so the chunk pass sees what
    /// the tail pass just persisted).
    let localSummary: () async throws -> KeepTalkingContextSyncMetadata
    /// The peer's metadata (fetched once).
    let remoteSummary: () async throws -> KeepTalkingContextSyncMetadata
    let makeTail: (_ local: KeepTalkingContextSyncMetadata, _ remote: KeepTalkingContextSyncMetadata) -> TailRequest?
    let dispatchTail: (TailRequest) async throws -> Result
    let makeChunk: (_ local: KeepTalkingContextSyncMetadata, _ remote: KeepTalkingContextSyncMetadata) -> ChunkRequest?
    let dispatchChunk: (ChunkRequest) async throws -> Result
    let persist: (Result) async throws -> Void
}

/// Run the shared reconcile: fetch the peer summary once, pull the append-only
/// tail, then repair any diverging chunk. A nil `make*` (nothing to pull) skips
/// that phase.
func runSyncReconcile<T, C, R>(_ steps: KeepTalkingSyncReconcile<T, C, R>) async throws {
    let remote = try await steps.remoteSummary()
    var local = try await steps.localSummary()
    if let tail = steps.makeTail(local, remote) {
        try await steps.persist(steps.dispatchTail(tail))
    }
    local = try await steps.localSummary()
    if let chunk = steps.makeChunk(local, remote) {
        try await steps.persist(steps.dispatchChunk(chunk))
    }
}
