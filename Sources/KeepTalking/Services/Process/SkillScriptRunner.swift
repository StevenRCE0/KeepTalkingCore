#if os(macOS)
import Darwin
import Foundation

public enum SkillScriptRunner {
    public static func makeCommand(
        scriptURL: URL,
        arguments: [String]
    ) -> [String] {
        let path = scriptURL.path
        switch scriptURL.pathExtension.lowercased() {
            case "py":
                return ["/usr/bin/env", "python3", path] + arguments
            case "sh", "command":
                return ["/bin/zsh", path] + arguments
            default:
                if FileManager.default.isExecutableFile(atPath: path) {
                    return [path] + arguments
                }
                return ["/bin/zsh", path] + arguments
        }
    }

    /// Runs a skill script *patiently*: rather than killing the process at a
    /// fixed `graceSeconds`, it waits the grace period quietly and then waits
    /// indefinitely for the process to finish, polling every `pollSeconds`. The
    /// child's stdout/stderr are redirected to temp files (inherited fds, so the
    /// seatbelt sandbox doesn't block them) instead of in-memory pipes — this
    /// avoids the pipe-buffer deadlock and unbounded memory that an unbounded
    /// wait would otherwise risk, and lets the poll hook tail incremental output
    /// via `onProgress`. Cancelling the surrounding task (e.g. aborting the agent
    /// run) terminates the process and unwinds as `CancellationError`.
    public static func run(
        command: [String],
        currentDirectory: URL,
        environment: [String: String] = [:],
        actionID: UUID,
        graceSeconds: TimeInterval = 10,
        pollSeconds: TimeInterval = 5,
        sandboxPolicy: KTSandboxPolicy? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SkillScriptExecutionResult {
        guard let executable = command.first else {
            return SkillScriptExecutionResult(
                command: [],
                exitCode: 2,
                stdout: "",
                stderr: "Missing command executable."
            )
        }

        let processBox = SkillScriptProcessBox()
        return try await withTaskCancellationHandler {
            try await run(
                process: processBox.process,
                executable: executable,
                command: command,
                currentDirectory: currentDirectory,
                environment: environment,
                actionID: actionID,
                graceSeconds: graceSeconds,
                pollSeconds: pollSeconds,
                sandboxPolicy: sandboxPolicy,
                onProgress: onProgress
            )
        } onCancel: {
            // Runs synchronously on whoever cancels (often the MainActor), so it
            // must not block: send SIGTERM now and escalate to SIGKILL
            // out-of-band if the process ignores it.
            terminateProcessIfRunning(processBox.process)
            scheduleForceKill(processBox)
        }
    }

    private final class SkillScriptProcessBox: @unchecked Sendable {
        let process = Process()
    }

    /// Reads newly-appended bytes from a redirected output temp file across
    /// polls, tracking a running offset so each call returns only the latest
    /// chunk.
    private final class OutputTailReader: @unchecked Sendable {
        private let url: URL
        private var offset: UInt64 = 0
        init(url: URL) { self.url = url }

        func readNewChunk() -> String {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return ""
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                let data = try handle.readToEnd() ?? Data()
                offset += UInt64(data.count)
                return DefaultProcessExecutionSupport.decode(data: data)
            } catch {
                return ""
            }
        }
    }

    private static func run(
        process: Process,
        executable: String,
        command: [String],
        currentDirectory: URL,
        environment: [String: String] = [:],
        actionID: UUID,
        graceSeconds: TimeInterval,
        pollSeconds: TimeInterval,
        sandboxPolicy: KTSandboxPolicy? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SkillScriptExecutionResult {
        let fileManager = FileManager.default
        let tempDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        let token = UUID().uuidString.lowercased()
        let actionLabel = actionID.uuidString.lowercased()
        let stdoutURL = tempDirectory.appendingPathComponent(
            "kt-skill-\(actionLabel)-\(token)-out.log"
        )
        let stderrURL = tempDirectory.appendingPathComponent(
            "kt-skill-\(actionLabel)-\(token)-err.log"
        )
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        func cleanupTempFiles() {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutWrite: FileHandle
        let stderrWrite: FileHandle
        do {
            stdoutWrite = try FileHandle(forWritingTo: stdoutURL)
            stderrWrite = try FileHandle(forWritingTo: stderrURL)
        } catch {
            cleanupTempFiles()
            throw error
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = currentDirectory
        // Redirect to temp files via inherited fds rather than pipes: an
        // unbounded patient wait can't deadlock on a full 64KB pipe buffer, and
        // the poll hook can tail the files for incremental progress.
        process.standardOutput = stdoutWrite
        process.standardError = stderrWrite
        process.environment =
            DefaultProcessExecutionSupport
            .mergedEnvironment(
                for: command,
                environment: environment
            )

        if let sandboxPolicy {
            let sandbox = SeatbeltSandbox()
            do {
                try sandbox.apply(policy: sandboxPolicy, to: process)
            } catch {
                try? stdoutWrite.close()
                try? stderrWrite.close()
                cleanupTempFiles()
                throw error
            }
        }

        let stdoutTail = OutputTailReader(url: stdoutURL)
        let stderrTail = OutputTailReader(url: stderrURL)

        let exitCode: Int32
        do {
            exitCode = try await patientWait(
                label: "skill script action=\(actionLabel)",
                graceSeconds: graceSeconds,
                pollSeconds: pollSeconds,
                // The subprocess *is* what we wait on; its exit delivers the
                // result via the termination handler, so it's always "alive"
                // until then. Patience ends only on completion or cancellation.
                isAlive: { true },
                onDeath: { SkillManagerError.toolCallTimedOut(actionID, graceSeconds) },
                onPoll: { _ in
                    guard let onProgress else { return }
                    let out = stdoutTail.readNewChunk()
                    if !out.isEmpty { onProgress(out) }
                    let err = stderrTail.readNewChunk()
                    if !err.isEmpty { onProgress(err) }
                }
            ) {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try process.run()
                        // The child holds its own dup'd fds — release ours so we
                        // don't leak descriptors across a long run.
                        try? stdoutWrite.close()
                        try? stderrWrite.close()
                    } catch {
                        try? stdoutWrite.close()
                        try? stderrWrite.close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            terminateProcessIfRunning(process)
            try? stdoutWrite.close()
            try? stderrWrite.close()
            cleanupTempFiles()
            throw error
        }

        // A cancelled run had its process terminated by the cancellation
        // handler; surface that as a clean cancellation rather than a result.
        if Task.isCancelled {
            cleanupTempFiles()
            throw CancellationError()
        }

        let stdout = readDecodedOutput(at: stdoutURL)
        let stderr = readDecodedOutput(at: stderrURL)
        cleanupTempFiles()

        return SkillScriptExecutionResult(
            command: command,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func readDecodedOutput(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return DefaultProcessExecutionSupport.decode(data: data)
    }

    /// Sends SIGTERM without blocking the caller. Reaping happens via the run's
    /// termination handler, so we deliberately don't `waitUntilExit()` here —
    /// this can run on the MainActor during cancellation.
    private static func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// Escalates to SIGKILL out-of-band if the process hasn't exited shortly
    /// after SIGTERM. Without this, a script that ignores SIGTERM would leave
    /// the run's termination continuation suspended forever, wedging the
    /// cancellation instead of completing it.
    private static func scheduleForceKill(_ box: SkillScriptProcessBox) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let process = box.process
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }
}
#endif
