import Foundation
import MCP
import OpenAI

extension SkillManager {
    func makeSkillTools(
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

    func makeSkillSystemPrompt(
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
            - If a tool call can advance the request, make the tool call instead of only describing the next step.
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

    func shouldAllowScriptExecution(
        call: KeepTalkingActionCall,
        manifestContext: SkillManifestContext
    ) -> Bool {
        guard !manifestContext.scripts.isEmpty else {
            return false
        }
        guard scriptExecutor != nil else {
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
