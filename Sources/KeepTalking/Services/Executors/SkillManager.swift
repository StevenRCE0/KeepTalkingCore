//
//  SkillManager.swift
//  KeepTalking
//
//  Created by 砚渤 on 28/02/2026.
//

import Foundation
import MCP
import OpenAI

public enum SkillManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case missingAIConnector
    case invalidSkillDirectory(URL)
    case missingSkillManifest(URL)
    case invalidToolArguments(String)
    case invalidSkillPath(String)
    case toolCallTimedOut(UUID, TimeInterval)

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not a skill bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .missingAIConnector:
                return
                    "OpenAI is not configured for skill execution. Set OPENAI_API_KEY."
            case .invalidSkillDirectory(let url):
                return "Skill directory does not exist or is not readable: \(url.path)"
            case .missingSkillManifest(let url):
                return "Skill manifest not found: \(url.path)"
            case .invalidToolArguments(let raw):
                return "Tool arguments are not valid JSON object: \(raw)"
            case .invalidSkillPath(let path):
                return "Requested path is outside the skill directory: \(path)"
            case .toolCallTimedOut(let actionID, let timeout):
                return
                    "Timed out waiting for skill script action=\(actionID) after \(Int(timeout))s."
        }
    }
}

enum SkillScriptRunner {
    struct ExecutionResult: Sendable {
        let command: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private enum RunOutcome: Sendable {
        case exited(Int32)
        case timedOut
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func makeCommand(
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

    static func run(
        command: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> ExecutionResult {
        guard let executable = command.first else {
            return ExecutionResult(
                command: [],
                exitCode: 2,
                stdout: "",
                stderr: "Missing command executable."
            )
        }

        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await run(
                process: processBox.process,
                executable: executable,
                command: command,
                currentDirectory: currentDirectory,
                actionID: actionID,
                timeoutSeconds: timeoutSeconds
            )
        } onCancel: {
            terminateProcessIfRunning(processBox.process)
        }
    }

    private static func run(
        process: Process,
        executable: String,
        command: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> ExecutionResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = mergedEnvironment(for: command)

        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
        let exitCode: Int32
        do {
            let outcome = try await withThrowingTaskGroup(
                of: RunOutcome.self
            ) { group in
                group.addTask {
                    let status = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Int32, Error>) in
                        process.terminationHandler = { process in
                            continuation.resume(
                                returning: process.terminationStatus
                            )
                        }
                        do {
                            try process.run()
                            stdoutPipe.fileHandleForWriting.closeFile()
                            stderrPipe.fileHandleForWriting.closeFile()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    return .exited(status)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    requestProcessTermination(process)
                    return .timedOut
                }

                guard let result = try await group.next() else {
                    throw SkillManagerError.toolCallTimedOut(
                        actionID,
                        timeoutSeconds
                    )
                }
                group.cancelAll()
                return result
            }
            switch outcome {
                case .exited(let status):
                    exitCode = status
                case .timedOut:
                    throw SkillManagerError.toolCallTimedOut(
                        actionID,
                        timeoutSeconds
                    )
            }
        } catch {
            terminateProcessIfRunning(process)
            _ = try? await stdoutData
            _ = try? await stderrData
            throw error
        }

        let stdoutText = decode(data: try await stdoutData)
        let stderrText = decode(data: try await stderrData)

        return ExecutionResult(
            command: command,
            exitCode: exitCode,
            stdout: stdoutText,
            stderr: stderrText
        )
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try handle.readToEnd() ?? Data()
        }.value
    }

    private static func decode(data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
    }

    private static func requestProcessTermination(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }

    private static func mergedEnvironment(for command: [String]) -> [String: String]
    {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resolvePathEnvironment(
            command: command,
            environment: environment
        )
        environment["TMPDIR"] = resolveWritableTempDirectory(
            environment: environment
        )
        if environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        {
            environment["HOME"] = NSHomeDirectory()
        }
        return environment
    }

    private static func resolveWritableTempDirectory(
        environment: [String: String]
    ) -> String {
        let fileManager = FileManager.default
        let fallback = "/tmp"
        let candidates = [
            environment["TMPDIR"],
            ProcessInfo.processInfo.environment["TMPDIR"],
            NSTemporaryDirectory(),
            fallback,
        ]
        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                fileManager.isWritableFile(atPath: path)
            else {
                continue
            }
            return path
        }
        return fallback
    }

    private static func resolvePathEnvironment(
        command: [String],
        environment: [String: String]
    ) -> String {
        var components = (
            environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for candidate in defaults where !components.contains(candidate) {
            components.append(candidate)
        }

        if let executable = command.first,
            executable.hasPrefix("/")
        {
            let directory = URL(fileURLWithPath: executable)
                .deletingLastPathComponent().path
            if !directory.isEmpty, !components.contains(directory) {
                components.insert(directory, at: 0)
            }
        }

        if components.isEmpty {
            return defaults.joined(separator: ":")
        }
        return components.joined(separator: ":")
    }
}

/// Executes skill-backed actions by exposing skill files and scripts as AI tools.
public actor SkillManager {
    private struct SkillManifestContext: Sendable {
        let manifestURL: URL
        let manifestText: String
        let manifestMetadata: [String: String]
        let referencesFiles: [String]
        let scripts: [String]
        let assets: [String]
    }

    private static let getFileToolName = "kt_skill_get_file"
    private static let runScriptToolName = "kt_skill_run_script"
    private static let manifestMaxCharacters = 20_000
    private static let fileReadMaxCharacters = 30_000
    private static let scriptOutputMaxCharacters = 18_000

    private let nodeConfig: KeepTalkingConfig
    private let openAIConnector: OpenAIConnector?
    private let scriptTimeoutSeconds: TimeInterval

    private var skillBundlesByActionID: [UUID: KeepTalkingSkillBundle] = [:]

    /// Creates a skill manager for a node runtime.
    public init(
        nodeConfig: KeepTalkingConfig,
        openAIConnector: OpenAIConnector?,
        scriptTimeoutSeconds: TimeInterval = 20
    ) {
        self.nodeConfig = nodeConfig
        self.openAIConnector = openAIConnector
        self.scriptTimeoutSeconds = scriptTimeoutSeconds
    }

    /// Registers a skill action so it can be resolved and executed later.
    public func registerSkillAction(_ action: KeepTalkingAction) async throws {
        guard case .skill(let skillBundle) = action.payload else {
            throw SkillManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        try validateSkillDirectory(skillBundle.directory)
        skillBundlesByActionID[actionID] = skillBundle
    }

    /// Re-registers a skill action after its bundle metadata changes.
    public func refreshSkillAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        skillBundlesByActionID.removeValue(forKey: actionID)
        try await registerSkillAction(action)
    }

    /// Removes the runtime state associated with a skill action.
    public func unregisterAction(actionID: UUID) async {
        skillBundlesByActionID.removeValue(forKey: actionID)
    }

    /// Ensures a skill action is registered before use.
    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        if skillBundlesByActionID[actionID] == nil {
            try await registerSkillAction(action)
        }
    }

    /// Executes a skill action by planning tool usage with the configured AI connector.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall
    ) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        guard case .skill(let skillBundle) = action.payload else {
            throw SkillManagerError.invalidAction
        }
        guard let openAIConnector else {
            throw SkillManagerError.missingAIConnector
        }

        try await registerIfNeeded(action)

        let manifestContext = try loadManifestContext(
            for: skillBundle.directory
        )
        let allowScriptExecution = shouldAllowScriptExecution(
            call: call,
            manifestContext: manifestContext
        )
        let tools = makeSkillTools(
            allowScriptExecution: allowScriptExecution
        )
        var messages: [ChatQuery.ChatCompletionMessageParam] = [
            .developer(
                .init(
                    content: .textContent(
                        makeSkillSystemPrompt(
                            actionID: actionID,
                            bundle: skillBundle,
                            call: call,
                            manifestContext: manifestContext,
                            allowScriptExecution: allowScriptExecution
                        )
                    )
                )
            ),
            .user(
                .init(
                    content: .string(
                        makeSkillUserPrompt(call: call)
                    )
                )
            ),
        ]

        var latestAssistantText: String?
        for _ in 0..<8 {
            let turn = try await openAIConnector.completeTurn(
                messages: messages,
                tools: OpenAIConnector.toResponseTools(tools: tools),
                model: "gpt-5-codex"
            )

            if let assistantMessage = assistantMessage(from: turn) {
                messages.append(assistantMessage)
            }
            if let assistantText = turn.assistantText,
                !assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                latestAssistantText = assistantText
            }

            guard !turn.toolCalls.isEmpty else {
                break
            }

            messages.append(
                contentsOf: try await executeSkillToolCalls(
                    turn.toolCalls,
                    actionID: actionID,
                    skillDirectory: skillBundle.directory
                )
            )
        }

        let finalText =
            latestAssistantText
            ?? "Skill execution completed."

        return (
            content: [.text(finalText)],
            isError: false
        )
    }

    /// Returns the external tool names exposed by a skill action.
    public func listActionToolNames(action: KeepTalkingAction) async throws
        -> [String]
    {
        guard case .skill(let bundle) = action.payload else {
            throw SkillManagerError.invalidAction
        }
        let trimmed = bundle.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.isEmpty {
            return ["skill_action"]
        }
        return [trimmed]
    }

    private func makeSkillTools(
        allowScriptExecution: Bool
    ) -> [ChatQuery.ChatCompletionToolParam] {
        var tools: [ChatQuery.ChatCompletionToolParam] = [
            ChatQuery.ChatCompletionToolParam(
                function: .init(
                    name: Self.getFileToolName,
                    description:
                        "Read a file from the skill directory. Use relative paths when possible.",
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([
                            "path": JSONSchema(
                                .type(.string),
                                .description(
                                    "Path to read, relative to the skill directory."
                                )
                            ),
                            "max_characters": JSONSchema(
                                .type(.integer),
                                .description(
                                    "Optional maximum characters to return."
                                )
                            ),
                        ]),
                        .additionalProperties(.boolean(true))
                    ),
                    strict: false
                )
            )
        ]

        guard allowScriptExecution else {
            return tools
        }

        tools.append(
            ChatQuery.ChatCompletionToolParam(
                function: .init(
                    name: Self.runScriptToolName,
                    description:
                        "Run a script inside the skill directory. Prefer files inside scripts/.",
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([
                            "script": JSONSchema(
                                .type(.string),
                                .description(
                                    "Script file path, relative to the skill directory or scripts/."
                                )
                            ),
                            "args": JSONSchema(
                                .type(.object),
                                .description(
                                    "Optional script arguments, usually an array of strings."
                                ),
                                .additionalProperties(.boolean(true))
                            ),
                        ]),
                        .additionalProperties(.boolean(true))
                    ),
                    strict: false
                )
            )
        )
        return tools
    }

    private func assistantMessage(
        from turn: OpenAIConnector.ToolPlanningResult
    ) -> ChatQuery.ChatCompletionMessageParam? {
        let text = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? =
            (text?.isEmpty == false) ? .textContent(text!) : nil
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        if content == nil, toolCalls == nil {
            return nil
        }
        return .assistant(
            .init(
                content: content,
                toolCalls: toolCalls
            )
        )
    }

    private func executeSkillToolCalls(
        _ toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam],
        actionID: UUID,
        skillDirectory: URL
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.function.name
            let arguments = normalizedSkillToolArguments(
                try decodeToolArguments(toolCall.function.arguments)
            )

            let payload: String
            switch functionName {
                case Self.getFileToolName:
                    payload = try executeGetFile(
                        arguments,
                        skillDirectory: skillDirectory
                    )
                case Self.runScriptToolName:
                    payload = try await executeRunScript(
                        arguments,
                        actionID: actionID,
                        skillDirectory: skillDirectory
                    )
                default:
                    payload = "Unknown tool name: \(functionName)"
            }

            messages.append(
                .tool(
                    .init(
                        content: .textContent(payload),
                        toolCallId: toolCallID
                    )
                )
            )
        }
        return messages
    }

    private func decodeToolArguments(_ raw: String) throws -> [String: Value] {
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

    private func executeGetFile(
        _ arguments: [String: Value],
        skillDirectory: URL
    ) throws -> String {
        let rawPath =
            arguments["path"]?.stringValue
            ?? arguments["file"]?.stringValue
            ?? ""
        let fileURL = try resolveSkillFileURL(
            rawPath,
            skillDirectory: skillDirectory
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

    private func executeRunScript(
        _ arguments: [String: Value],
        actionID: UUID,
        skillDirectory: URL
    ) async throws -> String {
        let rawScript =
            arguments["script"]?.stringValue
            ?? arguments["path"]?.stringValue
            ?? ""
        let scriptURL = try resolveScriptURL(
            rawScript,
            skillDirectory: skillDirectory
        )
        let scriptArguments = extractScriptArguments(arguments)
        let command = SkillScriptRunner.makeCommand(
            scriptURL: scriptURL,
            arguments: scriptArguments
        )
        let execution = try await SkillScriptRunner.run(
            command: command,
            currentDirectory: skillDirectory,
            actionID: actionID,
            timeoutSeconds: scriptTimeoutSeconds
        )

        let joinedCommand = execution.command.joined(separator: " ")
        let stdout = clipped(
            execution.stdout,
            maxCharacters: Self.scriptOutputMaxCharacters
        )
        let stderr = clipped(
            execution.stderr,
            maxCharacters: Self.scriptOutputMaxCharacters
        )
        return """
            command: \(joinedCommand)
            exit_code: \(execution.exitCode)
            stdout:
            \(stdout.isEmpty ? "<empty>" : stdout)
            stderr:
            \(stderr.isEmpty ? "<empty>" : stderr)
            """
    }

    private func extractScriptArguments(_ arguments: [String: Value]) -> [String] {
        if let array = arguments["args"]?.arrayValue {
            return array.compactMap(scriptArgumentString(for:))
        }
        if let object = arguments["args"]?.objectValue {
            return object.sorted { $0.key < $1.key }.compactMap { key, value in
                scriptArgumentString(for: value).map { "\(key)=\($0)" }
            }
        }
        if let raw = arguments["args"]?.stringValue {
            return raw.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        if let raw = arguments["arguments"]?.stringValue {
            return raw.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return []
    }

    private func scriptArgumentString(for value: Value) -> String? {
        if let string = value.stringValue {
            return string
        }
        if let int = value.intValue {
            return String(int)
        }
        if let double = value.doubleValue {
            return String(double)
        }
        if let bool = value.boolValue {
            return String(bool)
        }
        return nil
    }

    private func normalizedSkillToolArguments(_ arguments: [String: Value])
        -> [String: Value]
    {
        if let nested = arguments["arguments"]?.objectValue {
            return nested
        }
        if let nested = arguments["params"]?.objectValue {
            return nested
        }
        return arguments
    }

    private func validateSkillDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SkillManagerError.invalidSkillDirectory(directory)
        }

        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: directory
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SkillManagerError.missingSkillManifest(manifestURL)
        }
    }

    private func loadManifestContext(for directory: URL) throws
        -> SkillManifestContext
    {
        try validateSkillDirectory(directory)
        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: directory
        )
        let rawManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let manifestText = clipped(
            rawManifest,
            maxCharacters: Self.manifestMaxCharacters
        )
        let metadata = parseManifestMetadata(rawManifest)

        return SkillManifestContext(
            manifestURL: manifestURL,
            manifestText: manifestText,
            manifestMetadata: metadata,
            referencesFiles: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .references,
                    in: directory
                ),
                root: directory
            ),
            scripts: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .scripts,
                    in: directory
                ),
                root: directory
            ),
            assets: listRelativeFiles(
                in: SkillDirectoryDefinitions.entryURL(
                    .assets,
                    in: directory
                ),
                root: directory
            )
        )
    }

    private func parseManifestMetadata(_ manifest: String) -> [String: String] {
        guard manifest.hasPrefix("---") else {
            return [:]
        }
        let lines = manifest.components(separatedBy: .newlines)
        guard lines.count >= 3, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return [:]
        }

        var metadata: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            guard
                let separator = line.firstIndex(of: ":"),
                separator != line.startIndex
            else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                metadata[key] = value
            }
        }
        return metadata
    }

    private func listRelativeFiles(in directory: URL, root: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return []
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let rootPath = root.standardizedFileURL.path
        var files: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }

            let path = fileURL.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                files.append(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return files.sorted()
    }

    private func makeSkillSystemPrompt(
        actionID: UUID,
        bundle: KeepTalkingSkillBundle,
        call: KeepTalkingActionCall,
        manifestContext: SkillManifestContext,
        allowScriptExecution: Bool
    ) -> String {
        let metadataJSON = encodeJSON(call.metadata.fields)
        let argumentsJSON = encodeJSON(call.arguments)
        let manifestMetadataJSON = encodeJSON(manifestContext.manifestMetadata)
        let scriptIndex = manifestContext.scripts.joined(separator: "\n")
        let referenceIndex = manifestContext.referencesFiles.joined(separator: "\n")
        let assetIndex = manifestContext.assets.joined(separator: "\n")

        return """
            You are executing a KeepTalking skill action.
            Action ID: \(actionID.uuidString.lowercased())
            Skill Name: \(bundle.name)
            Skill Directory: \(bundle.directory.path)
            Skill Manifest: \(manifestContext.manifestURL.path)

            Execution requirements:
            - Extract and use metadata from the request and skill manifest.
            - Use tool calls for file reads when needed.
            - Script execution is allowed only when explicitly requested.
            - Keep script execution scoped to this skill directory.
            - Be explicit and concise in the final answer.

            Script execution allowed for this request: \(allowScriptExecution ? "yes" : "no")

            Request metadata JSON:
            \(metadataJSON)

            Request arguments JSON:
            \(argumentsJSON)

            Skill manifest metadata JSON:
            \(manifestMetadataJSON)

            Available files:
            scripts/
            \(scriptIndex.isEmpty ? "<none>" : scriptIndex)

            references/
            \(referenceIndex.isEmpty ? "<none>" : referenceIndex)

            assets/
            \(assetIndex.isEmpty ? "<none>" : assetIndex)

            Manifest content (possibly truncated):
            \(manifestContext.manifestText)
            """
    }

    private func shouldAllowScriptExecution(
        call: KeepTalkingActionCall,
        manifestContext: SkillManifestContext
    ) -> Bool {
        guard !manifestContext.scripts.isEmpty else {
            return false
        }

        if call.arguments["execute_scripts"]?.boolValue == true {
            return true
        }
        if call.metadata.fields["execute_scripts"]?.boolValue == true {
            return true
        }

        let promptText =
            call.arguments["prompt"]?.stringValue?.lowercased() ?? ""
        if promptText.isEmpty {
            return false
        }
        let executionKeywords = [
            "run script",
            "execute script",
            "run ",
            "execute ",
            "build",
            "test",
        ]
        return executionKeywords.contains { promptText.contains($0) }
    }

    private func makeSkillUserPrompt(call: KeepTalkingActionCall) -> String {
        if let directPrompt =
            call.arguments["prompt"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !directPrompt.isEmpty
        {
            return directPrompt
        }
        return "Execute this skill request based on the provided request arguments and metadata."
    }

    private func resolveSkillFileURL(
        _ rawPath: String,
        skillDirectory: URL
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidToolArguments(rawPath)
        }
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = skillDirectory.appendingPathComponent(trimmed)
        }
        let resolved = candidate.standardizedFileURL
        let rootPath = skillDirectory.standardizedFileURL.path
        let resolvedPath = resolved.path

        let insideRoot =
            resolvedPath == rootPath
            || resolvedPath.hasPrefix(rootPath + "/")
        guard insideRoot else {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }
        return resolved
    }

    private func resolveScriptURL(
        _ rawScript: String,
        skillDirectory: URL
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
        ),
            !isDirectory.boolValue
        {
            return resolvedScriptsCandidate
        }

        throw SkillManagerError.invalidSkillPath(trimmed)
    }

    private func clipped(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters)) + "\n...[truncated]..."
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}
