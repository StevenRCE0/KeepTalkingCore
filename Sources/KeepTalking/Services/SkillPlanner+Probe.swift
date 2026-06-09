#if os(macOS)
import Foundation

/// Environment-probing for the skill planner. Lets the planner *verify* the
/// runtime — is a tool on PATH, does a path exist, does a candidate command
/// actually run — instead of declaring steps on faith. Probes run in a login
/// shell (so the user's real PATH is in effect) with a hard timeout, and report
/// whether what they found is reachable from the skill's runtime sandbox.
extension KeepTalkingSkillPlanner {

    /// The outcome of a single probe: a short line for the activity card and a
    /// fuller block fed back to the model as the tool result.
    struct ProbeOutcome: Sendable {
        let summary: String
        let toolResult: String
    }

    // MARK: - Probe operations

    /// Looks up `name` via `command -v` + `<name> --version` and reports the
    /// path, version, and whether it is runnable inside the skill sandbox.
    func probeCommand(_ name: String, grantedRoots: [String]) async -> ProbeOutcome {
        guard !name.isEmpty, isShellSafeToken(name) else {
            return ProbeOutcome(
                summary: "invalid name",
                toolResult: "error: '\(name)' is not a valid bare command name."
            )
        }

        // Print the resolved path, then a sentinel carrying command -v's exit
        // code, then up to three lines of --version output.
        let snippet =
            "command -v \(name) 2>/dev/null; printf '@@KT_RC=%s\\n' \"$?\"; "
            + "\(name) --version 2>&1 | head -n 3"
        let result = await runBounded(
            ["/bin/zsh", "-lc", snippet],
            cwd: probeWorkingDirectory(),
            timeout: 8
        )

        let lines = result.stdout.components(separatedBy: "\n")
        var path = ""
        var found = false
        var version = ""
        if let marker = lines.firstIndex(where: { $0.hasPrefix("@@KT_RC=") }) {
            path = lines[0..<marker].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rc = lines[marker].replacingOccurrences(of: "@@KT_RC=", with: "")
            found = rc == "0" && !path.isEmpty
            version = lines[(marker + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            found = !path.isEmpty
        }

        guard found else {
            return ProbeOutcome(
                summary: "\(name): not found on PATH",
                toolResult: """
                    command: \(name)
                    found: false
                    advice: Not on PATH in a login shell. Ask the user where it is \
                    (kt_require_file), suggest an install command, or pick another tool.
                    """
            )
        }

        let runnable = isRunnableInSkillSandbox(path: path, grantedRoots: grantedRoots)
        let versionLine = version.isEmpty ? path : version
        let summary =
            runnable
            ? "\(versionLine) — runnable"
            : "\(name) at \(path) — NOT runnable in sandbox"
        let advice =
            runnable
            ? "Runnable as-is."
            : "Found, but \(path) is outside the skill sandbox's exec allowlist "
                + "(/opt/homebrew/bin, /usr/local/bin, standard interpreters). Ask the "
                + "user to grant it with kt_require_file so the skill can execute it."
        return ProbeOutcome(
            summary: summary,
            toolResult: """
                command: \(name)
                found: true
                path: \(path)
                version: \(version.isEmpty ? "<unknown>" : version)
                runnable_in_skill_sandbox: \(runnable)
                advice: \(advice)
                """
        )
    }

    /// Stats an absolute path so the planner can confirm a root/entry it was
    /// pointed at really exists and has the right shape.
    func checkPath(_ path: String) -> ProbeOutcome {
        guard path.hasPrefix("/") else {
            return ProbeOutcome(
                summary: "needs absolute path",
                toolResult: "error: path must be absolute (got '\(path)')."
            )
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        guard exists else {
            return ProbeOutcome(
                summary: "does not exist",
                toolResult: "path: \(path)\nexists: false"
            )
        }
        let readable = fm.isReadableFile(atPath: path)
        let executable = fm.isExecutableFile(atPath: path)
        let kind = isDir.boolValue ? "directory" : "file"
        let traits =
            [readable ? "readable" : nil, executable ? "executable" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return ProbeOutcome(
            summary: "\(kind)\(traits.isEmpty ? "" : ", \(traits)")",
            toolResult: """
                path: \(path)
                exists: true
                is_directory: \(isDir.boolValue)
                readable: \(readable)
                executable: \(executable)
                """
        )
    }

    /// Dry-runs a candidate command (login shell, short timeout) so the planner
    /// can confirm an invocation works before declaring it. Unsandboxed — the
    /// tool description constrains it to safe read-only smoke checks.
    func tryRun(command: String, cwd: String?) async -> ProbeOutcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProbeOutcome(summary: "empty command", toolResult: "error: empty command.")
        }
        let workdir =
            (cwd?.hasPrefix("/") == true)
            ? URL(fileURLWithPath: cwd!) : probeWorkingDirectory()
        let result = await runBounded(
            ["/bin/zsh", "-lc", trimmed],
            cwd: workdir,
            timeout: 12
        )
        let out = String(result.stdout.prefix(4_000))
        let err = String(result.stderr.prefix(2_000))
        return ProbeOutcome(
            summary: "exit \(result.exitCode)",
            toolResult: """
                command: \(trimmed)
                exit_code: \(result.exitCode)
                stdout:
                \(out.isEmpty ? "<empty>" : out)
                stderr:
                \(err.isEmpty ? "<empty>" : err)
                """
        )
    }

    // MARK: - Runtime

    /// Runs `command` with a hard timeout by racing the (otherwise patient)
    /// `SkillScriptRunner` against a sleep and cancelling it — cancellation
    /// terminates the subprocess. Returns a synthetic 124 result on timeout.
    private func runBounded(
        _ command: [String],
        cwd: URL,
        timeout: TimeInterval
    ) async -> SkillScriptExecutionResult {
        // Probes are labelled with a throwaway id; they don't belong to the
        // skill action being planned.
        let actionID = UUID()
        do {
            return try await withThrowingTaskGroup(
                of: SkillScriptExecutionResult?.self
            ) { group in
                group.addTask {
                    try await SkillScriptRunner.run(
                        command: command,
                        currentDirectory: cwd,
                        environment: [:],
                        actionID: actionID,
                        graceSeconds: timeout + 1,
                        pollSeconds: timeout + 1,
                        sandboxPolicy: nil
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil  // timeout sentinel
                }
                defer { group.cancelAll() }
                let first = try await group.next() ?? nil
                return first
                    ?? SkillScriptExecutionResult(
                        command: command,
                        exitCode: 124,
                        stdout: "",
                        stderr: "probe timed out after \(Int(timeout))s"
                    )
            }
        } catch is CancellationError {
            return SkillScriptExecutionResult(
                command: command, exitCode: 124, stdout: "", stderr: "probe cancelled")
        } catch {
            return SkillScriptExecutionResult(
                command: command, exitCode: -1, stdout: "",
                stderr: "probe failed: \(error.localizedDescription)")
        }
    }

    private func probeWorkingDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Whether `path` is reachable from the skill runtime's seatbelt exec
    /// allowlist (mirrors `SeatbeltSandbox`) or sits under a path the user has
    /// already granted this session.
    private func isRunnableInSkillSandbox(path: String, grantedRoots: [String]) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let interpreterLiterals: Set<String> = [
            "/usr/bin/env", "/bin/zsh", "/bin/sh", "/bin/bash", "/usr/bin/python3",
        ]
        if interpreterLiterals.contains(std) { return true }
        for prefix in ["/opt/homebrew/bin/", "/usr/local/bin/"] where std.hasPrefix(prefix) {
            return true
        }
        for root in grantedRoots {
            let r = URL(fileURLWithPath: root).standardizedFileURL.path
            if std == r || std.hasPrefix(r + "/") { return true }
        }
        return false
    }

    /// Conservative check that a bare command name is safe to splice into a
    /// shell `command -v` / `--version` probe.
    private func isShellSafeToken(_ token: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-+"
        )
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
#endif
