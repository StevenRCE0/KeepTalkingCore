import Foundation

/// A link preview carried by the message that contains the link.
///
/// The sending node builds it on the send path — before the message row exists,
/// because messages are immutable once they sync — so every other node renders
/// the preview without ever contacting the linked site. The image travels
/// inline, small enough (see `KeepTalkingLinkPreviewFetcher`) that the message
/// stays one envelope and one sync item.
///
/// Every string comes from the linked page's author: render it as text, never
/// as markup.
public struct KeepTalkingLinkPreview: Codable, Sendable, Hashable {
    public struct Image: Codable, Sendable, Hashable {
        /// Encoded image bytes; base64 in every JSON form of the message.
        public var data: Data
        public var mimeType: String
        /// Pixel size, so a renderer can reserve the image's box up front.
        public var width: Int?
        public var height: Int?
        public var alt: String?

        public init(data: Data, mimeType: String, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
            self.data = data
            self.mimeType = mimeType
            self.width = width
            self.height = height
            self.alt = alt
        }
    }

    /// The link exactly as the message text writes it. Renderers match the
    /// links they parse against this string.
    public var url: String
    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var image: Image?

    public init(
        url: String,
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        image: Image? = nil
    ) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.image = image
    }
}

// MARK: - Which links get a preview

extension KeepTalkingLinkPreview {
    /// Previews one message may carry. Each costs a page fetch on the send path
    /// and possibly an image transfer to every peer.
    public static let maximumPerMessage = 3

    /// The links in `text` that stand on a line of their own — a bare
    /// `https://…`, `<https://…>` or `[text](https://…)` and nothing else —
    /// outside fenced and indented code. That is the line a renderer turns into
    /// a preview block; a link inside a sentence, list item or quote stays an
    /// ordinary link and is not fetched.
    ///
    /// A bare URL ending in punctuation GFM leaves out of autolinks (`.`, `,`,
    /// `)` without its `(` …) doesn't qualify: the renderer would read that
    /// line as a link plus text.
    public static func candidateURLs(in text: String) -> [String] {
        var urls: [String] = []
        var openFence: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = openFence {
                if line.hasPrefix(fence) { openFence = nil }
                continue
            }
            if let fence = ["```", "~~~"].first(where: { line.hasPrefix($0) }) {
                openFence = fence
                continue
            }
            let indentation = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            guard indentation.count < 4, !indentation.contains("\t"),
                let url = standaloneURL(in: line), !urls.contains(url)
            else { continue }
            urls.append(url)
            if urls.count == maximumPerMessage { break }
        }
        return urls
    }

    private static func standaloneURL(in line: String) -> String? {
        if line.hasPrefix("<"), line.hasSuffix(">") {
            return webURLString(line.dropFirst().dropLast())
        }
        if line.hasPrefix("["), line.hasSuffix(")"),
            let split = line.range(of: "](", options: .backwards)
        {
            var destination = line[split.upperBound..<line.index(before: line.endIndex)]
                .trimmingCharacters(in: .whitespaces)[...]
            if let space = destination.firstIndex(where: \.isWhitespace) {
                let title = destination[space...].trimmingCharacters(in: .whitespaces)
                guard title.count >= 2, let quote = title.first, quote == "\"" || quote == "'",
                    title.last == quote
                else { return nil }
                destination = destination[..<space]
            }
            if destination.hasPrefix("<"), destination.hasSuffix(">") {
                destination = destination.dropFirst().dropLast()
            }
            return webURLString(destination)
        }
        guard !line.contains(where: \.isWhitespace), let last = line.last, !"?!.,:*_~'\"".contains(last),
            line.filter({ $0 == "(" }).count == line.filter({ $0 == ")" }).count
        else { return nil }
        return webURLString(line[...])
    }

    private static func webURLString(_ candidate: Substring) -> String? {
        let lowered = candidate.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"),
            !candidate.contains(where: \.isWhitespace),
            let components = URLComponents(string: String(candidate)),
            let host = components.host, !host.isEmpty
        else { return nil }
        return String(candidate)
    }
}
