import AIProxy
import Foundation
import MCP

/// Captures the structured output of every script the inner skill agent
/// runs so the outer chat can surface real `command/stdout/stderr` fields
/// instead of only the inner LLM's prose summary. Reference type so the
/// inner loop can append from inside `async` calls without `inout`.
final class SkillScriptTraceCollector: @unchecked Sendable {
    struct Entry {
        let toolName: String
        let result: String
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    func append(toolName: String, structuredResult: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(toolName: toolName, result: structuredResult))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Last script trace formatted as the canonical script result block
    /// (`command:\n…\nexit_code: N\nstdout:\n…\nstderr:\n…`). Returns
    /// nil when no script ran.
    func lastResultBlock() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last?.result
    }
}

extension SkillManager {
    func assistantMessage(
        from turn: AITurnResult
    ) -> AIMessage? {
        let text = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (text?.isEmpty == false)
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        if !hasText, toolCalls == nil {
            return nil
        }
        return AIMessage(
            role: .assistant,
            content: hasText ? .text(text!) : nil,
            toolCalls: toolCalls ?? []
        )
    }

    func executeSkillToolCalls(
        _ toolCalls: [AIToolCall],
        actionID: UUID,
        skillDirectory: URL?,
        manifestContext: SkillManifestContext,
        sandboxPolicy: KTSandboxPolicy? = nil,
        scriptTrace: SkillScriptTraceCollector? = nil,
        attachmentsDir: URL? = nil,
        manifest: KTResourceManifest? = nil,
        workspaceDirectory: URL? = nil
    ) async throws -> [AIMessage] {
        var messages: [AIMessage] = []
        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.name
            let arguments = normalizedSkillToolArguments(
                try decodeToolArguments(toolCall.argumentsJSON)
            )

            let parameters = skillBundlesByActionID[actionID]?.parameters ?? [:]
            let payload: String
            var paramDirRoots = parameters.values.filter { $0.hasPrefix("/") }
            // Staged context attachments are a readable root for the file tools too.
            if let attachmentsDir { paramDirRoots.append(attachmentsDir.path) }
            if functionName == Self.getFileToolName {
                var resolvedArgs = arguments
                // Resolve directory labels in the path (e.g. "input_dir/file.txt" → "/real/path/file.txt")
                if let path = arguments["path"]?.stringValue {
                    resolvedArgs["path"] = .string(resolveDirectoryLabel(path, parameters: parameters))
                }
                let raw = try executeGetFile(resolvedArgs, skillDirectory: skillDirectory, allowedRoots: paramDirRoots)
                payload = parameters.reduce(raw) { result, pair in
                    result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
                }
            } else if functionName == Self.listFilesToolName {
                let dirLabel = arguments["directory"]?.stringValue ?? ""
                payload = executeListFiles(
                    directory: dirLabel, parameters: parameters,
                    skillDirectory: skillDirectory, attachmentsDir: attachmentsDir)
            } else if functionName == Self.shellToolName {
                payload = try await executeShellCommand(
                    arguments,
                    actionID: actionID,
                    skillDirectory: skillDirectory,
                    parameters: parameters,
                    sandboxPolicy: sandboxPolicy,
                    attachmentsDir: attachmentsDir,
                    manifest: manifest,
                    workspaceDirectory: workspaceDirectory
                )
                // The skill loop reports its final answer back to the outer chat as
                // one tool result; appending the structured command/stdout/stderr
                // block here is what lets the Output card show real terminal output
                // instead of only the inner LLM's prose summary.
                scriptTrace?.append(toolName: functionName, structuredResult: payload)
            } else {
                payload =
                    "Tool '\(functionName)' is not available. Use \(Self.shellToolName) "
                    + "to run scripts and commands."
            }

            messages.append(
                .tool(payload, toolCallID: toolCallID)
            )
        }
        return messages
    }

    func decodeToolArguments(_ raw: String) throws -> [String: Value] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw SkillManagerError.invalidToolArguments(raw)
        }
        do {
            return try JSONDecoder().decode([String: Value].self, from: data)
        } catch {
            throw SkillManagerError.invalidToolArguments(raw)
        }
    }

    func executeGetFile(
        _ arguments: [String: Value],
        skillDirectory: URL?,
        allowedRoots: [String] = []
    ) throws -> String {
        let rawPath =
            arguments["path"]?.stringValue
            ?? arguments["file"]?.stringValue
            ?? ""
        let fileURL = try resolveSkillFileURL(
            rawPath,
            skillDirectory: skillDirectory,
            allowedRoots: allowedRoots
        )
        let data = try Data(contentsOf: fileURL)
        let decoded =
            String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let maxCharacters =
            arguments["max_characters"]?.intValue
            ?? Self.fileReadMaxCharacters
        return clipped(
            decoded,
            maxCharacters: max(512, maxCharacters)
        )
    }

    /// Runs a shell command line (the `kt_shell` tool) under the sandbox in the
    /// thread workspace, with the resource manifest injected so `$KT_*` handles
    /// resolve. The sole execution path now that per-declared-script tools are
    /// retired — a real shell, so no argv expansion or control-token stripping is
    /// needed; it scrubs paths and renders the canonical result block.
    func executeShellCommand(
        _ arguments: [String: Value],
        actionID: UUID,
        skillDirectory: URL?,
        parameters: [String: String] = [:],
        sandboxPolicy: KTSandboxPolicy? = nil,
        attachmentsDir: URL? = nil,
        manifest: KTResourceManifest? = nil,
        workspaceDirectory: URL? = nil
    ) async throws -> String {
        guard let scriptExecutor else {
            throw SkillManagerError.scriptExecutionUnavailableOnThisPlatform
        }
        let command =
            (arguments["command"]?.stringValue
            ?? arguments["cmd"]?.stringValue
            ?? arguments["script"]?.stringValue
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw SkillManagerError.invalidToolArguments("kt_shell requires a 'command' string")
        }
        let environment = skillExecutionEnvironment(
            parameters: parameters,
            skillDirectory: skillDirectory,
            manifest: manifest,
            attachmentsDir: attachmentsDir,
            workspaceDirectory: workspaceDirectory
        )
        let cwd = workspaceDirectory ?? skillDirectory ?? URL(fileURLWithPath: "/")

        #if os(macOS)
        let execution = try await scriptExecutor.runShellCommand(
            command: command,
            currentDirectory: cwd,
            environment: environment,
            actionID: actionID,
            timeoutSeconds: scriptTimeoutSeconds,
            sandboxPolicy: sandboxPolicy
        )
        #else
        _ = (environment, cwd, sandboxPolicy)
        let execution = SkillScriptExecutionResult(
            command: ["/bin/zsh", "-c", command], exitCode: 1, stdout: "",
            stderr: "Shell execution is unavailable on this platform.")
        #endif

        return sanitizedExecutionBlock(
            execution, manifest: manifest, skillDirectory: skillDirectory,
            workspaceDirectory: workspaceDirectory)
    }

    /// Builds the execution environment shared by `executeRunScript` and
    /// `executeShellCommand`: bundle parameters (minus the reserved `KT_` namespace,
    /// so an author parameter can never shadow a generated resource key), always
    /// `SKILL_DIR`, and the manifest's per-resource `KT_<KIND>_<H8>` keys plus the
    /// `KT_ATTACHMENTS` umbrella (falling back to the bare umbrella when no manifest
    /// was built). All values are canonical absolute paths.
    ///
    /// `KT_WORKSPACE` is injected whenever the run has a workspace, because the
    /// output scrubber rewrites workspace paths to `$KT_WORKSPACE` — a token the
    /// model reads back and reuses in later commands, where an unset variable
    /// would expand to "" and silently retarget the path.
    func skillExecutionEnvironment(
        parameters: [String: String],
        skillDirectory: URL?,
        manifest: KTResourceManifest?,
        attachmentsDir: URL?,
        workspaceDirectory: URL? = nil
    ) -> [String: String] {
        var environment = parameters.filter { !$0.key.hasPrefix("KT_") }
        if let skillDir = skillDirectory {
            environment["SKILL_DIR"] = skillDir.path
        }
        if let manifest {
            for (key, value) in manifest.environmentVariables() {
                environment[key] = value
            }
        } else if let attachmentsDir {
            environment["KT_ATTACHMENTS"] = attachmentsDir.path
        }
        if let workspaceDirectory {
            environment["KT_WORKSPACE"] = workspaceDirectory.standardizedFileURL.path
        }
        return environment
    }

    static let stdoutOverflowFilename = "_kt_stdout_overflow.txt"

    /// Scrubs a finished run's command line + stdout/stderr (path handles, clip to
    /// the output cap), logs the `[ACT]` trace, and renders the canonical
    /// `command/exit_code/stdout/stderr` block the outer chat parses into rows.
    ///
    /// When stdout exceeds `scriptOutputMaxCharacters` and a workspace directory
    /// is available, the full sanitized output is saved to
    /// `$KT_WORKSPACE/_kt_stdout_overflow.txt` so the inner agent (or a
    /// post-loop auto-populate step) can access the un-truncated content. The
    /// clipped block includes a note pointing to the file.
    func sanitizedExecutionBlock(
        _ execution: SkillScriptExecutionResult,
        manifest: KTResourceManifest?,
        skillDirectory: URL?,
        workspaceDirectory: URL? = nil
    ) -> String {
        let joinedCommand = sanitizeAgentVisiblePaths(
            execution.command.joined(separator: " "),
            manifest: manifest, skillDirectory: skillDirectory,
            workspaceDirectory: workspaceDirectory)
        let sanitizedStdout = sanitizeAgentVisiblePaths(
            execution.stdout, manifest: manifest, skillDirectory: skillDirectory,
            workspaceDirectory: workspaceDirectory)
        let stdoutOverflowed = sanitizedStdout.count > Self.scriptOutputMaxCharacters
        let stdout: String
        if stdoutOverflowed, let workspaceDirectory {
            let overflowURL = workspaceDirectory.appendingPathComponent(
                Self.stdoutOverflowFilename)
            try? sanitizedStdout.write(to: overflowURL, atomically: true, encoding: .utf8)
            stdout =
                clipped(sanitizedStdout, maxCharacters: Self.scriptOutputMaxCharacters)
                + "\n[Full output (\(sanitizedStdout.count) chars) saved to "
                + "$KT_WORKSPACE/\(Self.stdoutOverflowFilename) — use kt_shell to read, "
                + "process, or copy it to a write slot]"
            onLog?(
                "[ACT/overflow] stdout \(sanitizedStdout.count) chars → saved to "
                    + "\(overflowURL.lastPathComponent)")
        } else {
            stdout = clipped(sanitizedStdout, maxCharacters: Self.scriptOutputMaxCharacters)
        }
        let stderr = clipped(
            sanitizeAgentVisiblePaths(
                execution.stderr, manifest: manifest, skillDirectory: skillDirectory,
                workspaceDirectory: workspaceDirectory),
            maxCharacters: Self.scriptOutputMaxCharacters
        )

        onLog?("[ACT] command='\(joinedCommand)' exit=\(execution.exitCode)")
        if !stdout.isEmpty { onLog?("[ACT/stdout] \(stdout)") }
        if !stderr.isEmpty { onLog?("[ACT/stderr] \(stderr)") }

        return """
            command: \(joinedCommand)
            exit_code: \(execution.exitCode)
            stdout:
            \(stdout.isEmpty ? "<empty>" : stdout)
            stderr:
            \(stderr.isEmpty ? "<empty>" : stderr)
            """
    }

    /// Replaces absolute paths the agent must not see with stable handles: each
    /// manifest resource path → its `$KT_<KIND>_<H8>` env key, the workspace →
    /// `$KT_WORKSPACE`, the skill directory → `$SKILL_DIR`, and home → `~`. Used to
    /// scrub a run's command line + stdout/stderr before they reach the agent or
    /// the chat output. Longest source first so a file path is rewritten before its
    /// containing directory. Each macOS firmlink-rooted path (/var, /tmp, /etc) is
    /// registered in BOTH its `/var…` and `/private/var…` forms: env vars carry one
    /// form but symlink-resolving tools (`pwd`/`getcwd`, `realpath`, `ls`) emit the
    /// other, so without both a `/private` prefix (or the whole workspace path)
    /// would leak through.
    func sanitizeAgentVisiblePaths(
        _ text: String,
        manifest: KTResourceManifest?,
        skillDirectory: URL?,
        workspaceDirectory: URL? = nil
    ) -> String {
        guard text.contains("/") else { return text }
        var replacements: [(from: String, to: String)] = []
        if let manifest {
            for (key, value) in manifest.environmentVariables() where !value.isEmpty {
                replacements.append((value, "$\(key)"))
            }
        }
        if let workspaceDirectory, !workspaceDirectory.path.isEmpty {
            replacements.append((workspaceDirectory.path, "$KT_WORKSPACE"))
        }
        if let skillDirectory, !skillDirectory.path.isEmpty {
            replacements.append((skillDirectory.path, "$SKILL_DIR"))
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            replacements.append((home, "~"))
        }
        // Register both firmlink forms for every path so the resolved form a tool
        // prints is scrubbed regardless of which form the env var carried.
        let firmlinks = ["/var/", "/tmp/", "/etc/"]
        var expanded: [(from: String, to: String)] = []
        for (from, to) in replacements {
            expanded.append((from, to))
            if firmlinks.contains(where: { from.hasPrefix($0) }) {
                expanded.append(("/private" + from, to))
            } else if from.hasPrefix("/private/var/")
                || from.hasPrefix("/private/tmp/")
                || from.hasPrefix("/private/etc/")
            {
                expanded.append((String(from.dropFirst("/private".count)), to))
            }
        }
        // Longest source first so a file path is rewritten before its parent dir.
        expanded.sort { $0.from.count > $1.from.count }
        var result = text
        for (from, to) in expanded {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    func normalizedSkillToolArguments(_ arguments: [String: Value]) -> [String: Value] {
        if let nested = arguments["arguments"]?.objectValue { return nested }
        if let nested = arguments["params"]?.objectValue { return nested }
        return arguments
    }

    /// Resolves a directory label prefix (e.g. "input_dir/file.m4v") to the real path
    /// using the bundle's parameters. If no label matches, returns the path unchanged.
    func resolveDirectoryLabel(_ path: String, parameters: [String: String]) -> String {
        // Check if path starts with a known parameter label
        for (label, realPath) in parameters where realPath.hasPrefix("/") {
            if path == label {
                return realPath
            }
            let prefix = label + "/"
            if path.hasPrefix(prefix) {
                let remainder = String(path.dropFirst(prefix.count))
                return (realPath as NSString).appendingPathComponent(remainder)
            }
        }
        return path
    }

    /// Lists files in a directory identified by label or relative path.
    func executeListFiles(
        directory: String,
        parameters: [String: String],
        skillDirectory: URL?,
        attachmentsDir: URL? = nil
    ) -> String {
        let resolved = resolveDirectoryLabel(directory, parameters: parameters)
        let dirURL: URL
        if resolved.hasPrefix("/") {
            dirURL = URL(fileURLWithPath: resolved)
        } else if let skillDir = skillDirectory {
            dirURL = skillDir.appendingPathComponent(resolved)
        } else {
            return "Error: no directory found for '\(directory)'."
        }

        // Verify the directory is within an allowed path (skill dir, a parameter
        // dir, or the staged-attachments dir).
        let resolvedPath = dirURL.resolvingSymlinksInPath().path
        let allowedRoots =
            [skillDirectory?.resolvingSymlinksInPath().path].compactMap { $0 }
            + parameters.values.filter { $0.hasPrefix("/") }
            + [attachmentsDir?.resolvingSymlinksInPath().path].compactMap { $0 }
        let isAllowed = allowedRoots.contains { root in
            resolvedPath == root || resolvedPath.hasPrefix(root + "/")
        }
        guard isAllowed else {
            return "Error: directory '\(directory)' is outside allowed paths."
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
            return "Error: '\(directory)' is not a directory or does not exist."
        }

        do {
            let contents = try fm.contentsOfDirectory(atPath: dirURL.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
            if contents.isEmpty {
                return "Directory '\(directory)' is empty."
            }
            let listing = contents.map { name -> String in
                var childIsDir: ObjCBool = false
                let childPath = (dirURL.path as NSString).appendingPathComponent(name)
                fm.fileExists(atPath: childPath, isDirectory: &childIsDir)
                let suffix = childIsDir.boolValue ? "/" : ""
                return "\(directory)/\(name)\(suffix)"
            }
            return listing.joined(separator: "\n")
        } catch {
            return "Error listing '\(directory)': \(error.localizedDescription)"
        }
    }

    func resolveSkillFileURL(
        _ rawPath: String,
        skillDirectory: URL?,
        allowedRoots: [String] = []
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidToolArguments(rawPath)
        }
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            guard let skillDirectory else {
                throw SkillManagerError.invalidSkillDirectory(URL(fileURLWithPath: "<none>"))
            }
            candidate = skillDirectory.appendingPathComponent(trimmed)
        }
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        // Check skill directory
        if let skillDir = skillDirectory?.resolvingSymlinksInPath() {
            let rootPath = skillDir.path
            if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") {
                return resolved
            }
        }

        // Check parameter directories
        for root in allowedRoots where !root.isEmpty {
            if resolvedPath == root || resolvedPath.hasPrefix(root + "/") {
                return resolved
            }
        }

        // If no allowed root matched
        if skillDirectory != nil || !allowedRoots.isEmpty {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }
        return resolved
    }

}
