import Foundation
import NIOConcurrencyHelpers

/// Shares link-preview fetches between everyone asking about the same URL for
/// a few minutes: a composer showing the preview while the message is typed,
/// then the send path attaching it.
///
/// The composer usually asks first, so by the time the message is sent the
/// preview is already here and the send doesn't wait. A request still in
/// flight is joined, not repeated. Each fetch runs detached from whoever
/// started it: a send that gives up at its budget leaves it running for the
/// next asker instead of cancelling it for everyone.
public final class KeepTalkingLinkPreviewCache: KeepTalkingLinkPreviewFetching {
    private struct Entry {
        let fetch: Task<KeepTalkingFetchedLinkPreview?, Never>
        let startedAt: ContinuousClock.Instant
    }

    private let upstream: any KeepTalkingLinkPreviewFetching
    private let lifetime: Duration
    private let capacity: Int
    private let entries = NIOLockedValueBox<[URL: Entry]>([:])

    /// - Parameters:
    ///   - lifetime: How long an answer — a miss included — is reused.
    ///   - capacity: Entries kept before the oldest are dropped.
    public init(
        wrapping upstream: any KeepTalkingLinkPreviewFetching,
        lifetime: Duration = .seconds(600),
        capacity: Int = 64
    ) {
        self.upstream = upstream
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview? {
        let now = ContinuousClock.now
        let fetch = entries.withLockedValue { entries in
            entries = entries.filter { now - $0.value.startedAt < lifetime }
            if let entry = entries[url] { return entry.fetch }

            let upstream = self.upstream
            let fetch = Task.detached { await upstream.preview(for: url) }
            if entries.count >= capacity,
                let oldest = entries.min(by: { $0.value.startedAt < $1.value.startedAt })?.key
            {
                entries.removeValue(forKey: oldest)
            }
            entries[url] = Entry(fetch: fetch, startedAt: now)
            return fetch
        }
        return await fetch.value
    }
}
