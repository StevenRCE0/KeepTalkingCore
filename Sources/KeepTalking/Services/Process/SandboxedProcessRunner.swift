#if os(macOS)
import Darwin
import Foundation

/// Sandboxed process + shell runner — the SDK's execution primitive. Runs an argv
/// (`run(command:)`) or a real shell command line (`runShell`) under a compiled
/// sandbox policy, with patient-wait and SIGTERM→SIGKILL cancellation. Formerly
/// `SkillScriptRunner`; generalised as the agent moved from per-declared-script
/// tools to a sandboxed shell.
public enum SandboxedProcessRunner {
    /// Runs a command *patiently*: rather than killing the process at a
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
        // argv is NOT a shell, so a manifest resource handle the agent passed as an
        // argument (e.g. "$KT_OTB_…", copied from the resources prompt) would
        // otherwise reach the script as a literal string. Expand `$NAME`/`${NAME}`
        // references against the INJECTED environment (manifest keys, SKILL_DIR,
        // bundle params — not the inherited parent env) so the script receives the
        // real staged path, exactly as a shell would have expanded it.
        let command = expandInjectedReferences(in: command, using: environment)
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

    /// Runs an arbitrary command LINE through a real shell (`/bin/zsh -c`) under
    /// the same sandbox + patient-wait + cancellation machinery as `run(command:)`.
    /// This is the agent's general-purpose execution primitive: because a genuine
    /// shell interprets the string, `$KT_<KIND>_<H8>` resource handles, quoting,
    /// pipes, redirections, and globs all expand natively — there is NO argv
    /// pre-expansion (`expandInjectedReferences`) and no control-token stripping,
    /// the very workarounds the no-shell script path needed. The KeepTalking
    /// resource env vars are injected, so the shell resolves handles to real paths.
    /// The shell `runShell` invokes. macOS ships zsh as the default login shell and
    /// it's guaranteed on our deployment floor; Linux (the KeepTalkingDemon port)
    /// may not have zsh, so prefer bash there. A runtime existence check keeps it
    /// robust on either platform, falling back to `/bin/sh` as a last resort.
    public static func resolveShellExecutable() -> String {
        #if os(macOS)
        let candidates = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        #else
        let candidates = ["/bin/bash", "/usr/bin/bash", "/bin/sh"]
        #endif
        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return candidates.last ?? "/bin/sh"
    }

    public static func runShell(
        command: String,
        currentDirectory: URL,
        environment: [String: String] = [:],
        actionID: UUID,
        graceSeconds: TimeInterval = 10,
        pollSeconds: TimeInterval = 5,
        sandboxPolicy: KTSandboxPolicy? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SkillScriptExecutionResult {
        let shell = resolveShellExecutable()
        let argv = [shell, "-c", command]
        let processBox = SkillScriptProcessBox()
        return try await withTaskCancellationHandler {
            try await run(
                process: processBox.process,
                executable: shell,
                command: argv,
                currentDirectory: currentDirectory,
                environment: environment,
                actionID: actionID,
                graceSeconds: graceSeconds,
                pollSeconds: pollSeconds,
                sandboxPolicy: sandboxPolicy,
                onProgress: onProgress
            )
        } onCancel: {
            terminateProcessIfRunning(processBox.process)
            scheduleForceKill(processBox)
        }
    }

    /// Expands `$NAME` / `${NAME}` references in each command token to an INJECTED
    /// environment value. Scoped to the run-specific `environment` dict (manifest
    /// resource keys, SKILL_DIR, bundle params) — NOT the inherited parent env — so
    /// only KeepTalking-provisioned handles resolve, predictably. Unknown tokens are
    /// left untouched.
    static func expandInjectedReferences(
        in command: [String], using environment: [String: String]
    ) -> [String] {
        guard !environment.isEmpty else { return command }
        return command.map { expandInjectedReferences(in: $0, using: environment) }
    }

    static func expandInjectedReferences(
        in string: String, using environment: [String: String]
    ) -> String {
        guard string.contains("$") else { return string }
        func isIdentifier(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }
        let characters = Array(string)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                result.append(characters[index])
                index += 1
                continue
            }
            var cursor = index + 1
            let braced = cursor < characters.count && characters[cursor] == "{"
            if braced { cursor += 1 }
            var name = ""
            while cursor < characters.count && isIdentifier(characters[cursor]) {
                name.append(characters[cursor])
                cursor += 1
            }
            if braced {
                guard cursor < characters.count, characters[cursor] == "}" else {
                    result.append(characters[index])
                    index += 1
                    continue
                }
                cursor += 1
            }
            if !name.isEmpty, let value = environment[name] {
                result.append(value)
                index = cursor
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
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
