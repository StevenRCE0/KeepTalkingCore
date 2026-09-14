#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation
import Testing

@testable import KeepTalkingSDK

struct LoginShellEnvironmentTests {
    @Test("parse keeps only the NUL-separated entries between the markers")
    func parsesMarkedDump() {
        let marker = "__MARK__"
        var data = Data("profile chatter\nmotd\n".utf8)
        data.append(Data(marker.utf8))
        for entry in [
            "PATH=/opt/homebrew/bin:/usr/bin", "MULTI=line one\nline two", "SHLVL=2", "PWD=/tmp", "_=/usr/bin/env",
            "NOEQUALS", "=empty", "KEEPTALKING_RESOLVING_ENVIRONMENT=1", "EMPTY=",
        ] {
            data.append(Data(entry.utf8))
            data.append(0)
        }
        data.append(Data(marker.utf8))
        data.append(Data("trailing noise".utf8))

        let parsed = KeepTalkingLoginShellEnvironment.parse(data, marker: marker)
        #expect(
            parsed == [
                "PATH": "/opt/homebrew/bin:/usr/bin",
                "MULTI": "line one\nline two",
                "EMPTY": "",
            ])
    }

    @Test("parse yields nothing without two markers")
    func rejectsIncompleteDump() {
        let marker = "__MARK__"
        #expect(KeepTalkingLoginShellEnvironment.parse(Data("no markers".utf8), marker: marker).isEmpty)
        #expect(KeepTalkingLoginShellEnvironment.parse(Data("__MARK__PATH=/x\0".utf8), marker: marker).isEmpty)
        #expect(KeepTalkingLoginShellEnvironment.parse(Data("__MARK____MARK__".utf8), marker: marker).isEmpty)
    }

    @Test("a login shell is found and placeholders are skipped")
    func findsLoginShell() throws {
        let shell = try #require(KeepTalkingLoginShellEnvironment.loginShellPath(environment: [:]))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
        let fromNologin = KeepTalkingLoginShellEnvironment.loginShellPath(
            environment: ["SHELL": "/usr/sbin/nologin"])
        #expect(fromNologin != "/usr/sbin/nologin")
    }

    #if os(macOS)
    @Test("resolving the real login shell yields a PATH and drops shell-run variables")
    func resolvesRealShell() {
        let resolved = KeepTalkingLoginShellEnvironment.resolveNow()
        #expect(!(resolved["PATH"] ?? "").isEmpty)
        #expect(resolved["SHLVL"] == nil)
        #expect(resolved["PWD"] == nil)
        #expect(resolved[KeepTalkingLoginShellEnvironment.resolvingMarkerVariable] == nil)

        // The merged environment used for spawns carries the shell's PATH.
        let merged = DefaultProcessExecutionSupport.mergedEnvironment(
            for: ["npx"], environment: ["KT_TEST": "1"])
        #expect(merged["KT_TEST"] == "1")
        for component in (resolved["PATH"] ?? "").split(separator: ":") {
            #expect((merged["PATH"] ?? "").split(separator: ":").contains(component))
        }
    }
    #endif
}
#endif
