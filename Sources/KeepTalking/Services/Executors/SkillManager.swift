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

public actor SkillManager {
    private struct ScriptExecutionResult: Sendable {
        let command: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

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

    public init(
        nodeConfig: KeepTalkingConfig,
        openAIConnector: OpenAIConnector?,
        scriptTimeoutSeconds: TimeInterval = 20
    ) {
        self.nodeConfig = nodeConfig
        self.openAIConnector = openAIConnector
        self.scriptTimeoutSeconds = scriptTimeoutSeconds
    }

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

    public func refreshSkillAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        skillBundlesByActionID.removeValue(forKey: actionID)
        try await registerSkillAction(action)
    }

    public func unregisterAction(actionID: UUID) async {
        skillBundlesByActionID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        if skillBundlesByActionID[actionID] == nil {
            try await registerSkillAction(action)
        }
    }

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
                tools: tools,
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
            let arguments = try decodeToolArguments(toolCall.function.arguments)

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
        let command = makeScriptCommand(
            scriptURL: scriptURL,
            scriptArguments: scriptArguments
        )
        let execution = try await Self.runCommandWithTimeout(
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
            return array.compactMap { value in
                value.stringValue
                    ?? value.intValue.map { String($0) }
                    ?? value.doubleValue.map { String($0) }
            }
        }
        if let object = arguments["args"]?.objectValue {
            return object.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        if let raw = arguments["args"]?.stringValue {
            return raw.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        if let raw = arguments["arguments"]?.stringValue {
            return raw.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return []
    }

    private func makeScriptCommand(
        scriptURL: URL,
        scriptArguments: [String]
    ) -> [String] {
        let path = scriptURL.path
        switch scriptURL.pathExtension.lowercased() {
            case "py":
                return ["/usr/bin/env", "python3", path] + scriptArguments
            case "sh":
                return ["/bin/zsh", path] + scriptArguments
            default:
                if FileManager.default.isExecutableFile(atPath: path) {
                    return [path] + scriptArguments
                }
                return ["/bin/zsh", path] + scriptArguments
        }
    }

    private nonisolated static func runCommandWithTimeout(
        command: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> ScriptExecutionResult {
        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
        return try await withThrowingTaskGroup(
            of: ScriptExecutionResult.self
        ) { group in
            group.addTask {
                try runCommand(
                    command: command,
                    currentDirectory: currentDirectory
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw SkillManagerError.toolCallTimedOut(actionID, timeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw SkillManagerError.toolCallTimedOut(actionID, timeoutSeconds)
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func runCommand(
        command: [String],
        currentDirectory: URL
    ) throws -> ScriptExecutionResult {
        guard let executable = command.first else {
            return ScriptExecutionResult(
                command: [],
                exitCode: 2,
                stdout: "",
                stderr: "Missing command executable."
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ScriptExecutionResult(
                command: command,
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        process.waitUntilExit()

        let stdoutData =
            try stdoutPipe.fileHandleForReading.readToEnd()
            ?? Data()
        let stderrData =
            try stderrPipe.fileHandleForReading.readToEnd()
            ?? Data()
        let stdoutText =
            String(data: stdoutData, encoding: .utf8)
            ?? String(decoding: stdoutData, as: UTF8.self)
        let stderrText =
            String(data: stderrData, encoding: .utf8)
            ?? String(decoding: stderrData, as: UTF8.self)

        return ScriptExecutionResult(
            command: command,
            exitCode: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText
        )
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
