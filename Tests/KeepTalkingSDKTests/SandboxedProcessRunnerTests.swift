import Foundation
import Testing

@testable import KeepTalkingSDK

struct SandboxedProcessRunnerTests {
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

        let result = try await SandboxedProcessRunner.run(
            command: ["/bin/zsh", scriptURL.path],
            currentDirectory: fixture,
            actionID: UUID(),
            graceSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("line-1"))
        #expect(result.stdout.contains("line-20000"))
    }

    @Test("script runner terminates a cancelled process")
    func terminatesCancelledProcess() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let markerURL = fixture.appendingPathComponent("terminated.txt")
        let startedURL = fixture.appendingPathComponent("started.txt")
        let scriptURL = fixture.appendingPathComponent("longrunning.sh")
        try """
        #!/bin/zsh
        trap 'print "terminated" > "$1"; exit 0' TERM
        print "started" > "$2"
        while true; do
          sleep 1
        done
        """
        .write(to: scriptURL, atomically: true, encoding: .utf8)

        // The run now waits patiently (no hard timeout) — only an explicit
        // cancellation stops it. Cancelling the surrounding task must terminate
        // the process and surface a CancellationError.
        let task = Task {
            try await SandboxedProcessRunner.run(
                command: ["/bin/zsh", scriptURL.path, markerURL.path, startedURL.path],
                currentDirectory: fixture,
                actionID: UUID(),
                graceSeconds: 1
            )
        }

        // Abort only once the script is actually running: a cancellation that
        // lands before launch (the first spawn in a process also resolves the
        // login-shell environment) is honoured before the process exists and
        // would never reach the trap.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: startedURL.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: startedURL.path))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
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
