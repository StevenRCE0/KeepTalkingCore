import Foundation
import Testing

@testable import KeepTalkingSDK

struct LinkMetadataParsingTests {
    static let pageURL = URL(string: "https://example.com/blog/launch")!

    private func parse(_ html: String, contentType: String? = nil) -> KeepTalkingLinkMetadata {
        parse(Data(html.utf8), contentType: contentType)
    }

    private func parse(
        _ html: Data,
        contentType: String? = nil,
        byteLimit: Int = KeepTalkingLinkMetadata.headByteLimit
    ) -> KeepTalkingLinkMetadata {
        KeepTalkingLinkMetadata.parse(
            html: html,
            pageURL: Self.pageURL,
            contentType: contentType,
            byteLimit: byteLimit
        )
    }

    @Test func readsOpenGraphWhateverTheAttributeStyle() {
        let metadata = parse(
            """
            <HTML><HEAD>
            <META CONTENT="Launch day" PROPERTY="og:title">
            <meta property='og:description' content='Everything that shipped'>
            <meta property=og:site_name content=Example>
            </HEAD>
            """)
        #expect(metadata.title == "Launch day")
        #expect(metadata.summary == "Everything that shipped")
        #expect(metadata.siteName == "Example")
    }

    @Test func fallsBackToTwitterCardsAndPlainHTML() {
        let metadata = parse(
            """
            <head>
            <title>
              Plain   title
            </title>
            <meta name="description" content="Plain description">
            <meta name="twitter:description" content="Card description">
            <meta name="application-name" content="Example App">
            </head>
            """)
        #expect(metadata.title == "Plain title")
        #expect(metadata.summary == "Card description")
        #expect(metadata.siteName == "Example App")
    }

    @Test func decodesCharacterReferences() {
        let metadata = parse(
            "<head><title>Tom &amp; Jerry &mdash; what&#8217;s new &#x1F389; &#150; &unknown; &amp</title></head>")
        #expect(metadata.title == "Tom & Jerry — what’s new 🎉 – &unknown; &amp")
    }

    /// A regex parser that measures ranges in Characters instead of UTF-16
    /// units drops exactly this tag.
    @Test func keepsEmojiAndFlagsIntact() {
        let metadata = parse(#"<head><meta property="og:title" content="🎉🎉 Launch 🇯🇵"></head>"#)
        #expect(metadata.title == "🎉🎉 Launch 🇯🇵")
    }

    @Test func ignoresMarkupInsideScriptsStylesAndComments() {
        let metadata = parse(
            """
            <head>
            <script>var decoy = '<meta property="og:title" content="script">'; if (a < b) {}</script>
            <!-- <meta property="og:title" content="comment"> -->
            <style>/* <title>style</title> */ a > b {}</style>
            <meta property="og:title" content="Real">
            </head>
            """)
        #expect(metadata.title == "Real")
    }

    @Test(arguments: [
        #"<head><meta property="og:title" content="Head"></head><meta property="og:description" content="After">"#,
        #"<meta property="og:title" content="Head"><BODY class=x><meta property="og:description" content="Body">"#,
    ])
    func stopsAtTheEndOfHead(html: String) {
        let metadata = parse(html)
        #expect(metadata.title == "Head")
        #expect(metadata.summary == nil)
    }

    @Test func resolvesRelativeURLsAgainstThePageOrItsBase() {
        let relative = parse(
            #"<head><meta property="og:image" content="cover.png?w=1&amp;h=2"><link rel=icon href="//cdn.example.com/i.png" sizes=64x64></head>"#
        )
        #expect(relative.image?.url.absoluteString == "https://example.com/blog/cover.png?w=1&h=2")
        #expect(relative.iconURL?.absoluteString == "https://cdn.example.com/i.png")

        let based = parse(
            #"<head><base href="https://static.example.net/assets/"><meta property="og:image" content="cover.png"></head>"#
        )
        #expect(based.image?.url.absoluteString == "https://static.example.net/assets/cover.png")
    }

    @Test func dropsNonWebImageURLs() {
        let metadata = parse(
            #"<head><meta property="og:image" content="javascript:alert(1)"><meta name="twitter:image" content="data:image/png;base64,AAAA"></head>"#
        )
        #expect(metadata.image == nil)
    }

    @Test func keepsTheFirstImageWithItsOwnProperties() {
        let metadata = parse(
            """
            <head>
            <meta property="og:image" content="http://example.com/a.png">
            <meta property="og:image:secure_url" content="https://example.com/a.png">
            <meta property="og:image:width" content="1200">
            <meta property="og:image:height" content="630">
            <meta property="og:image:alt" content="A cover">
            <meta property="og:image" content="https://example.com/b.png">
            <meta property="og:image:width" content="10">
            </head>
            """)
        #expect(
            metadata.image
                == .init(url: URL(string: "https://example.com/a.png")!, width: 1200, height: 630, alt: "A cover"))
    }

    @Test func picksTheIconClosestToPreviewSize() {
        let metadata = parse(
            """
            <head>
            <link rel="shortcut icon" href="/favicon-16.png" sizes="16x16">
            <link rel="mask-icon" href="/mask.svg">
            <link rel="icon" type="image/svg+xml" href="/icon.svg">
            <link rel="apple-touch-icon" href="/touch.png">
            <link rel="icon" href="/favicon-512.png" sizes="512x512">
            </head>
            """)
        #expect(metadata.iconURL?.absoluteString == "https://example.com/touch.png")
    }

    @Test func fallsBackToWindows1252ForUndeclaredLegacyBytes() {
        let html = Data("<head><title>Caf".utf8) + Data([0xE9]) + Data("</title></head>".utf8)
        #expect(parse(html).title == "Café")
    }

    @Test func readsUTF16WithAByteOrderMark() throws {
        let html = try #require("<head><title>Sixteen bits</title></head>".data(using: .utf16LittleEndian))
        #expect(parse(Data([0xFF, 0xFE]) + html).title == "Sixteen bits")
    }

    #if canImport(Darwin)
    @Test func decodesGBKDeclaredByTheDocumentOrTheTransport() throws {
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let title = "发布日：新功能一览"
        let encodedTitle = try #require(title.data(using: gb18030))

        let declared = Data(#"<head><meta charset="gbk"><title>"#.utf8) + encodedTitle + Data("</title>".utf8)
        #expect(parse(declared).title == title)

        // The transport's charset outranks a wrong in-document declaration.
        let mislabelled =
            Data(#"<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><title>"#.utf8)
            + encodedTitle + Data("</title>".utf8)
        #expect(parse(mislabelled, contentType: "text/html; charset=GB2312").title == title)
    }
    #endif

    @Test func stopsReadingAtTheByteLimit() {
        let early = #"<head><meta property="og:title" content="Early">"#
        let html = early + String(repeating: " ", count: 200) + #"<meta property="og:description" content="Late">"#
        let metadata = parse(Data(html.utf8), byteLimit: early.utf8.count + 50)
        #expect(metadata.title == "Early")
        #expect(metadata.summary == nil)
    }

    @Test(arguments: [
        #"<head><meta property="og:title" content="Whole"><meta property="og:description" content="Cut of"#,
        #"<head><meta property="og:title" content="Whole"><meta property=og:description content=Cut"#,
    ])
    func dropsATagCutOffMidway(html: String) {
        let metadata = parse(html)
        #expect(metadata.title == "Whole")
        #expect(metadata.summary == nil)
    }

    @Test func clampsOverlongText() throws {
        let metadata = parse("<head><title>\(String(repeating: "a", count: 1_000))</title></head>")
        let title = try #require(metadata.title)
        #expect(title.count == 300)
        #expect(title.hasSuffix("…"))
    }

    @Test func aPageWithoutMetadataIsEmpty() {
        #expect(parse("<!doctype html><html><head></head><body><title>Not this</title></body></html>").isEmpty)
    }
}
