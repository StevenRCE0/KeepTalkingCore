import Foundation
import Testing

@testable import KeepTalkingSDK

struct ShellWordsTests {
    @Test("plain words split on any run of whitespace, newlines included")
    func splitsOnWhitespace() throws {
        #expect(try ShellWords.split("npx  -y\t@scope/server\n/tmp") == ["npx", "-y", "@scope/server", "/tmp"])
        #expect(try ShellWords.split("   ") == [])
        #expect(try ShellWords.split("") == [])
    }

    @Test("single quotes are literal, double quotes honour the POSIX escapes")
    func handlesQuotes() throws {
        #expect(try ShellWords.split("a '/Users/me/My Docs' b") == ["a", "/Users/me/My Docs", "b"])
        #expect(try ShellWords.split(#"echo 'it'\''s'"#) == ["echo", "it's"])
        #expect(try ShellWords.split(#"x "say \"hi\" \$HOME \\ \n""#) == ["x", #"say "hi" $HOME \ \n"#])
        #expect(try ShellWords.split(#"pre"fix"ed"#) == ["prefixed"])
        #expect(try ShellWords.split(#"a "" b"#) == ["a", "", "b"])
    }

    @Test("backslashes escape outside quotes and continue lines")
    func handlesBackslashes() throws {
        #expect(try ShellWords.split(#"/path/with\ space"#) == ["/path/with space"])
        #expect(try ShellWords.split("npx -y \\\n  @scope/server") == ["npx", "-y", "@scope/server"])
        #expect(try ShellWords.split("\"multi \\\nline\"") == ["multi line"])
    }

    @Test("malformed input is reported, not silently truncated")
    func reportsErrors() {
        #expect(throws: ShellWords.Error.unterminatedQuote("'")) {
            try ShellWords.split("npx 'oops")
        }
        #expect(throws: ShellWords.Error.unterminatedQuote("\"")) {
            try ShellWords.split("npx \"oops")
        }
        #expect(throws: ShellWords.Error.trailingBackslash) {
            try ShellWords.split("npx \\")
        }
    }

    @Test("join quotes only what needs quoting and round-trips through split")
    func joinRoundTrips() throws {
        let words = ["npx", "-y", "@scope/server", "/Users/me/My Docs", "it's", "", "a\"b", "$HOME", "x=y"]
        let line = ShellWords.join(words)
        #expect(line == #"npx -y @scope/server '/Users/me/My Docs' 'it'\''s' '' 'a"b' '$HOME' x=y"#)
        #expect(try ShellWords.split(line) == words)
    }

    @Test("leading NAME=value words become environment assignments")
    func parsesCommandLineAssignments() throws {
        let parsed = try ShellWords.CommandLine.parse("FOO=1 BAR='a b' npx -y pkg --flag=x=y")
        #expect(parsed.environment == ["FOO": "1", "BAR": "a b"])
        #expect(parsed.argv == ["npx", "-y", "pkg", "--flag=x=y"])

        // Not identifiers: a leading assignment needs a POSIX name.
        #expect(try ShellWords.CommandLine.parse("=x cmd").argv == ["=x", "cmd"])
        #expect(try ShellWords.CommandLine.parse("1A=x cmd").argv == ["1A=x", "cmd"])
        #expect(try ShellWords.CommandLine.parse("a-b=x cmd").argv == ["a-b=x", "cmd"])
        #expect(try ShellWords.CommandLine.parse("").argv == [])

        let rendered = ShellWords.CommandLine(environment: ["B": "2 3", "A": "1"], argv: ["run", "it now"]).rendered
        #expect(rendered == "A=1 B='2 3' run 'it now'")
        #expect(
            try ShellWords.CommandLine.parse(rendered)
                == ShellWords.CommandLine(environment: ["A": "1", "B": "2 3"], argv: ["run", "it now"]))
    }

    @Test("environment lines are KEY=VALUE per line with verbatim values")
    func parsesEnvironmentLines() {
        let parsed = ShellWords.parseEnvironmentLines(
            "API_KEY=sk-abc\n  export TOKEN = \"quoted value\" \n\nnovalue\n=nokey\nEMPTY=\nURL=http://x?a=b"
        )
        #expect(
            parsed == [
                "API_KEY": "sk-abc",
                "TOKEN": " \"quoted value\"",
                "EMPTY": "",
                "URL": "http://x?a=b",
            ])
        #expect(ShellWords.renderEnvironmentLines(["B": "2", "A": "1"]) == "A=1\nB=2")
    }
}
