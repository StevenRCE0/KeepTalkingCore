import AIProxy
import Foundation
import MCP

extension SkillManager {
    func makeSkillTools(context: SkillManifestContext) -> [KeepTalkingActionToolDefinition] {
        var tools: [KeepTalkingActionToolDefinition] = [
            .init(
                functionName: Self.getFileToolName,
                actionID: UUID(),
                ownerNodeID: UUID(),
                source: .skill,
                description:
                    "Read a file from the skill directory or any accessible directory. "
                    + "Use a directory label (e.g. \"input_dir/file.txt\") or a path relative to the skill directory.",
                parameters: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Path to read. Use \"<dir_label>/filename\" for parameter directories "
                                    + "or a relative path for the skill directory."
                            ),
                        ]),
                        "max_characters": .object([
                            "type": .string("integer"),
                            "description": .string("Optional maximum characters to return."),
                        ]),
                    ]),
                    "additionalProperties": .bool(true),
                ]
            ),
            .init(
                functionName: Self.listFilesToolName,
                actionID: UUID(),
                ownerNodeID: UUID(),
                source: .skill,
                description:
                    "List files in an accessible directory. "
                    + "Use a directory label (e.g. \"input_dir\") to list files the user granted access to.",
                parameters: [
                    "type": .string("object"),
                    "properties": .object([
                        "directory": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Directory label from the accessible directories list (e.g. \"input_dir\", \"output_dir\"), "
                                    + "or a relative path within the skill directory."
                            ),
                        ])
                    ]),
                    "required": .array([.string("directory")]),
                    "additionalProperties": .bool(false),
                ]
            ),
        ]

        guard scriptExecutor != nil, !context.declaredTools.isEmpty else {
            return tools
        }

        for toolName in context.declaredTools.keys.sorted() {
            let scriptPath = context.declaredTools[toolName]!
            tools.append(
                .init(
                    functionName: toolName,
                    actionID: UUID(),
                    ownerNodeID: UUID(),
                    source: .skill,
                    description: "Run the \(toolName) skill tool (\(scriptPath)). "
                        + "Pass the full CLI arguments as a plain text string — "
                        + "the runtime resolves directory labels and env values automatically.",
                    parameters: [
                        "type": .string("object"),
                        "properties": .object([
                            "args": .object([
                                "type": .string("string"),
                                "description": .string(
                                    "Raw CLI arguments string, e.g. '--text \"hello world\" --voice Samantha'. "
                                        + "Use directory labels (e.g. input_dir/file.txt) for paths."
                                ),
                            ])
                        ]),
                        "additionalProperties": .bool(false),
                    ]
                )
            )
        }
        return tools
    }

    func makeSkillSystemPrompt(
        actionID: UUID,
        bundle: KeepTalkingSkillBundle,
        call: KeepTalkingActionCall,
        manifestContext: SkillManifestContext
    ) -> String {
        let metadataJSON = encodeJSON(call.metadata.fields)
        let argumentsJSON = encodeJSON(call.arguments)
        let manifestMetadataJSON = encodeJSON(manifestContext.manifestMetadata)
        let scriptIndex = manifestContext.scripts.joined(separator: "\n")
        let referenceIndex = manifestContext.referencesFiles.joined(separator: "\n")
        let assetIndex = manifestContext.assets.joined(separator: "\n")

        let declaredToolsList =
            manifestContext.declaredTools.isEmpty
            ? "<none>"
            : manifestContext.declaredTools.sorted(by: { $0.key < $1.key })
                .map { "- \($0.key) → \($0.value)" }.joined(separator: "\n")

        // Build accessible directories list from parameters that look like paths
        let directoryParams = bundle.parameters.filter { _, value in
            value.hasPrefix("/") && FileManager.default.fileExists(atPath: value)
        }
        let accessibleDirsList: String
        if directoryParams.isEmpty {
            accessibleDirsList = "<none>"
        } else {
            accessibleDirsList = directoryParams.sorted(by: { $0.key < $1.key })
                .map { "- \($0.key) (use \"\($0.key)/\" prefix to access files)" }
                .joined(separator: "\n")
        }

        return """
            You are executing a KeepTalking skill action.
            Action ID: \(actionID.uuidString.lowercased())
            Skill Name: \(bundle.name)

            ## CRITICAL: You MUST call tool functions to execute scripts.
            You have the following executable tools available. Call them directly — do NOT output
            shell commands or ask the user to run anything manually.
            \(declaredToolsList)

            ## Accessible directories
            These directories were granted by the user. Use \(Self.listFilesToolName) to discover
            files, and reference them by label (e.g. "input_dir/filename.ext") when passing paths
            to scripts. The runtime resolves labels to real paths automatically.
            \(accessibleDirsList)

            ## File tools
            - \(Self.listFilesToolName): List files in an accessible directory by label.
            - \(Self.getFileToolName): Read a file from the skill directory or an accessible directory.

            ## Execution requirements
            - ALWAYS call a declared tool to fulfill the request. Never just describe a command.
            - If a filename is ambiguous or uncertain, call \(Self.listFilesToolName) first to find the exact name.
            - Script output (stdout/stderr) is returned directly.
            - Be explicit and concise in the final answer.

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

            Manifest content:
            \(manifestContext.manifestText)
            """
    }

    func makeSkillUserPrompt(call: KeepTalkingActionCall) -> String {
        if let directPrompt =
            call.arguments["prompt"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !directPrompt.isEmpty
        {
            return directPrompt
        }
        return "Execute this skill request based on the provided request arguments and metadata."
    }

    func clipped(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters)) + "\n...[truncated]..."
    }

    func encodeJSON<T: Encodable>(_ value: T) -> String {
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
