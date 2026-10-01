import Foundation

/// What a web page says about itself for a link preview: Open Graph first,
/// Twitter Card and plain HTML tags as fallbacks.
///
/// Built from the top of the page alone by `parse(html:pageURL:contentType:)`.
/// Every string comes from the page's author, so a renderer must show it as
/// text, never as markup.
public struct KeepTalkingLinkMetadata: Sendable, Codable, Equatable {
    public struct Image: Sendable, Codable, Equatable {
        public var url: URL
        /// The declared pixel size (`og:image:width` / `height`). Pages get this
        /// wrong often enough that a renderer should prefer the size of the
        /// bytes it actually fetched.
        public var width: Int?
        public var height: Int?
        public var alt: String?

        public init(url: URL, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
            self.url = url
            self.width = width
            self.height = height
            self.alt = alt
        }
    }

    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var image: Image?
    /// The declared icon closest to preview size. Nil when the page declares
    /// none — trying `/favicon.ico` is the fetcher's guess, not the page's word.
    public var iconURL: URL?

    public init(
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        image: Image? = nil,
        iconURL: URL? = nil
    ) {
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.image = image
        self.iconURL = iconURL
    }

    /// No title, summary or image: nothing worth drawing a card for.
    public var isEmpty: Bool { title == nil && summary == nil && image == nil }
}

// MARK: - Parsing

extension KeepTalkingLinkMetadata {
    /// How much of a page is read when `</head>` doesn't come first.
    static let headByteLimit = 512 * 1024

    /// Longest text kept per field; cards clamp further when they render.
    private enum Limit {
        static let title = 300
        static let summary = 600
        static let siteName = 120
        static let alt = 300
    }

    /// Parses the start of an HTML document.
    ///
    /// - Parameters:
    ///   - html: The response body, or as much of it as was read. Bytes past
    ///     `byteLimit` are ignored.
    ///   - pageURL: Where the document was served from, after redirects.
    ///     Relative image and icon URLs resolve against it, or against the
    ///     page's `<base href>`.
    ///   - contentType: The response's `Content-Type`. Its `charset` outranks
    ///     the document's own declaration.
    static func parse(
        html: Data,
        pageURL: URL,
        contentType: String? = nil,
        byteLimit: Int = headByteLimit
    ) -> KeepTalkingLinkMetadata {
        var bytes = [UInt8](html.prefix(byteLimit))
        var encoding: String.Encoding?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
            encoding = .utf8
        } else if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) {
            // UTF-16 is the one encoding whose markup isn't ASCII bytes, so it
            // is transcoded up front and scanned like any UTF-8 page.
            let bigEndian = bytes[0] == 0xFE
            let units = bytes.dropFirst(2).prefix((bytes.count - 2) & ~1)
            let text = String(bytes: units, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
            bytes = Array((text ?? "").utf8)
            encoding = .utf8
        }

        let head = HTMLHeadScanner(scanning: bytes)
        return KeepTalkingLinkMetadata(
            head: head,
            encoding: encoding ?? HTMLText.declaredEncoding(contentType: contentType, tags: head.tags),
            pageURL: pageURL
        )
    }

    private init(head: HTMLHeadScanner, encoding: String.Encoding?, pageURL: URL) {
        let meta = MetaTags(head.tags)
        func text(_ bytes: [UInt8]?, _ limit: Int) -> String? {
            HTMLText.text(bytes, declared: encoding, limit: limit)
        }
        let base =
            head.tags.first { $0.name == "base" && $0["href"] != nil }
            .flatMap { Self.webURL($0["href"], encoding: encoding, relativeTo: pageURL) } ?? pageURL
        func url(_ bytes: [UInt8]?) -> URL? {
            Self.webURL(bytes, encoding: encoding, relativeTo: base)
        }

        title =
            text(meta.first["og:title"], Limit.title)
            ?? text(meta.first["twitter:title"], Limit.title)
            ?? text(head.title, Limit.title)
        summary =
            text(meta.first["og:description"], Limit.summary)
            ?? text(meta.first["twitter:description"], Limit.summary)
            ?? text(meta.first["description"], Limit.summary)
        siteName =
            text(meta.first["og:site_name"], Limit.siteName)
            ?? text(meta.first["application-name"], Limit.siteName)

        let twitterAlt = text(meta.first["twitter:image:alt"], Limit.alt)
        let secureImage = url(meta.image["secure_url"]).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        if let imageURL = secureImage ?? url(meta.image["url"]) {
            image = Image(
                url: imageURL,
                width: Self.dimension(meta.image["width"]),
                height: Self.dimension(meta.image["height"]),
                alt: text(meta.image["alt"], Limit.alt) ?? twitterAlt
            )
        } else if let imageURL = url(meta.first["twitter:image"]) ?? url(meta.first["twitter:image:src"]) {
            image = Image(url: imageURL, alt: twitterAlt)
        }

        iconURL = Self.icon(in: head.tags, resolve: url)
    }

    /// An http(s) URL from an attribute value, resolved against `base`.
    /// Anything else — `javascript:`, `data:`, junk — is dropped.
    private static func webURL(_ bytes: [UInt8]?, encoding: String.Encoding?, relativeTo base: URL) -> URL? {
        guard let bytes else { return nil }
        let raw = HTMLText.decodingCharacterReferences(HTMLText.decode(bytes, declared: encoding))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "%20")
        guard !raw.isEmpty, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func dimension(_ bytes: [UInt8]?) -> Int? {
        guard let bytes, let value = Int(HTMLText.ascii(bytes).trimmingCharacters(in: .whitespaces)),
            (1...20_000).contains(value)
        else { return nil }
        return value
    }

    /// The declared icon best suited to a preview card: the smallest of at
    /// least 64 px, else the largest. An `apple-touch-icon` counts as 180 px
    /// and a plain `icon` as 16 px unless `sizes` says otherwise. SVG icons are
    /// skipped; the image downscaler can't rasterise them.
    private static func icon(in tags: [HTMLHeadScanner.Tag], resolve: ([UInt8]?) -> URL?) -> URL? {
        var best: (url: URL, size: Int)?
        for tag in tags where tag.name == "link" {
            guard let rel = tag["rel"] else { continue }
            let rels = HTMLText.ascii(rel).lowercased().split(whereSeparator: \.isWhitespace)
            let isTouchIcon = rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed")
            guard isTouchIcon || rels.contains("icon") else { continue }
            if let type = tag["type"], HTMLText.ascii(type).lowercased().contains("svg") { continue }
            guard let url = resolve(tag["href"]), url.pathExtension.lowercased() != "svg" else { continue }

            let size = declaredSize(tag["sizes"]) ?? (isTouchIcon ? 180 : 16)
            if let current = best, !isBetterIcon(size, than: current.size) { continue }
            best = (url, size)
        }
        return best?.url
    }

    private static func isBetterIcon(_ size: Int, than current: Int) -> Bool {
        switch (size >= 64, current >= 64) {
            case (true, true): return size < current
            case (true, false): return true
            case (false, true): return false
            case (false, false): return size > current
        }
    }

    /// The largest edge in a `sizes` attribute ("16x16 32x32"); nil for "any".
    private static func declaredSize(_ bytes: [UInt8]?) -> Int? {
        guard let bytes else { return nil }
        return HTMLText.ascii(bytes).lowercased()
            .split(whereSeparator: \.isWhitespace)
            .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            .max()
    }
}

/// The page's `<meta>` tags keyed the way Open Graph reads them.
private struct MetaTags {
    /// The first `content` for each key (`property`, else `name`), lowercased.
    var first: [String: [UInt8]] = [:]
    /// The first `og:image` (`url`) and the structured `og:image:*` properties
    /// that belong to it. Open Graph binds those to the image above them, so
    /// the ones after a second `og:image` describe that one, not this.
    var image: [String: [UInt8]] = [:]

    init(_ tags: [HTMLHeadScanner.Tag]) {
        var imageCount = 0
        for tag in tags where tag.name == "meta" {
            guard let rawKey = tag["property"] ?? tag["name"], let content = tag["content"] else { continue }
            let key = HTMLText.ascii(rawKey).trimmingCharacters(in: .whitespaces).lowercased()
            if key == "og:image" || key == "og:image:url" {
                imageCount += 1
                if imageCount == 1 { image["url"] = content }
            } else if key.hasPrefix("og:image:"), imageCount <= 1 {
                let property = String(key.dropFirst("og:image:".count))
                if image[property] == nil { image[property] = content }
            }
            if first[key] == nil { first[key] = content }
        }
    }
}
