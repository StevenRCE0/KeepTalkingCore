import Foundation
import Testing

@testable import KeepTalkingSDK

struct SkillScriptRunnerTests {
    @Test("script runner drains large stdout without hanging")
    func drainsLargeStdout() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let scriptURL = fixture.appendingPathComponent("large-output.sh")
        try """
            #!/bin/zsh
            for i in {1..20000}; do
              print "line-$i"
            done
            """
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = try await SkillScriptRunner.run(
            command: SkillScriptRunner.makeCommand(
                scriptURL: scriptURL,
                arguments: []
            ),
            currentDirectory: fixture,
            actionID: UUID(),
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("line-1"))
        #expect(result.stdout.contains("line-20000"))
    }

    @Test("script runner terminates timed out processes")
    func terminatesTimedOutProcess() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let markerURL = fixture.appendingPathComponent("terminated.txt")
        let scriptURL = fixture.appendingPathComponent("timeout.sh")
        try """
            #!/bin/zsh
            trap 'print "terminated" > "$1"; exit 0' TERM
            while true; do
              sleep 1
            done
            """
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        await #expect(throws: SkillManagerError.self) {
            _ = try await SkillScriptRunner.run(
                command: SkillScriptRunner.makeCommand(
                    scriptURL: scriptURL,
                    arguments: [markerURL.path]
                ),
                currentDirectory: fixture,
                actionID: UUID(),
                timeoutSeconds: 1
            )
        }

        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
