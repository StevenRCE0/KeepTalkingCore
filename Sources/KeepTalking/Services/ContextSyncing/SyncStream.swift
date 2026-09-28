import Foundation

enum KeepTalkingContextSyncPage {
    static let maximumItemCount = 64
    static let maximumEncodedBytes = 64 * 1024

    /// Hard ceiling on a single item, distinct from the batching budget above.
    ///
    /// `maximumEncodedBytes` is a target: an item larger than it is still
    /// delivered alone, because paging cannot split one item. That exemption is
    /// right up to the point where the item cannot ride *any* envelope — past
    /// there the responder's own result send fails, the requester gets a
    /// failure, and the stream never advances past that item again. Such an
    /// item is skipped so the rest of the stream keeps flowing.
    ///
    /// Matches `KeepTalkingMessageLimits.maximumContentBytes`, which refuses to
    /// create one in the first place; this bound only catches rows that predate
    /// that guard.
    static let maximumItemBytes = KeepTalkingMessageLimits.maximumContentBytes

    static func page<Item: Encodable>(
        _ items: [Item],
        limit: Int = maximumItemCount
    ) -> (items: [Item], hasMore: Bool) {
        let encoder = JSONEncoder()
        let countLimit = max(1, min(limit, maximumItemCount))
        var byteCount = 0
        var page: [Item] = []

        for item in items.prefix(countLimit) {
            let itemByteCount =
                (try? encoder.encode(item).count) ?? maximumEncodedBytes
            if itemByteCount > maximumItemBytes { continue }
            guard
                page.isEmpty
                    || byteCount + itemByteCount <= maximumEncodedBytes
            else {
                break
            }
            page.append(item)
            byteCount += itemByteCount
        }
        return (page, page.count < items.count)
    }

    /// Pages a canonically oldest-first stream from its newest end. `before`
    /// is the oldest item delivered by the preceding page. Pages arrive
    /// newest-to-oldest while their contents remain in canonical display order.
    static func newestFirst<Item: Encodable, Key: Comparable>(
        _ orderedItems: [Item],
        before: Key? = nil,
        key: (Item) -> Key,
        limit: Int = maximumItemCount
    ) -> (items: [Item], nextBefore: Key?) {
        let candidates = orderedItems.filter { item in
            guard let before else { return true }
            return key(item) < before
        }
        let page = page(
            Array(candidates.reversed()),
            limit: limit
        )
        let nextBefore =
            page.hasMore
            ? page.items.last.map(key)
            : nil
        return (Array(page.items.reversed()), nextBefore)
    }
}

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

    /// A bounded newest-first page inside the supplied frozen tail ranges.
    func items(
        after cursors: [KeepTalkingContextSyncTailCursor],
        before: KeepTalkingContextSyncPageKey?
    ) -> (items: [Item], nextBefore: KeepTalkingContextSyncPageKey?)

    /// A bounded page beginning at the supplied diverging chunks.
    func items(
        in chunks: [KeepTalkingContextSyncChunkCursor],
        before: KeepTalkingContextSyncPageKey?
    ) -> (items: [Item], nextBefore: KeepTalkingContextSyncPageKey?)
}

enum KeepTalkingSyncReconcileError: LocalizedError {
    case noProgress(String)

    var errorDescription: String? {
        switch self {
            case .noProgress(let phase):
                return "Context sync made no progress during the \(phase) phase."
        }
    }
}

/// A request for one bounded page, continued by cursor.
///
/// `Cursor` is whatever totally orders the stream: `KeepTalkingContextSyncPageKey`
/// for messages, transcript lines, tombstones and the thread projection;
/// `KeepTalkingSideNotePageKey` for side notes, which have no timestamp/id pair.
protocol KeepTalkingSyncPageRequest {
    associatedtype Cursor: Comparable
    var before: Cursor? { get }
    func continuing(before: Cursor) -> Self
}

extension KeepTalkingContextSyncTailRequest: KeepTalkingSyncPageRequest {}
extension KeepTalkingContextSyncChunkRequest: KeepTalkingSyncPageRequest {}
extension KeepTalkingContextSyncTranscriptTailRequest: KeepTalkingSyncPageRequest {}
extension KeepTalkingContextSyncTranscriptChunkRequest: KeepTalkingSyncPageRequest {}

protocol KeepTalkingSyncPageResult {
    associatedtype Cursor: Comparable
    var nextBefore: Cursor? { get }
}

extension KeepTalkingContextSyncMessagesResult: KeepTalkingSyncPageResult {}
extension KeepTalkingContextSyncTranscriptLinesResult: KeepTalkingSyncPageResult {}

/// A page of a whole set rather than of a stream: the items themselves are
/// what the requester reassembles.
protocol KeepTalkingSyncSetPageResult: KeepTalkingSyncPageResult {
    associatedtype Item
    var items: [Item] { get }
}

extension KeepTalkingContextSyncSetPageRequest: KeepTalkingSyncPageRequest {}
extension KeepTalkingContextSyncSetPageResult: KeepTalkingSyncSetPageResult {}

/// The requester-side three-phase reconcile, parameterized over a stream's
/// request/result types. Both message sync and transcript-line sync build one of
/// these and call `runSyncReconcile` — so the summary→tail→chunk control flow
/// lives in exactly one place. The closures supply the stream-specific bits
/// (which snapshot, which envelope, how to persist); the `make*` closures reuse
/// the shared `…TailRequest.init?(local:remote:)` / `…ChunkRequest.init?` diff math.
struct KeepTalkingSyncReconcile<
    TailRequest: KeepTalkingSyncPageRequest,
    ChunkRequest: KeepTalkingSyncPageRequest,
    Result: KeepTalkingSyncPageResult
> {
    /// Our current metadata (re-read between phases so the chunk pass sees what
    /// the tail pass just persisted).
    let localSummary: () async throws -> KeepTalkingContextSyncMetadata
    /// The peer's metadata (fetched once).
    let remoteSummary: () async throws -> KeepTalkingContextSyncMetadata
    let makeTail:
        (_ local: KeepTalkingContextSyncMetadata, _ remote: KeepTalkingContextSyncMetadata)
            -> TailRequest?
    let dispatchTail: (TailRequest) async throws -> Result
    let makeChunk:
        (_ local: KeepTalkingContextSyncMetadata, _ remote: KeepTalkingContextSyncMetadata)
            -> ChunkRequest?
    let dispatchChunk: (ChunkRequest) async throws -> Result
    let persist: (Result) async throws -> Void
    /// Where an abandoned repair reports itself. Unrepairable divergence is
    /// logged, not thrown — see `runSyncReconcile`.
    var log: ((String) -> Void)? = nil
}

/// Run the shared reconcile one bounded page at a time, persisting each page
/// before requesting the next cursor.
///
/// There is no snapshot check and no restart: correctness rests on the
/// `endIndex` clamp captured in each cursor plus id-dedup at persistence, so a
/// responder that appends mid-reconcile simply leaves work for the next pass
/// rather than invalidating this one.
///
/// Chunk repair is bounded and does NOT throw when it stops making progress. A
/// divergence can be genuinely unrepairable — two peers holding one id with
/// different content, which `filterNewMessages` will never overwrite — and
/// failing the whole sync for it means the tail never flows either. Log and
/// move on.
func runSyncReconcile<T, C, R>(
    _ steps: KeepTalkingSyncReconcile<T, C, R>,
    maximumChunkRepairRounds: Int = 8
) async throws where T.Cursor == R.Cursor, C.Cursor == R.Cursor {
    let remote = try await steps.remoteSummary()
    var local = try await steps.localSummary()

    if let firstTail = steps.makeTail(local, remote) {
        var tail: T? = firstTail
        while let current = tail {
            let result = try await steps.dispatchTail(current)
            tail = try await continueSyncPage(
                current,
                result: result,
                persist: steps.persist
            )
        }
        local = try await steps.localSummary()
    }

    var rounds = 0
    while let firstChunk = steps.makeChunk(local, remote) {
        guard rounds < max(1, maximumChunkRepairRounds) else {
            steps.log?(
                "chunk repair gave up after \(rounds) rounds; divergence is not repairable by refetch"
            )
            return
        }
        rounds += 1

        var chunk: C? = firstChunk
        while let current = chunk {
            let result = try await steps.dispatchChunk(current)
            chunk = try await continueSyncPage(
                current,
                result: result,
                persist: steps.persist
            )
        }

        let updated = try await steps.localSummary()
        guard updated != local else {
            steps.log?(
                "chunk repair made no progress; leaving the divergence in place"
            )
            return
        }
        local = updated
    }
}

private func continueSyncPage<Request, Result>(
    _ request: Request,
    result: Result,
    persist: (Result) async throws -> Void
) async throws -> Request?
where
    Request: KeepTalkingSyncPageRequest, Result: KeepTalkingSyncPageResult,
    Request.Cursor == Result.Cursor
{
    try await persist(result)
    guard let nextBefore = result.nextBefore else { return nil }
    if let before = request.before {
        // A responder that keeps handing back the same cursor would spin
        // forever; this is the one place a hard stop is still right.
        guard nextBefore < before else {
            throw KeepTalkingSyncReconcileError.noProgress("page continuation")
        }
    }
    return request.continuing(before: nextBefore)
}

/// Reassembles a whole set that a responder paged out.
///
/// Whole-set exchanges (side notes, message tombstones, the thread projection)
/// ride the summary result, but transport never fragments an envelope — so a
/// set that outgrows one is split with the same pager messages use. The summary
/// result carries the first page; this pulls the rest through
/// `continueSyncPage`, keeping its strictly-decreasing-cursor guard.
///
/// Returns the set in canonical (oldest-first) order: pages arrive newest-first
/// while each page's contents stay in canonical order, so every later page is
/// prepended. Callers merge the complete set once — tombstone pruning and the
/// thread projection's all-or-nothing apply both need the whole thing.
func collectSyncSetPages<Request, Result>(
    firstPage: [Result.Item],
    nextBefore: Request.Cursor?,
    request: (Request.Cursor) -> Request,
    dispatch: (Request) async throws -> Result
) async throws -> [Result.Item]
where
    Request: KeepTalkingSyncPageRequest, Result: KeepTalkingSyncSetPageResult,
    Request.Cursor == Result.Cursor
{
    var items = firstPage
    var current = nextBefore.map(request)
    while let page = current {
        let result = try await dispatch(page)
        current = try await continueSyncPage(
            page,
            result: result,
            persist: { items = $0.items + items }
        )
    }
    return items
}
