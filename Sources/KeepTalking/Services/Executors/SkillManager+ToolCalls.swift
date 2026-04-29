import AIProxy
import Foundation
import MCP

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
        sandboxPolicy: KTSandboxPolicy? = nil
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
            let paramDirRoots = parameters.values.filter { $0.hasPrefix("/") }
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
                payload = executeListFiles(directory: dirLabel, parameters: parameters, skillDirectory: skillDirectory)
            } else if let scriptPath = manifestContext.declaredTools[functionName] {
                // Route declared tool call to its script — ACT provides raw CLI args string
                let rawArgs = arguments["args"]?.stringValue ?? ""
                let resolvedArgs = resolveDirectoryLabel(rawArgs, parameters: parameters)
                let scriptArgs: [String: Value] = [
                    "script": .string(scriptPath),
                    "args": .string(resolvedArgs),
                ]
                payload = try await executeRunScript(
                    scriptArgs,
                    actionID: actionID,
                    skillDirectory: skillDirectory,
                    parameters: parameters,
                    sandboxPolicy: sandboxPolicy
                )
            } else {
                payload = "Tool '\(functionName)' is not declared in this skill's manifest."
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

    func executeRunScript(
        _ arguments: [String: Value],
        actionID: UUID,
        skillDirectory: URL?,
        parameters: [String: String] = [:],
        sandboxPolicy: KTSandboxPolicy? = nil
    ) async throws -> String {
        guard let scriptExecutor else {
            throw SkillManagerError.scriptExecutionUnavailableOnThisPlatform
        }
        let rawScript =
            arguments["script"]?.stringValue
            ?? arguments["path"]?.stringValue
            ?? ""
        let scriptURL = try resolveScriptURL(
            rawScript,
            skillDirectory: skillDirectory
        )
        let scriptArguments = extractScriptArguments(arguments)

        // Build env from bundle parameters; always inject SKILL_DIR
        var environment = parameters
        if let skillDir = skillDirectory {
            environment["SKILL_DIR"] = skillDir.path
        }

        #if os(macOS)
        let execution = try await scriptExecutor.runScript(
            scriptURL: scriptURL,
            arguments: scriptArguments,
            currentDirectory: skillDirectory ?? URL(fileURLWithPath: "/"),
            environment: environment,
            actionID: actionID,
            timeoutSeconds: scriptTimeoutSeconds,
            sandboxPolicy: sandboxPolicy
        )

        if let sandboxPolicy = sandboxPolicy {
            if let env = sandboxPolicy.descriptor.environment, !env.isEmpty {
                let envString = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: " ")
                let msg = "[ACT/env] \(envString)"
                onLog?(msg)
                print(msg)
            }
            if let directories = sandboxPolicy.descriptor.directories, !directories.isEmpty {
                let dirString = directories.keys.sorted().map { "\($0)=\(directories[$0]?.path ?? "")" }.joined(
                    separator: " ")
                let msg = "[ACT/dirs] \(dirString)"
                onLog?(msg)
                print(msg)
            }
        }
        #else
        // iOS protocol does not accept `environment` or `sandboxPolicy`; the
        // env dict is dropped on this platform.
        _ = environment
        let execution = try await scriptExecutor.runScript(
            scriptURL: scriptURL,
            arguments: scriptArguments,
            currentDirectory: skillDirectory ?? URL(fileURLWithPath: "/"),
            actionID: actionID,
            timeoutSeconds: scriptTimeoutSeconds
        )
        #endif

        let joinedCommand = execution.command.joined(separator: " ")
        let stdout = clipped(
            execution.stdout,
            maxCharacters: Self.scriptOutputMaxCharacters
        )
        let stderr = clipped(
            execution.stderr,
            maxCharacters: Self.scriptOutputMaxCharacters
        )

        let logMsg = "[ACT] command='\(joinedCommand)' exit=\(execution.exitCode)"
        onLog?(logMsg)
        print(logMsg)

        if !stdout.isEmpty {
            let outMsg = "[ACT/stdout] \(stdout)"
            onLog?(outMsg)
            print(outMsg)
        }
        if !stderr.isEmpty {
            let errMsg = "[ACT/stderr] \(stderr)"
            onLog?(errMsg)
            print(errMsg)
        }
        return """
            command: \(joinedCommand)
            exit_code: \(execution.exitCode)
            stdout:
            \(stdout.isEmpty ? "<empty>" : stdout)
            stderr:
            \(stderr.isEmpty ? "<empty>" : stderr)
            """
    }

    func extractScriptArguments(_ arguments: [String: Value]) -> [String] {
        // ACT provides args as a raw CLI string — split respecting shell quoting
        if let raw = arguments["args"]?.stringValue {
            return shellSplit(raw)
        }
        if let raw = arguments["arguments"]?.stringValue {
            return shellSplit(raw)
        }
        if let array = arguments["args"]?.arrayValue {
            return array.compactMap(scriptArgumentString(for:))
        }
        return []
    }

    /// Splits a string into shell-style tokens, respecting double and single quotes.
    private func shellSplit(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var escape = false
        for ch in string {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" && !inSingle {
                escape = true
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if ch.isWhitespace && !inDouble && !inSingle {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    func scriptArgumentString(for value: Value) -> String? {
        if let string = value.stringValue { return string }
        if let int = value.intValue { return String(int) }
        if let double = value.doubleValue { return String(double) }
        if let bool = value.boolValue { return String(bool) }
        return nil
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
        skillDirectory: URL?
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

        // Verify the directory is within an allowed path (skill dir or a parameter dir)
        let resolvedPath = dirURL.resolvingSymlinksInPath().path
        let allowedRoots =
            [skillDirectory?.resolvingSymlinksInPath().path].compactMap { $0 }
            + parameters.values.filter { $0.hasPrefix("/") }
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

    func resolveScriptURL(
        _ rawScript: String,
        skillDirectory: URL?
    ) throws -> URL {
        let trimmed = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidToolArguments(rawScript)
        }
        let primary = try resolveSkillFileURL(trimmed, skillDirectory: skillDirectory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: primary.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            return primary
        }
        let scriptsCandidate = "scripts/\(trimmed)"
        let resolvedScriptsCandidate = try resolveSkillFileURL(
            scriptsCandidate,
            skillDirectory: skillDirectory
        )
        if FileManager.default.fileExists(
            atPath: resolvedScriptsCandidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue {
            return resolvedScriptsCandidate
        }
        throw SkillManagerError.invalidSkillPath(trimmed)
    }
}
