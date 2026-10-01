import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct LinkPreviewSendPathTests {
    /// Answers from a fixed table; `slowURL` stands in for a fetch stuck where
    /// cancellation can't reach it (a host lookup).
    private struct StubFetcher: KeepTalkingLinkPreviewFetching {
        var previews: [URL: KeepTalkingFetchedLinkPreview] = [:]
        var slowURL: URL?

        func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview? {
            if url == slowURL {
                await Task { try? await Task.sleep(for: .seconds(2)) }.value
            }
            return previews[url]
        }
    }

    static let postURL = URL(string: "https://example.com/post")!
    static let image = KeepTalkingLinkPreview.Image(
        data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
        mimeType: "image/jpeg",
        width: 480,
        height: 252,
        alt: "Cover"
    )
    static let postPreview = KeepTalkingFetchedLinkPreview(
        metadata: KeepTalkingLinkMetadata(
            title: "A post",
            summary: "About things",
            siteName: "Example",
            image: .init(url: URL(string: "https://example.com/cover.jpg")!, alt: "Cover")
        ),
        image: image
    )

    // MARK: Which links

    @Test(arguments: [
        ("Look at this:\nhttps://example.com/post", ["https://example.com/post"]),
        (
            "<https://example.com/a>\n[Title](https://example.com/b \"hover\")",
            [
                "https://example.com/a", "https://example.com/b",
            ]
        ),
        ("inline https://example.com/post link", []),
        ("- https://example.com/listed\n> https://example.com/quoted", []),
        ("```\nhttps://example.com/fenced\n```\n    https://example.com/indented", []),
        (
            "https://example.com/post.\nhttps://en.wikipedia.org/wiki/Swift_(language)",
            [
                "https://en.wikipedia.org/wiki/Swift_(language)"
            ]
        ),
        ("ftp://example.com/file\n![image](https://example.com/i.png)", []),
        (
            "https://a.example\nhttps://a.example\nhttps://b.example\nhttps://c.example\nhttps://d.example",
            [
                "https://a.example", "https://b.example", "https://c.example",
            ]
        ),
        // A fence closes only on its own character, at least as long, alone.
        ("````\n```\nhttps://example.com/inside\n````\nhttps://example.com/after", ["https://example.com/after"]),
        ("```swift\nhttps://example.com/a\n```swift\nhttps://example.com/b\n```", []),
        // Four spaces in is indented code, not a fence.
        ("    ```\nhttps://example.com/unfenced", ["https://example.com/unfenced"]),
        // Two links are a sentence, not a link line; a label may nest brackets.
        ("[a](https://example.com/x) and [b](https://example.com/y)", []),
        ("[see [docs]](https://example.com/docs)", ["https://example.com/docs"]),
        ("<https://example.com/a b>\n<https://example.com/c>", ["https://example.com/c"]),
        ("Look:\r\nhttps://example.com/crlf\r\n", ["https://example.com/crlf"]),
    ])
    func findsLinksStandingOnTheirOwnLines(text: String, expected: [String]) {
        #expect(KeepTalkingLinkPreview.candidateURLs(in: text) == expected)
    }

    // MARK: Budget and size

    @Test func sendStopsWaitingAtTheBudget() async {
        let slow = URL(string: "https://slow.example")!
        let fetcher = StubFetcher(previews: [Self.postURL: Self.postPreview], slowURL: slow)

        let started = ContinuousClock.now
        let results = await KeepTalkingClient.fetchLinkPreviews(
            [Self.postURL, slow],
            with: fetcher,
            within: .milliseconds(200)
        )
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(results[Self.postURL] != nil)
        #expect(results[slow] == nil)
    }

    @Test func previewsShedImagesThenPreviewsToFitBesideTheText() {
        // 64 KiB each once base64'd: one fits the 96 KiB left below, two don't.
        let bulky = KeepTalkingLinkPreview.Image(data: Data(count: 48 * 1024), mimeType: "image/jpeg")
        let previews = [
            KeepTalkingLinkPreview(url: "https://a.example", title: "A", image: bulky),
            KeepTalkingLinkPreview(url: "https://b.example", title: "B", image: bulky),
        ]
        let limit = KeepTalkingMessageLimits.maximumContentBytes

        #expect(KeepTalkingClient.linkPreviews(previews, fittingAlongside: 1_000) == previews)

        let imagesDropped = KeepTalkingClient.linkPreviews(previews, fittingAlongside: limit - 100 * 1024)
        #expect(imagesDropped.map(\.url) == ["https://a.example", "https://b.example"])
        #expect(imagesDropped.filter { $0.image != nil }.count == 1)

        #expect(KeepTalkingClient.linkPreviews(previews, fittingAlongside: limit).isEmpty)
    }

    // MARK: The send path

    @Test func sentMessagesCarryPreviewsWithInlineImages() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let client = makeClient(localStore: localStore)
        client.setLinkPreviewFetcher(StubFetcher(previews: [Self.postURL: Self.postPreview]))
        let contextID = UUID()

        try await client.send("Look at this:\n\(Self.postURL.absoluteString)", in: contextID)
        try await client.send("Reasoning about \n\(Self.postURL.absoluteString)", in: contextID, type: .thinking)

        let messages = try await KeepTalkingContextMessage.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .sort(\.$timestamp, .ascending)
            .all()
        try #require(messages.count == 2)
        let preview = try #require(messages[0].linkPreviews?.first)
        #expect(preview.url == Self.postURL.absoluteString)
        #expect(preview.title == "A post")
        #expect(preview.siteName == "Example")
        #expect(preview.image?.data == Self.image.data)
        #expect(preview.image?.width == 480)
        #expect(preview.image?.alt == "Cover")
        #expect(messages[1].linkPreviews == nil)
    }

    @Test func aClientWithoutAFetcherSendsNoPreviews() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let client = makeClient(localStore: localStore)
        let contextID = UUID()

        try await client.send(Self.postURL.absoluteString, in: contextID)

        let message = try #require(
            try await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$context.$id == contextID)
                .first()
        )
        #expect(message.linkPreviews == nil)
    }

    // MARK: The wire

    @Test func previewsSurviveTheWireAndOldPeersStillDecode() throws {
        let context = KeepTalkingContext()
        context.id = UUID()
        let message = KeepTalkingContextMessage(context: context, sender: .node(node: UUID()), content: "x")
        message.linkPreviews = [
            KeepTalkingLinkPreview(
                url: "https://example.com/post",
                title: "A post",
                image: .init(data: Self.image.data, mimeType: "image/jpeg", width: 480, height: 252)
            )
        ]

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(KeepTalkingContextMessage.self, from: encoded)
        #expect(decoded.linkPreviews == message.linkPreviews)

        // A node that predates previews sends no such key.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "linkPreviews")
        object.removeValue(forKey: "link_previews")
        let legacy = try JSONDecoder().decode(
            KeepTalkingContextMessage.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.linkPreviews == nil)
        #expect(legacy.content == "x")
    }

    // MARK: Where fetches may go

    @Test(arguments: [
        ("http://localhost:8080/", false),
        ("http://printer.local/", false),
        ("http://127.0.0.1/", false),
        ("http://10.1.2.3/", false),
        ("http://172.20.0.1/", false),
        ("http://192.168.1.1/admin", false),
        ("http://169.254.169.254/latest/meta-data", false),
        ("http://100.100.1.1/", false),
        ("http://[::1]/", false),
        ("http://[fd00::1]/", false),
        ("http://[::ffff:192.168.0.1]/", false),
        ("ftp://8.8.8.8/", false),
        ("https://8.8.8.8/", true),
        ("https://[2001:4860:4860::8888]/", true),
    ])
    func fetchesOnlyPubliclyRoutableHosts(url: String, allowed: Bool) async throws {
        let url = try #require(URL(string: url))
        #expect(LinkPreviewAddressPolicy.allows(url) == allowed)
        // The async path the fetcher takes gives the same answer.
        #expect(await LinkPreviewAddressPolicy.admits(url) == allowed)
    }

    private func makeClient(localStore: any KeepTalkingLocalStore) -> KeepTalkingClient {
        KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!,
                node: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
            ),
            localStore: localStore
        )
    }
}
