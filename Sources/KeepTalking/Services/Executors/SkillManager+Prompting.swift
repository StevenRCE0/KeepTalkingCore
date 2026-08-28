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
                    "Read a PLAIN-TEXT (UTF-8) file from the skill directory or any accessible directory. "
                    + "Binary files (PDF, images, .docx, etc.) are not readable this way — run a script/tool that extracts their text instead. "
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

        // The general-purpose execution primitive: a real sandboxed shell. The
        // agent writes a command line; resource handles ($KT_<KIND>_<HEX>), pipes,
        // redirections, and globs all work because a genuine shell interprets it.
        if scriptExecutor != nil {
            tools.append(
                .init(
                    functionName: Self.shellToolName,
                    actionID: UUID(),
                    ownerNodeID: UUID(),
                    source: .skill,
                    description:
                        "Run a command line in a sandboxed shell (zsh), with the current "
                        + "directory set to your writable workspace. This is a REAL shell: "
                        + "pipes, redirections (2>&1, >file), quoting, and globs all work, "
                        + "and stdout/stderr/exit_code are returned. Every KeepTalking resource "
                        + "handle is an environment variable whose VALUE is that file's absolute "
                        + "path — use the handle in its $-form AS the path, e.g. "
                        + "cat \"$KT_ATTACHMENT_<HEX>\". Never hardcode an absolute path and never "
                        + "invent a handle. Only the skill directory, the provisioned resources, "
                        + "and the workspace are reachable; anything else is blocked by the sandbox.",
                    parameters: [
                        "type": .string("object"),
                        "properties": .object([
                            "command": .object([
                                "type": .string("string"),
                                "description": .string(
                                    "The shell command line to run. Pass resource handles in their "
                                        + "$-form as paths, e.g. "
                                        + "'python3 \"$SKILL_DIR/scripts/run.py\" --in \"$KT_OTB_<HEX>\" > \"$KT_ATTACHMENT_<HEX>\"'."
                                ),
                            ])
                        ]),
                        "required": .array([.string("command")]),
                        "additionalProperties": .bool(false),
                    ]
                )
            )
        }

        // Per-declared-script tools are retired: the agent runs scripts through
        // `kt_shell` (`zsh "$SKILL_DIR/scripts/foo.py" …`) instead of a generated
        // tool per `scripts.<name>` frontmatter entry. The shell is the single,
        // universal execution surface — no tool registry to keep in sync.
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

            ## Shell (\(Self.shellToolName)) — your execution tool
            Run scripts, CLI tools, and multi-step pipelines through \(Self.shellToolName).
            It is a REAL sandboxed shell whose current directory is your writable
            workspace, so pipes, redirections (2>&1, > out.txt), quoting, and globs all
            work. Every provisioned resource is an environment variable whose VALUE is
            that file's absolute path — use the handle in its $-form AS the concrete path,
            e.g. `python3 "$SKILL_DIR/scripts/run.py" --in "$KT_ATTACHMENT_…"` (always
            quote it; paths can contain spaces). Never hardcode an absolute path and never
            invent a handle that wasn't provided. Place any file you want returned to the
            caller at a write-slot variable. Do NOT ask the user to run anything manually.

            ## Accessible directories
            These directories were granted by the user. Use \(Self.listFilesToolName) to discover
            files, and reference them by label (e.g. "input_dir/filename.ext"); the runtime
            resolves labels to real paths.
            \(accessibleDirsList)

            ## File tools
            - \(Self.listFilesToolName): List files in an accessible directory by label.
            - \(Self.getFileToolName): Read a PLAIN-TEXT (UTF-8) file from the skill directory or an accessible directory. Binary files (PDF, images, .docx) are not readable this way — use \(Self.shellToolName) with a tool that extracts their text.

            ## Output handling
            stdout returned by \(Self.shellToolName) is TRUNCATED to ~\(Self.scriptOutputMaxCharacters) characters.
            When a command produces content meant for a `write` slot — a full transcript,
            generated text, processed data — redirect stdout directly to the write-slot
            path so the full content is captured regardless of length:

                python3 "$SKILL_DIR/scripts/run.py" > "$KT_…"

            Use the actual write-slot variable from the resources list below.
            Only leave stdout un-redirected for short diagnostic output you need to inspect.
            If a command already ran without redirection and output was truncated, re-run
            with redirection to the write-slot path rather than trying to reconstruct the
            content. Any file you write to the workspace is also harvested as output.

            ## Execution requirements
            - Use \(Self.shellToolName) to do the work. Never just describe a command.
            - Prefer calling the skill's own scripts (under scripts/) over writing \
            ad-hoc command lines — the scripts are pre-authored with error handling \
            and precondition checks. Invoke the entry-point script when one exists.
            - If a filename is ambiguous or uncertain, call \(Self.listFilesToolName) first to find the exact name.
            - stdout/stderr and the exit code are returned to you after each run.
            - Report results faithfully: a non-zero exit_code, or a stderr error, means the run FAILED. Never claim success or "exit code 0" unless the returned exit_code is actually 0 — if it failed, say so and quote the error.
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
