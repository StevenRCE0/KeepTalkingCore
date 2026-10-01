import Foundation
import Testing

@testable import KeepTalkingSDK

struct LinkPreviewCacheTests {
    /// Counts upstream fetches; each takes `delay` and can't be cancelled
    /// (like a fetch stuck in a host lookup).
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class CountingFetcher: KeepTalkingLinkPreviewFetching {
        let calls = Counter()
        let delay: Duration

        init(delay: Duration = .milliseconds(100)) {
            self.delay = delay
        }

        func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview? {
            await calls.increment()
            let delay = delay
            await Task { try? await Task.sleep(for: delay) }.value
            return KeepTalkingFetchedLinkPreview(metadata: KeepTalkingLinkMetadata(title: url.host))
        }
    }

    static let url = URL(string: "https://example.com/post")!

    @Test func concurrentAskersShareOneFetch() async {
        let upstream = CountingFetcher()
        let cache = KeepTalkingLinkPreviewCache(wrapping: upstream)

        async let first = cache.preview(for: Self.url)
        async let second = cache.preview(for: Self.url)
        let results = await [first, second]

        #expect(results.allSatisfy { $0?.metadata.title == "example.com" })
        #expect(await upstream.calls.value == 1)

        _ = await cache.preview(for: Self.url)
        #expect(await upstream.calls.value == 1)
    }

    @Test func answersExpire() async throws {
        let upstream = CountingFetcher(delay: .zero)
        let cache = KeepTalkingLinkPreviewCache(wrapping: upstream, lifetime: .milliseconds(50))

        _ = await cache.preview(for: Self.url)
        try await Task.sleep(for: .milliseconds(80))
        _ = await cache.preview(for: Self.url)

        #expect(await upstream.calls.value == 2)
    }

    /// The send path cancels its wait at its budget; the composer that asked
    /// first still gets the answer, from the same fetch.
    @Test func anAskerGivingUpDoesNotCancelTheFetch() async {
        let upstream = CountingFetcher(delay: .milliseconds(200))
        let cache = KeepTalkingLinkPreviewCache(wrapping: upstream)

        let impatient = Task { await cache.preview(for: Self.url) }
        try? await Task.sleep(for: .milliseconds(20))
        impatient.cancel()

        let patient = await cache.preview(for: Self.url)
        #expect(patient?.metadata.title == "example.com")
        #expect(await upstream.calls.value == 1)
    }
}
