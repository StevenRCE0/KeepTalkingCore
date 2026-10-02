import Foundation

/// POSIX shell word splitting and quoting for command lines typed into a single
/// field — the rules of `sh` (what Python's `shlex.split(posix=True)` and Rust's
/// `shell-words` implement), without running a shell:
///
/// - unquoted whitespace (space, tab, newline) separates words, so a command
///   pasted across several lines still parses;
/// - `'…'` is literal; `"…"` honours `\"`, `\\`, `\$`, a backslash-escaped backtick, and a
///   backslash-newline continuation; an unquoted `\` escapes the next character;
/// - nothing is expanded — no globs, variables, comments, pipes or redirections.
///   The result is an argv, not a script.
public enum ShellWords {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        /// A `'` or `"` was opened and never closed.
        case unterminatedQuote(Character)
        /// The line ends with a lone `\`.
        case trailingBackslash

        public var errorDescription: String? {
            switch self {
                case .unterminatedQuote(let quote):
                    return "Unterminated \(quote) quote in command line."
                case .trailingBackslash:
                    return "Command line ends with a backslash."
            }
        }
    }

    /// Splits `line` into words.
    public static func split(_ line: String) throws -> [String] {
        let characters = Array(line)
        var words: [String] = []
        var current = ""
        // Distinguishes an empty quoted word (`""`) from no word at all.
        var hasWord = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
                case _ where character.isWhitespace:
                    if hasWord {
                        words.append(current)
                        current = ""
                        hasWord = false
                    }
                    index += 1

                case "'":
                    hasWord = true
                    index += 1
                    var closed = false
                    while index < characters.count {
                        if characters[index] == "'" {
                            closed = true
                            index += 1
                            break
                        }
                        current.append(characters[index])
                        index += 1
                    }
                    guard closed else { throw Error.unterminatedQuote("'") }

                case "\"":
                    hasWord = true
                    index += 1
                    var closed = false
                    while index < characters.count {
                        let inner = characters[index]
                        if inner == "\"" {
                            closed = true
                            index += 1
                            break
                        }
                        if inner == "\\", index + 1 < characters.count {
                            let next = characters[index + 1]
                            if next == "\"" || next == "\\" || next == "$" || next == "`" {
                                current.append(next)
                                index += 2
                                continue
                            }
                            if next.isNewline {
                                index += 2
                                continue
                            }
                        }
                        current.append(inner)
                        index += 1
                    }
                    guard closed else { throw Error.unterminatedQuote("\"") }

                case "\\":
                    guard index + 1 < characters.count else { throw Error.trailingBackslash }
                    let next = characters[index + 1]
                    if !next.isNewline {
                        current.append(next)
                        hasWord = true
                    }
                    index += 2

                default:
                    current.append(character)
                    hasWord = true
                    index += 1
            }
        }

        if hasWord {
            words.append(current)
        }
        return words
    }

    /// Renders `words` as one line that ``split(_:)`` parses back to the same
    /// words — each quoted only when it has to be.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// Quotes one word for a POSIX shell: unchanged when it only contains safe
    /// characters, otherwise wrapped in single quotes (with `'` as `'\''`).
    public static func quote(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let isSafe = word.unicodeScalars.allSatisfy { scalar in
            switch scalar {
                case "a"..."z", "A"..."Z", "0"..."9",
                    "_", "-", ".", "/", ":", "@", "%", "+", "=", ",":
                    return true
                default:
                    return false
            }
        }
        if isSafe {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A command line read the way a shell reads `FOO=1 BAR='a b' npx …`:
    /// leading `NAME=value` words are environment assignments and the rest is
    /// the argv, program first.
    public struct CommandLine: Equatable, Sendable {
        public var environment: [String: String]
        public var argv: [String]

        public init(environment: [String: String] = [:], argv: [String] = []) {
            self.environment = environment
            self.argv = argv
        }

        public static func parse(_ line: String) throws -> CommandLine {
            var environment: [String: String] = [:]
            var words = try ShellWords.split(line)[...]
            while let first = words.first,
                let assignment = ShellWords.environmentAssignment(first)
            {
                environment[assignment.name] = assignment.value
                words = words.dropFirst()
            }
            return CommandLine(environment: environment, argv: Array(words))
        }

        /// The line ``parse(_:)`` reads back to this value.
        public var rendered: String {
            let assignments = environment.keys.sorted().map {
                "\($0)=\(ShellWords.quote(environment[$0] ?? ""))"
            }
            return (assignments + argv.map(ShellWords.quote)).joined(separator: " ")
        }
    }

    /// Reads an environment field: one `KEY=VALUE` per line, value verbatim
    /// (no quote handling, like a `.env` file). An optional `export ` prefix is
    /// tolerated so lines pasted from a profile work. Lines without a key are
    /// skipped.
    public static func parseEnvironmentLines(_ text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("export ") {
                line = line.dropFirst("export ".count).drop(while: \.isWhitespace)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            environment[key] = String(line[line.index(after: separator)...])
        }
        return environment
    }

    /// Renders an environment as `KEY=VALUE` lines, keys sorted, for editing.
    public static func renderEnvironmentLines(_ environment: [String: String]) -> String {
        environment.keys.sorted()
            .map { "\($0)=\(environment[$0] ?? "")" }
            .joined(separator: "\n")
    }

    /// `NAME=value` where NAME is a POSIX identifier (`[A-Za-z_][A-Za-z0-9_]*`).
    static func environmentAssignment(_ word: String) -> (name: String, value: String)? {
        guard let separator = word.firstIndex(of: "="), separator != word.startIndex else {
            return nil
        }
        let name = word[..<separator]
        func isIdentifierCharacter(_ character: Character, leading: Bool) -> Bool {
            guard character.isASCII else { return false }
            if character == "_" || character.isLetter { return true }
            return !leading && character.isNumber
        }
        guard let first = name.first, isIdentifierCharacter(first, leading: true),
            name.dropFirst().allSatisfy({ isIdentifierCharacter($0, leading: false) })
        else {
            return nil
        }
        return (String(name), String(word[word.index(after: separator)...]))
    }
}
