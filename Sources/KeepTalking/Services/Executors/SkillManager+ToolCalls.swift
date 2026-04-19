#if os(macOS)
import Foundation
import MCP
import OpenAI

extension SkillManager {
    func assistantMessage(
        from turn: AITurnResult
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

    func executeSkillToolCalls(
        _ toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam],
        actionID: UUID,
        skillDirectory: URL,
        sandboxPolicy: KTSandboxPolicy? = nil
    ) async throws -> [ChatQuery.ChatCompletionMessageParam.ToolMessageParam] {
        var messages: [ChatQuery.ChatCompletionMessageParam.ToolMessageParam] = []
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
                        skillDirectory: skillDirectory,
                        sandboxPolicy: sandboxPolicy
                    )
                default:
                    payload = "Unknown tool name: \(functionName)"
            }

            messages.append(
                .init(
                    content: .textContent(payload),
                    toolCallId: toolCallID
                )
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

    func executeRunScript(
        _ arguments: [String: Value],
        actionID: UUID,
        skillDirectory: URL,
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
        let execution = try await scriptExecutor.runScript(
            scriptURL: scriptURL,
            arguments: scriptArguments,
            currentDirectory: skillDirectory,
            actionID: actionID,
            timeoutSeconds: scriptTimeoutSeconds,
            sandboxPolicy: sandboxPolicy
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

    func extractScriptArguments(_ arguments: [String: Value]) -> [String] {
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

    func resolveSkillFileURL(
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

    func resolveScriptURL(
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
        ), !isDirectory.boolValue {
            return resolvedScriptsCandidate
        }
        throw SkillManagerError.invalidSkillPath(trimmed)
    }
}
#endif
