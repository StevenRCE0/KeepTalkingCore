import Foundation

/// Turns the raw values `HTMLHeadScanner` captures into display text: picks the
/// page's charset, decodes, resolves character references and collapses
/// whitespace.
enum HTMLText {
    // MARK: Charset

    /// The charset a page declares, in the order the WHATWG encoding-sniffing
    /// algorithm gives: the transport's `Content-Type` first, then the
    /// document's own `<meta charset>` or `http-equiv` declaration. Nil when
    /// neither names an encoding this platform can decode.
    static func declaredEncoding(contentType: String?, tags: [HTMLHeadScanner.Tag]) -> String.Encoding? {
        if let label = contentType.flatMap({ charsetParameter(in: $0) }),
            let encoding = encoding(forLabel: label)
        {
            return encoding
        }
        for tag in tags where tag.name == "meta" {
            if let charset = tag["charset"], let encoding = encoding(forLabel: ascii(charset)) {
                return encoding
            }
            if let equiv = tag["http-equiv"], ascii(equiv).lowercased() == "content-type",
                let content = tag["content"],
                let label = charsetParameter(in: ascii(content)),
                let encoding = encoding(forLabel: label)
            {
                return encoding
            }
        }
        return nil
    }

    /// Maps a charset label to a Foundation encoding, following the browser
    /// conventions pages rely on: `iso-8859-1` and `us-ascii` mean
    /// windows-1252, every GB label means GB18030 (their common superset), and
    /// a declared UTF-16 means UTF-8 — a document whose `<meta>` could be read
    /// as ASCII isn't UTF-16.
    static func encoding(forLabel label: String) -> String.Encoding? {
        let label =
            label
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            .lowercased()
        switch label {
            case "utf-8", "utf8", "unicode-1-1-utf-8", "utf-16", "utf-16le", "utf-16be":
                return .utf8
            case "us-ascii", "ascii", "iso-8859-1", "iso8859-1", "latin1", "l1",
                "windows-1252", "cp1252", "x-cp1252":
                return .windowsCP1252
            case "shift_jis", "shift-jis", "sjis", "x-sjis", "windows-31j", "ms932", "csshiftjis":
                return .shiftJIS
            case "euc-jp", "x-euc-jp":
                return .japaneseEUC
            case "iso-2022-jp":
                return .iso2022JP
            case "iso-8859-2", "latin2":
                return .isoLatin2
            case "windows-1250": return .windowsCP1250
            case "windows-1251": return .windowsCP1251
            case "windows-1253": return .windowsCP1253
            case "windows-1254": return .windowsCP1254
            default:
                return platformEncoding(forLabel: label)
        }
    }

    /// Labels Foundation has no named constant for (GB18030, Big5, EUC-KR,
    /// KOI8-R, …). Darwin resolves them through CoreFoundation's IANA table;
    /// elsewhere they stay unknown and the page decodes as if undeclared.
    private static func platformEncoding(forLabel label: String) -> String.Encoding? {
        #if canImport(Darwin)
        let chinese: Set<String> = [
            "gb2312", "gbk", "x-gbk", "cp936", "ms936", "windows-936", "gb18030",
            "csgb2312", "chinese", "gb_2312", "gb_2312-80", "iso-ir-58",
        ]
        let name = chinese.contains(label) ? "gb18030" : label
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        #else
        return nil
        #endif
    }

    /// The `charset=` parameter of a `Content-Type`-style value.
    static func charsetParameter(in value: String) -> String? {
        let lowered = value.lowercased()
        guard let key = lowered.range(of: "charset") else { return nil }
        var rest = lowered[key.upperBound...].drop(while: { $0 == " " })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\"" || $0 == "'" })
        let label = rest.prefix(while: { !";,\"' \t".contains($0) })
        return label.isEmpty ? nil : String(label)
    }

    // MARK: Text

    /// A captured value as display text: decoded, references resolved,
    /// whitespace collapsed and clamped to `limit` characters. Nil when empty.
    static func text(_ bytes: [UInt8]?, declared encoding: String.Encoding?, limit: Int) -> String? {
        guard let bytes else { return nil }
        let text = collapsingWhitespace(decodingCharacterReferences(decode(bytes, declared: encoding)))
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// Decodes one captured value. With no declared charset, strict UTF-8 is
    /// tried before windows-1252, the way browsers treat an unlabelled page;
    /// whatever still fails is read as lossy UTF-8.
    static func decode(_ bytes: [UInt8], declared encoding: String.Encoding?) -> String {
        if let encoding {
            if encoding != .utf8, let text = String(bytes: bytes, encoding: encoding) { return text }
        } else if let text = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .windowsCP1252)
        {
            return text
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Tag names, attribute names and keywords are ASCII by definition.
    static func ascii(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Character references

    /// Resolves `&name;`, `&#123;` and `&#x1F389;`. A named reference needs its
    /// semicolon and must be in `namedReferences`; anything else stays as
    /// written. Numeric references get the HTML spec's repairs: NUL, surrogates
    /// and out-of-range values become U+FFFD, and 0x80–0x9F are read as the
    /// windows-1252 characters pages mean by them.
    static func decodingCharacterReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "&", let reference = reference(in: scalars, at: index) {
                result.append(contentsOf: reference.text.unicodeScalars)
                index += reference.length
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    private static func reference(in scalars: [Unicode.Scalar], at start: Int) -> (text: String, length: Int)? {
        var index = start + 1
        guard index < scalars.count else { return nil }

        if scalars[index] == "#" {
            index += 1
            var radix: UInt32 = 10
            if index < scalars.count, scalars[index] == "x" || scalars[index] == "X" {
                radix = 16
                index += 1
            }
            let digitsStart = index
            var value: UInt32 = 0
            while index < scalars.count, let digit = hexDigitValue(scalars[index]), digit < radix {
                if value <= 0x10FFFF { value = value * radix + digit }
                index += 1
            }
            guard index > digitsStart else { return nil }
            if index < scalars.count, scalars[index] == ";" { index += 1 }
            return (character(forCodePoint: value), index - start)
        }

        var name = String.UnicodeScalarView()
        while index < scalars.count, index - start <= 32, isASCIIAlphanumeric(scalars[index]) {
            name.append(scalars[index])
            index += 1
        }
        guard index < scalars.count, scalars[index] == ";",
            let replacement = namedReferences[String(name)]
        else { return nil }
        return (replacement, index + 1 - start)
    }

    private static func character(forCodePoint value: UInt32) -> String {
        switch value {
            case 0, 0xD800...0xDFFF, 0x110000...:
                return "\u{FFFD}"
            case 0x80...0x9F:
                return String(bytes: [UInt8(value)], encoding: .windowsCP1252) ?? "\u{FFFD}"
            default:
                return Unicode.Scalar(value).map { String(Character($0)) } ?? "\u{FFFD}"
        }
    }

    private static func hexDigitValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
            case 0x30...0x39: return scalar.value - 0x30
            case 0x41...0x46: return scalar.value - 0x41 + 10
            case 0x61...0x66: return scalar.value - 0x61 + 10
            default: return nil
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            default: return false
        }
    }

    /// The named references page titles and descriptions actually use. The
    /// full HTML table has 2,231 entries; unknown names stay as written.
    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "shy": "\u{00AD}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·",
        "prime": "′", "Prime": "″",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±", "times": "×",
        "divide": "÷", "micro": "µ", "para": "¶", "sect": "§", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "cent": "¢", "pound": "£", "yen": "¥", "euro": "€", "curren": "¤",
        "iexcl": "¡", "iquest": "¿", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ",
        "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å",
        "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Iacute": "Í", "Ntilde": "Ñ", "Oacute": "Ó", "Ouml": "Ö", "Oslash": "Ø",
        "Uacute": "Ú", "Uuml": "Ü",
    ]
}
