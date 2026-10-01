import Foundation

/// A deliberately small HTML tokenizer that reads only what a link preview
/// needs from the top of a page: `<meta>`, `<link>` and `<base>` tags and the
/// `<title>` text.
///
/// It walks raw bytes instead of a decoded string. Every character that shapes
/// HTML markup is ASCII, and the legacy encodings pages still ship in (GBK,
/// Big5, Shift_JIS, EUC-*) never reuse `<`, `>`, `"` or `'` as a trailing byte,
/// so tags can be found before the charset is known — even when the charset is
/// only declared by one of those tags. Values are decoded afterwards, once it
/// is (see `HTMLText`).
///
/// Scanning ends at `</head>` or `<body`. Script, style and the other raw-text
/// elements are skipped whole, so a `"<meta …>"` string inside inline
/// JavaScript is never mistaken for a tag. A tag cut off before its `>` — by a
/// byte limit or a broken page — is dropped rather than half-read.
struct HTMLHeadScanner {
    struct Tag {
        /// Lowercased tag name: `meta`, `link` or `base`.
        let name: String
        /// Lowercased attribute names mapped to their raw value bytes. A
        /// repeated attribute keeps its first value, as in the HTML spec.
        let attributes: [String: [UInt8]]

        subscript(attribute: String) -> [UInt8]? { attributes[attribute] }
    }

    private(set) var tags: [Tag] = []
    /// Raw bytes between `<title>` and `</title>`, from the first title only.
    private(set) var title: [UInt8]?

    private let bytes: [UInt8]
    private var index = 0

    private static let collectedElements: Set<String> = ["meta", "link", "base"]
    /// Elements whose contents are raw text: markup inside them isn't markup.
    private static let rawTextElements: Set<String> = [
        "script", "style", "template", "textarea", "xmp", "iframe", "noembed", "noframes",
    ]

    init(scanning bytes: [UInt8]) {
        self.bytes = bytes
        scan()
    }

    private mutating func scan() {
        while let open = position(of: "<".utf8, from: index) {
            index = open + 1
            guard index < bytes.count else { return }
            switch bytes[index] {
                case UInt8(ascii: "!"):
                    if matches("--", at: index + 1) {
                        guard let close = position(of: "-->".utf8, from: index + 3) else { return }
                        index = close + 3
                    } else {
                        guard skipPastTagEnd() else { return }
                    }
                case UInt8(ascii: "?"):
                    guard skipPastTagEnd() else { return }
                case UInt8(ascii: "/"):
                    index += 1
                    if readName() == "head" { return }
                    guard skipPastTagEnd() else { return }
                case let byte where Self.isLetter(byte):
                    let name = readName()
                    let collect = Self.collectedElements.contains(name)
                    guard let attributes = readAttributes(collecting: collect) else { return }
                    if collect {
                        tags.append(Tag(name: name, attributes: attributes))
                    } else if name == "body" {
                        return
                    } else if name == "title" {
                        guard let close = endTag("title") else { return }
                        if title == nil { title = Array(bytes[index..<close]) }
                        index = close
                    } else if Self.rawTextElements.contains(name) {
                        guard let close = endTag(name) else { return }
                        index = close
                    }
                default:
                    continue  // A bare "<" in text.
            }
        }
    }

    /// Reads a tag name at `index`, lowercased, leaving `index` just past it.
    private mutating func readName() -> String {
        let start = index
        while index < bytes.count, !Self.endsName(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index].map(Self.lowercased), as: UTF8.self)
    }

    /// Reads attributes up to and past the tag's closing `>`. Nil when the page
    /// ends inside the tag.
    private mutating func readAttributes(collecting: Bool) -> [String: [UInt8]]? {
        var attributes: [String: [UInt8]] = [:]
        while true {
            while index < bytes.count, Self.isSpace(bytes[index]) || bytes[index] == UInt8(ascii: "/") {
                index += 1
            }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ">") {
                index += 1
                return attributes
            }

            let nameStart = index
            index += 1  // The first byte belongs to the name, even an "=".
            while index < bytes.count, !Self.endsName(bytes[index]), bytes[index] != UInt8(ascii: "=") {
                index += 1
            }
            let nameEnd = index
            skipSpaces()

            var value: ArraySlice<UInt8> = []
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                skipSpaces()
                guard index < bytes.count else { return nil }
                let quote = bytes[index]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
                    value = bytes[(index + 1)..<close]
                    index = close + 1
                } else {
                    let start = index
                    while index < bytes.count, !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") {
                        index += 1
                    }
                    value = bytes[start..<index]
                }
            }

            guard collecting else { continue }
            let name = String(decoding: bytes[nameStart..<nameEnd].map(Self.lowercased), as: UTF8.self)
            if attributes[name] == nil { attributes[name] = Array(value) }
        }
    }

    /// Moves past the next `>`; false when the page ends first.
    private mutating func skipPastTagEnd() -> Bool {
        guard let close = bytes[index...].firstIndex(of: UInt8(ascii: ">")) else { return false }
        index = close + 1
        return true
    }

    private mutating func skipSpaces() {
        while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
    }

    /// Where the `</name` closing a title or raw-text element starts, if the
    /// page has one.
    private func endTag(_ name: String) -> Int? {
        var from = index
        while let open = position(of: "</".utf8, from: from) {
            let after = open + 2 + name.utf8.count
            if matches(name, at: open + 2), after == bytes.count || Self.endsName(bytes[after]) {
                return open
            }
            from = open + 1
        }
        return nil
    }

    private func position(of needle: some Collection<UInt8>, from start: Int) -> Int? {
        guard let first = needle.first, start < bytes.count else { return nil }
        var from = start
        while let hit = bytes[from...].firstIndex(of: first) {
            if bytes[hit...].starts(with: needle) { return hit }
            from = hit + 1
        }
        return nil
    }

    /// Whether the bytes at `offset` spell `word` (given in lowercase),
    /// ignoring ASCII case.
    private func matches(_ word: String, at offset: Int) -> Bool {
        let word = word.utf8
        guard offset + word.count <= bytes.count else { return false }
        return zip(bytes[offset...], word).allSatisfy { Self.lowercased($0) == $1 }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func endsName(_ byte: UInt8) -> Bool {
        isSpace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">")
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }
}
