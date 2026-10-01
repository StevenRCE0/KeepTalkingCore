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
    /// The rules are `LinkLine`'s patterns, written the same way as ChatCanvas's
    /// `segmentMarkdown` (src/lib/linkLines.ts) so the card lands where the
    /// sender found the link. Change one, change both.
    public static func candidateURLs(in text: String) -> [String] {
        let rules = LinkLine()
        var urls: [String] = []
        var openFence: Substring?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if let fence = openFence {
                if rules.closes(fence, line) { openFence = nil }
                continue
            }
            if let opened = line.wholeMatch(of: rules.fenceOpener) {
                openFence = opened.output.1 ?? opened.output.2
                continue
            }
            guard let url = rules.standaloneURL(in: line), !urls.contains(url) else { continue }
            urls.append(url)
            if urls.count == maximumPerMessage { break }
        }
        return urls
    }
}

/// One line of a message, read by CommonMark's rules as far as previews care.
///
/// Built once per message rather than kept in statics: `Regex` isn't
/// `Sendable`.
private struct LinkLine {
    /// A code fence: three or more backticks (whose info string holds no
    /// backtick) or tildes, indented at most three spaces.
    let fenceOpener = #/ {0,3}(?:(`{3,})[^`]*|(~{3,}).*)/#
    /// A fence that closes: the opener's character, at least as many times,
    /// and nothing after it.
    let fenceCloser = #/ {0,3}(`+|~+)[ \t]*/#
    /// The text of a line that isn't indented code: at most three spaces in.
    let content = #/ {0,3}(\S(?:.*\S)?)\s*/#
    /// `<https://…>`, an autolink.
    let autolink = #/<((?i:https?)://[^\s<>]+)>/#
    /// `[label](destination "title")` and nothing else; the label may hold one
    /// level of balanced brackets, the destination may be `<…>`.
    let inlineLink =
        #/\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*(?:<([^<>\s]+)>|(\S+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/#
    /// A bare URL, minus any that end in punctuation GFM leaves out of an
    /// autolink — the renderer would read that line as a link plus text.
    let bareURL = #/(?i:https?)://\S*[^\s?!.,:*_~'"]/#
    /// An http(s) URL with no whitespace; `webURL(_:)` then wants a host.
    let httpURL = #/(?i:https?)://\S+/#

    func closes(_ opener: Substring, _ line: Substring) -> Bool {
        guard let fence = line.wholeMatch(of: fenceCloser)?.output.1 else { return false }
        return fence.first == opener.first && fence.count >= opener.count
    }

    func standaloneURL(in line: Substring) -> String? {
        guard let text = line.wholeMatch(of: content)?.output.1 else { return nil }
        if let link = text.wholeMatch(of: autolink) {
            return webURL(link.output.1)
        }
        if let link = text.wholeMatch(of: inlineLink) {
            return (link.output.2 ?? link.output.3).flatMap(webURL)
        }
        // GFM keeps a closing parenthesis only when it has an opening one.
        guard text.wholeMatch(of: bareURL) != nil,
            text.filter({ $0 == "(" }).count == text.filter({ $0 == ")" }).count
        else { return nil }
        return webURL(text)
    }

    /// `candidate` when it is an http(s) URL with a host.
    private func webURL(_ candidate: Substring) -> String? {
        guard candidate.wholeMatch(of: httpURL) != nil,
            let host = URLComponents(string: String(candidate))?.host, !host.isEmpty
        else { return nil }
        return String(candidate)
    }
}
