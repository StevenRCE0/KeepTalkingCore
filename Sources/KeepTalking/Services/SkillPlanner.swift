#if os(macOS)
import Foundation
import MCP
import OpenAI

public enum KeepTalkingSkillPlannerError: LocalizedError {
    case missingManifest(URL)
    case planNotFinalized

    public var errorDescription: String? {
        switch self {
            case .missingManifest(let url):
                return "Skill manifest not found: \(url.path)"
            case .planNotFinalized:
                return "Analysis did not complete — the model did not call kt_finalize."
        }
    }
}

/// A single observable event emitted by `KeepTalkingSkillPlanner` during planning.
public enum KeepTalkingSkillPlannerEvent: Sendable {
    case readingFile(path: String)
    case declaringTool(verb: String, intent: String)
    case requiringEnv(name: String)
    case requiringDirectory(label: String)
    case registeringScript(toolName: String, path: String)
    case suggestingScript(path: String)
    case creatingShortcut(name: String)
    case creatingPrimitive(kind: String)
    case finalizing
}

/// The outcome of a planner run: either a full skill plan or a direct primitive/shortcut action.
public enum KeepTalkingSkillPlannerResult: Sendable {
    case plan(KTSkillCommandPlan)
    case directAction(KeepTalkingPrimitiveBundle)
}

/// AI-driven planner that analyses a skill bundle by calling structured tools
/// to declare atomic tools, scopes, and script registrations.
///
/// The model reads skill files via `kt_read_skill_file`, then calls declaration
/// tools (`kt_declare_tool`, `kt_require_env`, etc.) to build the plan
/// incrementally. It must call `kt_finalize(rationale:)` to complete.
/// No prose output is expected or rendered.
public actor KeepTalkingSkillPlanner {

    // MARK: - Tool names

    private static let readFileTool = "kt_read_skill_file"
    private static let declareToolTool = "kt_declare_tool"
    private static let requireEnvTool = "kt_require_env"
    private static let requireDirTool = "kt_require_directory"
    private static let registerScriptTool = "kt_register_script"
    private static let suggestScriptTool = "kt_suggest_script"
    private static let createShortcutTool = "kt_create_shortcut"
    private static let createPrimitiveTool = "kt_create_primitive"
    private static let finalizeTool = "kt_finalize"

    private static let maxTurns = 20
    private static let manifestMaxCharacters = 20_000

    private static let primitiveActionList: String = {
        KeepTalkingPrimitiveBundle.availablePrimitiveActions
            .filter { $0.action != .createAction }
            .map { "- \($0.action.rawValue): \($0.indexDescription)" }
            .joined(separator: "\n")
    }()

    private let skillManager: SkillManager

    public init(aiConnector: any AIConnector) {
        self.skillManager = SkillManager(aiConnector: aiConnector)
    }

    // MARK: - Public

    /// Plans a skill action. The `onEvent` callback is async and returns an optional
    /// string — for `.requiringDirectory` it should return the selected path (or nil to skip),
    /// for `.requiringEnv` it should return the value (or nil to skip).
    /// Other events can return nil.
    public func plan(
        skillActionID: UUID? = nil,
        bundle: KeepTalkingSkillBundle,
        call: KeepTalkingActionCall,
        onEvent: (@Sendable (KeepTalkingSkillPlannerEvent) async -> String?)? = nil
    ) async throws -> KeepTalkingSkillPlannerResult {

        let isExisting = bundle.directory != nil

        let manifest: String
        if let dir = bundle.directory {
            manifest = (try? loadManifest(for: dir, applying: bundle)) ?? ""
        } else {
            manifest = ""
        }

        let fileIndex: [String: [String]] = bundle.directory.map { buildFileIndex(for: $0) } ?? [:]
        let availableShortcuts = await listMacOSShortcuts()

        var messages: [ChatQuery.ChatCompletionMessageParam] = [
            .developer(
                .init(
                    content: .textContent(
                        makeSystemPrompt(
                            bundle: bundle, isExisting: isExisting, manifest: manifest,
                            fileIndex: fileIndex, availableShortcuts: availableShortcuts)
                    ))),
            .user(.init(content: .string(makeUserPrompt(bundle: bundle, call: call, isExisting: isExisting)))),
        ]

        let tools = makePlannerTools()

        guard let aiConnector = skillManager.aiConnector else {
            throw SkillManagerError.missingAIConnector
        }

        var commands: [KTSkillAtomicCommand] = []
        var requiredEnv: [String] = []
        var requiredDirectories: [String] = []
        var toolDeclarations: [String: String] = [:]
        var suggestedScripts: [String: String] = [:]
        var collectedParameters: [String: String] = [:]
        var skillName = bundle.name
        var rationale: String?
        var commandIndex = 0
        var finalized = false

        var nudged = false
        for _ in 0..<Self.maxTurns {
            let turn = try await aiConnector.completeTurn(
                messages: messages,
                tools: OpenAIConnector.toResponseTools(tools: tools),
                model: "gpt-5-codex",
                toolChoice: nil,
                stage: .planning,
                toolExecutor: nil
            )

            if turn.toolCalls.isEmpty {
                // Model stopped calling tools — nudge it once to finalize
                if !finalized && !nudged {
                    nudged = true
                    if let assistantMsg = assistantMessage(from: turn) {
                        messages.append(assistantMsg)
                    }
                    messages.append(
                        .user(
                            .init(
                                content: .string(
                                    "You must call kt_finalize now to complete the analysis. "
                                        + "Declare any remaining tools first, then call kt_finalize with a rationale."
                                ))))
                    continue
                }
                break
            }

            if let assistantMsg = assistantMessage(from: turn) {
                messages.append(assistantMsg)
            }

            var toolResults: [ChatQuery.ChatCompletionMessageParam.ToolMessageParam] = []

            for call in turn.toolCalls {
                let args = (try? await skillManager.decodeToolArguments(call.function.arguments)) ?? [:]
                var result: String

                switch call.function.name {

                    case Self.readFileTool:
                        let path = string(args["path"]) ?? ""
                        _ = await onEvent?(.readingFile(path: path))
                        do {
                            guard let dir = bundle.directory else {
                                result = "Error: no skill directory set."
                                break
                            }
                            let normalized = await skillManager.normalizedSkillToolArguments(args)
                            result = try await skillManager.executeGetFile(normalized, skillDirectory: dir)
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }

                    case Self.declareToolTool:
                        let verbStr = string(args["verb"]) ?? "execute"
                        let intent = string(args["intent"]) ?? ""
                        _ = await onEvent?(.declaringTool(verb: verbStr, intent: intent))
                        let verb = KeepTalkingActionVerb(rawValue: verbStr) ?? .execute
                        let objectDesc = string(args["object_description"]) ?? ""
                        let objectKind = string(args["object_kind"]) ?? "command"
                        let subjectDesc = string(args["subject_description"])

                        let objectResource: KeepTalkingActionResource? = {
                            switch objectKind {
                                case "file":
                                    let paths = (args["object_paths"].flatMap { arrayOfStrings($0) } ?? [])
                                        .map { p -> URL in
                                            p.hasPrefix("/")
                                                ? URL(fileURLWithPath: p)
                                                : bundle.directory?.appendingPathComponent(p)
                                                    ?? URL(fileURLWithPath: p)
                                        }
                                    return paths.isEmpty ? nil : .filePaths(paths)
                                case "url":
                                    let urls = (args["object_urls"].flatMap { arrayOfStrings($0) } ?? [])
                                        .compactMap { URL(string: $0) }
                                    return urls.isEmpty ? nil : .urls(urls)
                                default:
                                    let cmd = args["object_command"].flatMap { arrayOfStrings($0) } ?? []
                                    return cmd.isEmpty ? nil : .command([cmd])
                            }
                        }()

                        let descriptor = KeepTalkingActionDescriptor(
                            subject: subjectDesc.map {
                                KeepTalkingActionResourceWithDescription(
                                    description: $0,
                                    resource: .command([[bundle.directory?.path ?? "/"]])
                                )
                            },
                            action: KeepTalkingActionWithDescription(description: verbStr, verbs: [verb]),
                            object: objectResource.map {
                                KeepTalkingActionResourceWithDescription(description: objectDesc, resource: $0)
                            }
                        )
                        commands.append(
                            KTSkillAtomicCommand(index: commandIndex, descriptor: descriptor, intent: intent))
                        commandIndex += 1
                        result = "Declared (index \(commandIndex - 1))."

                    case Self.requireEnvTool:
                        let name = string(args["name"]) ?? ""
                        let providedValue = await onEvent?(.requiringEnv(name: name))
                        if !name.isEmpty && !requiredEnv.contains(name) { requiredEnv.append(name) }
                        if let value = providedValue, !value.isEmpty {
                            collectedParameters[name] = value
                            result = "Noted. User provided value: \(value)"
                        } else {
                            result = "Noted. User skipped — use built-in defaults."
                        }

                    case Self.requireDirTool:
                        let label = string(args["label"]) ?? ""
                        let providedPath = await onEvent?(.requiringDirectory(label: label))
                        if !label.isEmpty && !requiredDirectories.contains(label) { requiredDirectories.append(label) }
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected directory: \(path)"
                        } else {
                            result = "Noted. User skipped — no directory granted."
                        }

                    case Self.registerScriptTool:
                        let toolName = string(args["tool_name"]) ?? ""
                        let scriptPath = string(args["script_path"]) ?? ""
                        _ = await onEvent?(.registeringScript(toolName: toolName, path: scriptPath))
                        if !toolName.isEmpty && !scriptPath.isEmpty { toolDeclarations[toolName] = scriptPath }
                        result = "Registered."

                    case Self.suggestScriptTool:
                        let path = string(args["path"]) ?? ""
                        let content = string(args["content"]) ?? ""
                        _ = await onEvent?(.suggestingScript(path: path))
                        if !path.isEmpty { suggestedScripts[path] = content }
                        result = "Recorded."

                    case Self.createShortcutTool:
                        let shortcutName = string(args["shortcut_name"]) ?? ""
                        let desc = string(args["description"]) ?? shortcutName
                        _ = await onEvent?(.creatingShortcut(name: shortcutName))
                        guard !shortcutName.isEmpty else {
                            result = "Error: shortcut_name is required."
                            break
                        }
                        return .directAction(
                            KeepTalkingPrimitiveBundle(
                                name: shortcutName,
                                indexDescription: desc,
                                action: .runMacOSShortcut,
                                shortcutName: shortcutName
                            ))

                    case Self.createPrimitiveTool:
                        let kindStr = string(args["action_kind"]) ?? ""
                        let desc = string(args["description"]) ?? kindStr
                        _ = await onEvent?(.creatingPrimitive(kind: kindStr))
                        guard let kind = KeepTalkingPrimitiveActionKind(rawValue: kindStr) else {
                            result =
                                "Error: unknown action_kind '\(kindStr)'. Valid: \(KeepTalkingPrimitiveActionKind.allCases.map(\.rawValue).joined(separator: ", "))"
                            break
                        }
                        let name = string(args["name"]) ?? kindStr
                        return .directAction(
                            KeepTalkingPrimitiveBundle(
                                name: name,
                                indexDescription: desc,
                                action: kind
                            ))

                    case Self.finalizeTool:
                        rationale = string(args["rationale"]) ?? ""
                        if let n = string(args["name"]), !n.isEmpty { skillName = n }
                        _ = await onEvent?(.finalizing)
                        finalized = true
                        result = "Done."

                    default:
                        result = "Unknown tool: \(call.function.name)"
                }

                toolResults.append(.init(content: .textContent(result), toolCallId: call.id))
            }

            messages.append(contentsOf: toolResults.map { .tool($0) })
            if finalized { break }
        }

        guard finalized else { throw KeepTalkingSkillPlannerError.planNotFinalized }

        // Stamp toolName/scriptPath onto commands from registered tool declarations
        for (toolName, scriptPath) in toolDeclarations {
            // Find a matching command by intent/script reference, or create one
            if let idx = commands.firstIndex(where: {
                $0.scriptPath == nil && $0.intent.localizedCaseInsensitiveContains(toolName)
            }) {
                commands[idx].toolName = toolName
                commands[idx].scriptPath = scriptPath
            } else {
                let cmd = KTSkillAtomicCommand(
                    index: commandIndex,
                    descriptor: KeepTalkingActionDescriptor(
                        action: KeepTalkingActionWithDescription(description: toolName, verbs: [.execute])
                    ),
                    intent: "Run \(toolName) via \(scriptPath)",
                    toolName: toolName,
                    scriptPath: scriptPath
                )
                commands.append(cmd)
                commandIndex += 1
            }
        }

        var planResult = KTSkillCommandPlan(
            skillActionID: skillActionID ?? UUID(),
            skillName: skillName,
            rationale: rationale ?? "",
            requiredEnv: requiredEnv,
            requiredDirectories: requiredDirectories,
            commands: commands
        )
        if !toolDeclarations.isEmpty { planResult.toolDeclarations = toolDeclarations }
        if !suggestedScripts.isEmpty { planResult.suggestedScripts = suggestedScripts }
        if !collectedParameters.isEmpty { planResult.collectedParameters = collectedParameters }
        return .plan(planResult)
    }

    // MARK: - Skill structure

    private func loadManifest(for directory: URL, applying bundle: KeepTalkingSkillBundle) throws -> String {
        let url = SkillDirectoryDefinitions.entryURL(.manifest, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KeepTalkingSkillPlannerError.missingManifest(url)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return String(bundle.applying(to: raw).prefix(Self.manifestMaxCharacters))
    }

    private func buildFileIndex(for directory: URL) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for entry: SkillDirectoryDefinitions.Entry in [.scripts, .references, .assets] {
            let entryURL = SkillDirectoryDefinitions.entryURL(entry, in: directory)
            index[entry.rawValue] = listRelativePaths(in: entryURL, root: directory)
        }
        return index
    }

    private func listRelativePaths(in directory: URL, root: URL) -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let rootPath = root.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                vals.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") { paths.append(String(path.dropFirst(rootPath.count + 1))) }
        }
        return paths.sorted()
    }

    // MARK: - Shortcuts listing

    private func listMacOSShortcuts() async -> [String] {
        #if os(macOS)
        await MacOSShortcuts.list()
        #else
        []
        #endif
    }

    // MARK: - Prompts

    private func makeSystemPrompt(
        bundle: KeepTalkingSkillBundle,
        isExisting: Bool,
        manifest: String,
        fileIndex: [String: [String]],
        availableShortcuts: [String]
    ) -> String {
        func listing(_ key: String) -> String {
            let files = fileIndex[key] ?? []
            return files.isEmpty ? "<none>" : files.joined(separator: "\n")
        }

        let modeContext: String
        if isExisting {
            modeContext = """
                You are registering tools for an existing KeepTalking skill.
                The skill directory is at: \(bundle.directory!.path)
                Read the available files to understand what the skill does, then declare its tools.
                """
        } else {
            modeContext = """
                You are bootstrapping a new KeepTalking skill from scratch.
                No skill directory exists yet. Use kt_suggest_script to create the necessary files,
                then declare the tools those scripts will expose.
                """
        }

        return """
            You are a KeepTalking action classifier and planner.

            ## Step 1 — Check primitives and shortcuts FIRST

            Before doing ANYTHING else, check whether the user's intent can be fulfilled by \
            a built-in primitive action or an installed macOS Shortcut. If it can:
            - Call kt_create_primitive or kt_create_shortcut as your ONLY tool call.
            - These are terminating — do NOT call any other tools before or after.
            - Prefer primitives over shortcuts when both could apply.

            Available Primitive Actions:
            \(Self.primitiveActionList)
            \(availableShortcuts.isEmpty ? "" : "\nAvailable macOS Shortcuts:\n\(availableShortcuts.joined(separator: "\n"))")

            ## Step 2 — Skill analysis (only if no primitive/shortcut matched)

            \(modeContext)

            Skill name: \(bundle.name)
            \(manifest.isEmpty ? "" : "Manifest (SKILL.md):\n\(manifest)\n")
            \(isExisting ? "Available scripts:\n\(listing("scripts"))\n\nAvailable references:\n\(listing("references"))" : "")

            Rules:
            - Do NOT output prose, explanations, or commentary. Use ONLY the provided tools.
            - Read only the files you need — typically the manifest and scripts.
            - For each distinct operation the skill performs, call kt_declare_tool.
            - For each env var needed at runtime (API keys, tokens), call kt_require_env.
            - For each external directory needed, call kt_require_directory.
            - If the skill processes or transforms files, you MUST call kt_require_directory \
            with descriptive labels like "input_dir", "output_dir", or "media_files".
            - For each script callable as a named tool, call kt_register_script.
            - If bootstrapping a new skill, call kt_suggest_script for each file to create.
            - You MUST call kt_finalize as your final tool call. The analysis is incomplete without it.
            - If there is nothing to declare (empty skill), still call kt_finalize explaining why.
            """
    }

    private func makeUserPrompt(
        bundle: KeepTalkingSkillBundle,
        call: KeepTalkingActionCall,
        isExisting: Bool
    ) -> String {
        let args: String
        if let data = try? JSONEncoder().encode(call.arguments),
            let json = String(data: data, encoding: .utf8), json != "{}"
        {
            args = " Arguments: \(json)"
        } else {
            args = ""
        }
        if isExisting {
            return "Analyse this skill and register its tools.\(args)"
        }
        return "Create an action for: \(bundle.indexDescription)\(args)"
    }

    // MARK: - Tool definitions

    private func makePlannerTools() -> [ChatQuery.ChatCompletionToolParam] {
        [
            tool(
                name: Self.readFileTool,
                description: "Read a file within the skill directory. Use relative paths.",
                properties: ["path": (.string, "Path relative to the skill directory.")],
                required: ["path"]),

            tool(
                name: Self.declareToolTool,
                description: "Declare one atomic tool/step the skill performs.",
                properties: [
                    "verb": (.string, "One of: read, write, execute, network, grep, ls, call-tool"),
                    "intent": (.string, "Why this step is needed."),
                    "subject_description": (.string, "Who or what performs this step (optional)."),
                    "object_description": (.string, "Human-readable description of what is accessed."),
                    "object_kind": (.string, "One of: file, url, command"),
                    "object_paths": (.array, "File paths when object_kind is 'file'."),
                    "object_urls": (.array, "URLs when object_kind is 'url'."),
                    "object_command": (.array, "Command tokens when object_kind is 'command'."),
                ],
                required: ["verb", "intent", "object_description", "object_kind"]),

            tool(
                name: Self.requireEnvTool,
                description: "Declare an environment variable the skill needs at runtime. Use UPPER_SNAKE_CASE.",
                properties: ["name": (.string, "Environment variable name, e.g. OPENAI_API_KEY.")],
                required: ["name"]),

            tool(
                name: Self.requireDirTool,
                description: "Declare an external directory the skill needs access to.",
                properties: ["label": (.string, "Short label, e.g. project_root or output_dir.")],
                required: ["label"]),

            tool(
                name: Self.registerScriptTool,
                description: "Register a script as a named callable tool in SKILL.md frontmatter.",
                properties: [
                    "tool_name": (.string, "Public tool name agents will use."),
                    "script_path": (.string, "Path relative to the skill directory."),
                ],
                required: ["tool_name", "script_path"]),

            tool(
                name: Self.suggestScriptTool,
                description: "Suggest a new script file to create (for bootstrapping a new skill).",
                properties: [
                    "path": (.string, "Path relative to the skill directory."),
                    "content": (.string, "Full content of the script."),
                ],
                required: ["path", "content"]),

            tool(
                name: Self.createShortcutTool,
                description: "Create a companion macOS Shortcut action. The shortcut must already exist on the system.",
                properties: [
                    "shortcut_name": (.string, "Exact name of the macOS Shortcut to run."),
                    "description": (.string, "What this shortcut does."),
                ],
                required: ["shortcut_name", "description"]),

            tool(
                name: Self.createPrimitiveTool,
                description: "Create a companion primitive action (built-in system capability).",
                properties: [
                    "action_kind": (.string, "One of the available primitive action kinds."),
                    "name": (.string, "Display name for the action."),
                    "description": (.string, "What this action does."),
                ],
                required: ["action_kind", "description"]),

            tool(
                name: Self.finalizeTool,
                description: "Finalize the analysis. MUST be called once all tools and scopes are declared.",
                properties: [
                    "name": (
                        .string,
                        "Short, descriptive skill name (e.g. 'FFmpeg Video Converter', 'PDF Merger'). Do NOT use the user's prompt as the name."
                    ),
                    "rationale": (.string, "One-sentence explanation of what this skill does."),
                ],
                required: ["name", "rationale"]),
        ]
    }

    // MARK: - Tool builder

    private enum ParamType { case string, array }

    private func tool(
        name: String, description: String,
        properties: [String: (ParamType, String)],
        required: [String]
    ) -> ChatQuery.ChatCompletionToolParam {
        let schemaProps = properties.mapValues { (type, desc) -> JSONSchema in
            switch type {
                case .string: return JSONSchema(.type(.string), .description(desc))
                case .array: return JSONSchema(.type(.array), .description(desc), .items(JSONSchema(.type(.string))))
            }
        }
        return ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: name, description: description,
                parameters: JSONSchema(.type(.object), .properties(schemaProps), .required(required)),
                strict: false
            )
        )
    }

    // MARK: - Message helper

    private func assistantMessage(from turn: AITurnResult) -> ChatQuery.ChatCompletionMessageParam? {
        let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let content: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? =
            text.flatMap { $0.isEmpty ? nil : .textContent($0) }
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        guard content != nil || toolCalls != nil else { return nil }
        return .assistant(.init(content: content, toolCalls: toolCalls))
    }

    // MARK: - MCP.Value helpers

    private func string(_ value: MCP.Value?) -> String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    private func arrayOfStrings(_ value: MCP.Value) -> [String]? {
        guard case .array(let arr) = value else { return nil }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
#endif
