import Foundation

extension KeepTalkingClient {
    /// How long a send waits for its link previews. Past this the message goes
    /// out with whatever arrived; a slow site costs its preview, not the send.
    static let linkPreviewBudget: Duration = .seconds(4)

    /// Builds the previews an outgoing message carries.
    ///
    /// Runs on the send path before the message row exists: a synced message
    /// is immutable, so a preview can only ride along, never follow.
    func outgoingLinkPreviews(for text: String) async -> [KeepTalkingLinkPreview] {
        guard let fetcher = linkPreviewFetcher else { return [] }
        let candidates = KeepTalkingLinkPreview.candidateURLs(in: text)
        guard !candidates.isEmpty else { return [] }

        let fetched = await Self.fetchLinkPreviews(
            candidates.compactMap { URL(string: $0) },
            with: fetcher,
            within: Self.linkPreviewBudget
        )
        let previews = candidates.compactMap { candidate -> KeepTalkingLinkPreview? in
            guard let url = URL(string: candidate), let result = fetched[url] else { return nil }
            return KeepTalkingLinkPreview(
                url: candidate,
                title: result.metadata.title,
                summary: result.metadata.summary,
                siteName: result.metadata.siteName,
                image: result.image.map {
                    KeepTalkingLinkPreview.Image(
                        data: $0.data,
                        mimeType: $0.mimeType,
                        width: $0.width,
                        height: $0.height,
                        alt: result.metadata.image?.alt
                    )
                }
            )
        }
        let fitting = Self.linkPreviews(previews, fittingAlongside: text.utf8.count)
        if !fitting.isEmpty {
            onLog?("[client/link-preview] built \(fitting.count) of \(candidates.count) previews")
        }
        return fitting
    }

    /// Trims previews until they and the text fit the ceiling a message's
    /// content has on its own — past it the message could neither ride an
    /// envelope nor a sync page. Images go first, largest first, then whole
    /// previews from the end.
    static func linkPreviews(
        _ previews: [KeepTalkingLinkPreview],
        fittingAlongside textByteCount: Int
    ) -> [KeepTalkingLinkPreview] {
        // Room for the message's other fields.
        let budget = KeepTalkingMessageLimits.maximumContentBytes - textByteCount - 4 * 1024
        var previews = previews
        func encodedSize() -> Int { (try? JSONEncoder().encode(previews).count) ?? .max }

        while encodedSize() > budget,
            let largest = previews.indices
                .filter({ previews[$0].image != nil })
                .max(by: { previews[$0].image!.data.count < previews[$1].image!.data.count })
        {
            previews[largest].image = nil
        }
        while !previews.isEmpty, encodedSize() > budget {
            previews.removeLast()
        }
        return previews
    }

    /// Fetches every URL concurrently and returns what arrived within
    /// `budget`, cancelling the rest.
    ///
    /// The fetches are unstructured on purpose: a task group waits for every
    /// child before it returns, and a fetch stuck in a host lookup can't be
    /// cancelled — the budget would stop being one. Stragglers finish on their
    /// own and their results are dropped.
    static func fetchLinkPreviews(
        _ urls: [URL],
        with fetcher: any KeepTalkingLinkPreviewFetching,
        within budget: Duration
    ) async -> [URL: KeepTalkingFetchedLinkPreview] {
        let uniqueURLs = Set(urls)
        guard !uniqueURLs.isEmpty else { return [:] }
        let (arrivals, continuation) = AsyncStream<(URL, KeepTalkingFetchedLinkPreview?)>.makeStream()
        let fetches = uniqueURLs.map { url in
            Task { continuation.yield((url, await fetcher.preview(for: url))) }
        }
        let deadline = Task {
            try? await Task.sleep(for: budget)
            continuation.finish()
        }

        var results: [URL: KeepTalkingFetchedLinkPreview] = [:]
        var pending = uniqueURLs.count
        for await (url, preview) in arrivals {
            results[url] = preview
            pending -= 1
            if pending == 0 { break }
        }
        continuation.finish()
        deadline.cancel()
        fetches.forEach { $0.cancel() }
        return results
    }
}
