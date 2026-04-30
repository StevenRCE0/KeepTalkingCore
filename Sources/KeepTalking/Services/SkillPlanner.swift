import AIProxy
import Foundation
import MCP

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
    case requiringDirectory(label: String, purpose: String)
    /// Mid-plan request for a single file. `contentTypes` is a list of UTI
    /// identifiers (e.g. "public.shell-script", "public.python-script"). Empty
    /// means any file. `purpose` is a short human-readable explanation of why
    /// the skill needs this file — the host MUST surface it on the picker so
    /// the user knows which path is being asked for.
    case requiringFile(label: String, purpose: String, contentTypes: [String])
    case requiringNetwork(host: String, purpose: String)
    case requiringHTTPURL(serviceName: String)
    case registeringScript(toolName: String, path: String)
    case suggestingScript(path: String)
    case creatingShortcut(name: String)
    case creatingPrimitive(kind: String)
    case creatingHTTPMCP(url: URL, name: String)
    case finalizing
    /// Emitted mid-turn when the agent calls `kt_create_primitive` for an
    /// action kind that declares a non-empty scope schema. The host should
    /// surface a review sheet to the user. Both payloads are compact JSON
    /// strings so the event stays Sendable and protocol-friendly.
    ///
    /// Callback return values:
    /// - `nil`: the host did not handle the event; the agent's proposed scope
    ///   is applied as-is.
    /// - JSON-object string: the user's edited scope. An empty object (`{}`)
    ///   clears the scope (action becomes unscoped).
    case proposingPrimitiveScope(
        kind: String, proposedScopeJSON: String, schemaJSON: String)
    /// Free-form clarifying question from the planner. The host should show
    /// `question` to the user (with `context` if provided) and resume with
    /// the user's typed answer, or nil if they decline to answer.
    case askingUser(question: String, context: String)
    /// Planner refused to plan because of missing permission or info. The
    /// host should surface `reason` to the user. Return value is ignored.
    case refusing(reason: String)
}

/// The outcome of a planner run: either a full skill plan or a direct primitive/shortcut/HTTP-MCP action.
public enum KeepTalkingSkillPlannerResult: Sendable {
    case plan(KTSkillCommandPlan)
    case directAction(KeepTalkingPrimitiveBundle)
    case directHTTPMCP(url: URL, name: String, indexDescription: String, headers: [String: String])
    /// Planner declined to build an action because it lacks permission or
    /// information needed to proceed. The host should surface `reason` to
    /// the user verbatim instead of treating this as an error.
    case refused(reason: String)
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
    private static let requireFileTool = "kt_require_file"
    private static let requireNetworkTool = "kt_require_network"
    private static let registerScriptTool = "kt_register_script"
    private static let suggestScriptTool = "kt_suggest_script"
    private static let createShortcutTool = "kt_create_shortcut"
    private static let createPrimitiveTool = "kt_create_primitive"
    private static let requireHTTPURLTool = "kt_require_http_url"
    private static let createHTTPMCPTool = "kt_create_http_mcp"
    private static let askUserTool = "kt_ask_user"
    private static let refuseTool = "kt_refuse"
    private static let finalizeTool = "kt_finalize"

    private static let maxTurns = 20
    private static let manifestMaxCharacters = 20_000

    private static let primitiveActionList: String = {
        KeepTalkingPrimitiveBundle.availablePrimitiveActions
            .filter { $0.action != .createAction }
            .map { primitive -> String in
                var line = "- \(primitive.action.rawValue): \(primitive.indexDescription)"
                let schema = primitive.action.scopeSchema
                if !schema.isEmpty,
                    let json = renderJSONSchema(.object(schema))
                {
                    line += "\n    scope schema: \(json)"
                    line +=
                        "\n    Propose an initial `scope` for this kind when calling kt_create_primitive — pick the narrowest values that satisfy the user's intent. The user can edit them before the action is granted."
                }
                return line
            }
            .joined(separator: "\n")
    }()

    /// Renders a JSON-shaped `AIProxyJSONValue` into a compact JSON string
    /// suitable for embedding in agent-facing prompts.
    private static func renderJSONSchema(_ value: AIProxyJSONValue) -> String? {
        func toFoundation(_ v: AIProxyJSONValue) -> Any {
            switch v {
                case .null: return NSNull()
                case .bool(let b): return b
                case .int(let i): return i
                case .double(let d): return d
                case .string(let s): return s
                case .array(let arr): return arr.map(toFoundation)
                case .object(let obj): return obj.mapValues(toFoundation)
            }
        }
        let raw = toFoundation(value)
        guard JSONSerialization.isValidJSONObject(raw),
            let data = try? JSONSerialization.data(
                withJSONObject: raw,
                options: [.sortedKeys, .withoutEscapingSlashes]),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private let skillManager: SkillManager
    /// Model identifier to send to the connector. Provider-specific (e.g.
    /// `openai/gpt-5-codex` for OpenRouter, `gpt-5-codex` for direct OpenAI).
    /// Pass the same value the rest of the agent loop uses so the planner
    /// doesn't 404 on providers that don't recognise the default.
    private let model: String

    public init(aiConnector: any AIConnector, model: String = "gpt-5-codex") {
        self.skillManager = SkillManager(aiConnector: aiConnector)
        self.model = model
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

        var messages: [AIMessage] = [
            .system(
                makeSystemPrompt(
                    bundle: bundle, isExisting: isExisting, manifest: manifest,
                    fileIndex: fileIndex, availableShortcuts: availableShortcuts)
            ),
            .user(makeUserPrompt(bundle: bundle, call: call, isExisting: isExisting)),
        ]

        let tools = makePlannerTools()

        guard let aiConnector = skillManager.aiConnector else {
            throw SkillManagerError.missingAIConnector
        }

        var commands: [KTSkillAtomicCommand] = []
        var requiredEnv: [String] = []
        var requiredDirectories: [String] = []
        var requiredFiles: [String] = []
        var requiredNetworkHosts: [String] = []
        var grantedNetworkHosts: [String] = []
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
                tools: tools,
                model: model,
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
                            "You must call kt_finalize now to complete the analysis. "
                                + "Declare any remaining tools first, then call kt_finalize with a rationale."
                        )
                    )
                    continue
                }
                break
            }

            if let assistantMsg = assistantMessage(from: turn) {
                messages.append(assistantMsg)
            }

            var toolResults: [AIMessage] = []

            for call in turn.toolCalls {
                let args = (try? await skillManager.decodeToolArguments(call.argumentsJSON)) ?? [:]
                var result: String

                switch call.name {

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
                        // Optional rich argument schema. Accept it as a JSON object
                        // (preferred — preserves nested types) or as a raw JSON string.
                        let argumentsSchema: String? = {
                            if case .object = args["arguments_schema"] ?? .null,
                                let raw = args["arguments_schema"],
                                let str = jsonString(from: raw)
                            {
                                return str
                            }
                            if case .string(let s) = args["arguments_schema"] ?? .null,
                                !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                return s
                            }
                            return nil
                        }()
                        commands.append(
                            KTSkillAtomicCommand(
                                index: commandIndex,
                                descriptor: descriptor,
                                intent: intent,
                                argumentsSchema: argumentsSchema
                            ))
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
                        let purpose = string(args["purpose"]) ?? ""
                        let providedPath = await onEvent?(
                            .requiringDirectory(label: label, purpose: purpose))
                        if !label.isEmpty && !requiredDirectories.contains(label) { requiredDirectories.append(label) }
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected directory: \(path)"
                        } else {
                            result = "Noted. User skipped — no directory granted."
                        }

                    case Self.requireFileTool:
                        let label = string(args["label"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        let contentTypes = arrayOfStrings(args["content_types"] ?? .null) ?? []
                        let providedPath = await onEvent?(
                            .requiringFile(
                                label: label, purpose: purpose, contentTypes: contentTypes))
                        if !label.isEmpty && !requiredFiles.contains(label) { requiredFiles.append(label) }
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected file: \(path)"
                        } else {
                            result = "Noted. User skipped — no file granted."
                        }

                    case Self.requireNetworkTool:
                        let host = string(args["host"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        let granted = await onEvent?(.requiringNetwork(host: host, purpose: purpose))
                        if !host.isEmpty && !requiredNetworkHosts.contains(host) {
                            requiredNetworkHosts.append(host)
                        }
                        if let granted, granted.lowercased() == "granted" {
                            if !grantedNetworkHosts.contains(host) { grantedNetworkHosts.append(host) }
                            result = "Granted. The skill may reach \(host) at runtime."
                        } else {
                            result = "User denied or skipped network access to \(host)."
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
                        let proposedScope: [String: [String]] = {
                            guard case .object(let dict)? = args["scope"] else { return [:] }
                            var out: [String: [String]] = [:]
                            for (key, value) in dict {
                                guard case .array(let entries) = value else { continue }
                                let strings: [String] = entries.compactMap {
                                    if case .string(let s) = $0 {
                                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return trimmed.isEmpty ? nil : trimmed
                                    }
                                    return nil
                                }
                                if !strings.isEmpty { out[key] = strings }
                            }
                            return out
                        }()

                        var finalScope: [String: [String]]? =
                            proposedScope.isEmpty ? nil : proposedScope
                        if !kind.scopeSchema.isEmpty {
                            let schemaJSON =
                                Self.renderJSONSchema(.object(kind.scopeSchema)) ?? "{}"
                            let proposalJSON =
                                Self.renderJSONSchema(
                                    .object(
                                        proposedScope.mapValues { entries in
                                            .array(entries.map { .string($0) })
                                        })) ?? "{}"
                            let editedJSON = await onEvent?(
                                .proposingPrimitiveScope(
                                    kind: kind.rawValue,
                                    proposedScopeJSON: proposalJSON,
                                    schemaJSON: schemaJSON
                                ))
                            if let editedJSON,
                                let data = editedJSON.data(using: .utf8),
                                let parsed = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any]
                            {
                                var resolved: [String: [String]] = [:]
                                for (key, value) in parsed {
                                    guard let arr = value as? [Any] else { continue }
                                    let strings = arr.compactMap { entry -> String? in
                                        guard let s = entry as? String else { return nil }
                                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return t.isEmpty ? nil : t
                                    }
                                    if !strings.isEmpty { resolved[key] = strings }
                                }
                                finalScope = resolved.isEmpty ? nil : resolved
                            }
                        }

                        return .directAction(
                            KeepTalkingPrimitiveBundle(
                                name: name,
                                indexDescription: desc,
                                action: kind,
                                scope: finalScope
                            ))

                    case Self.requireHTTPURLTool:
                        let serviceName = string(args["service_name"]) ?? ""
                        let providedURL = await onEvent?(.requiringHTTPURL(serviceName: serviceName))
                        if let provided = providedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !provided.isEmpty
                        {
                            // The agent often stops here and calls kt_finalize
                            // without ever creating the MCP. Spell out the
                            // required follow-up unambiguously.
                            result =
                                "User provided URL: \(provided). MANDATORY NEXT STEP: call kt_create_http_mcp now with url=\"\(provided)\" and a name + description. Do NOT call kt_finalize before kt_create_http_mcp — the action is not created until you do."
                        } else {
                            result =
                                "User did not provide a URL. Stop and call kt_finalize without creating an HTTP MCP."
                        }

                    case Self.createHTTPMCPTool:
                        let urlStr = string(args["url"]) ?? ""
                        let mcpName = string(args["name"]) ?? urlStr
                        let desc = string(args["description"]) ?? ""
                        let headers: [String: String] = {
                            guard case .object(let dict)? = args["headers"] else { return [:] }
                            var out: [String: String] = [:]
                            for (k, v) in dict {
                                if case .string(let s) = v { out[k] = s }
                            }
                            return out
                        }()
                        guard let url = URL(string: urlStr), url.scheme?.lowercased().hasPrefix("http") == true
                        else {
                            result = "Error: invalid url '\(urlStr)'."
                            break
                        }
                        _ = await onEvent?(.creatingHTTPMCP(url: url, name: mcpName))
                        return .directHTTPMCP(
                            url: url,
                            name: mcpName.isEmpty ? (url.host ?? urlStr) : mcpName,
                            indexDescription: desc,
                            headers: headers
                        )

                    case Self.askUserTool:
                        let question = string(args["question"]) ?? ""
                        let qContext = string(args["context"]) ?? ""
                        let answer = await onEvent?(
                            .askingUser(question: question, context: qContext))
                        if let answer, !answer.isEmpty {
                            result = "User answered: \(answer)"
                        } else {
                            result =
                                "User did not answer. If you cannot proceed without this information, call kt_refuse."
                        }

                    case Self.refuseTool:
                        let reason = string(args["reason"]) ?? "Planner refused."
                        _ = await onEvent?(.refusing(reason: reason))
                        return .refused(reason: reason)

                    case Self.finalizeTool:
                        rationale = string(args["rationale"]) ?? ""
                        if let n = string(args["name"]), !n.isEmpty { skillName = n }
                        _ = await onEvent?(.finalizing)
                        finalized = true
                        result = "Done."

                    default:
                        result = "Unknown tool: \(call.name)"
                }

                toolResults.append(.tool(result, toolCallID: call.id))
            }

            messages.append(contentsOf: toolResults)
            if finalized { break }
        }

        guard finalized else { throw KeepTalkingSkillPlannerError.planNotFinalized }

        // Auto-link script bindings the planner forgot to register. Models
        // frequently call kt_suggest_script + kt_declare_tool but skip the
        // kt_register_script step that pairs them — leaving the runtime
        // unable to dispatch the declared tool to its script. For each
        // execute/call-tool command whose descriptor command references a
        // known script (suggested or already on disk), synthesize a tool
        // name and stamp it. The user-facing effect is that the skill
        // actually runs the script the planner intended to wrap.
        let knownScriptPaths: Set<String> = {
            var paths = Set(suggestedScripts.keys)
            if let dir = bundle.directory {
                let scripts = SkillDirectoryDefinitions.entryURL(.scripts, in: dir)
                if let enumerator = FileManager.default.enumerator(at: scripts, includingPropertiesForKeys: nil) {
                    for case let url as URL in enumerator {
                        let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                        paths.insert(rel)
                    }
                }
            }
            return paths
        }()

        // Track scripts the planner already explicitly registered so the
        // auto-link doesn't double-bind them and create duplicate-name tool
        // entries (which fail with "tools contains duplicate names" at the
        // provider level).
        let registeredScriptPaths: Set<String> = Set(toolDeclarations.values)

        for idx in commands.indices where commands[idx].toolName == nil && commands[idx].scriptPath == nil {
            let cmd = commands[idx]
            guard let verb = cmd.descriptor.action?.verbs?.first,
                verb == .execute || verb == .callTool,
                case .command(let groups) = cmd.descriptor.object?.resource,
                let tokens = groups.first
            else { continue }
            // Find a token that names a known script path. Tokens are
            // shell-style ("bash", "scripts/foo.sh", "{{arg}}") so we just
            // look for an exact match or a basename match.
            let matchedScript = tokens.first { token in
                knownScriptPaths.contains(token)
                    || knownScriptPaths.contains { $0.hasSuffix("/" + token) || $0 == token }
            }
            guard let script = matchedScript else { continue }
            let resolvedPath = knownScriptPaths.first { $0 == script || $0.hasSuffix("/" + script) } ?? script
            // Skip if the planner already registered this script — pairing
            // happens via the `toolDeclarations` loop below.
            if registeredScriptPaths.contains(resolvedPath) { continue }
            let synthesizedName = synthesizeToolName(for: cmd, fallback: resolvedPath)
            // Avoid colliding with an already-registered tool name.
            if toolDeclarations[synthesizedName] != nil { continue }
            commands[idx].toolName = synthesizedName
            commands[idx].scriptPath = resolvedPath
            toolDeclarations[synthesizedName] = resolvedPath
        }

        // Stamp toolName/scriptPath onto commands from registered tool declarations
        for (toolName, scriptPath) in toolDeclarations {
            // Skip if any command already binds this script — the auto-link
            // pass above (or a prior iteration) handled it. Without this
            // guard, registering a script the planner already declared as an
            // atomicTool produced a duplicate command sharing the same
            // toolName, which the model provider rejects with
            // "tools contains duplicate names".
            if commands.contains(where: { $0.toolName == toolName || $0.scriptPath == scriptPath }) {
                continue
            }
            // Otherwise: find a matching unbound command by intent reference,
            // or synthesize a fresh execute command for the script.
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
            requiredFiles: requiredFiles,
            requiredNetworkHosts: requiredNetworkHosts,
            grantedNetworkHosts: grantedNetworkHosts,
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

            ## Step 1 — Check primitives, shortcuts, and HTTP MCP FIRST

            Before doing ANYTHING else, check whether the user's intent can be fulfilled by \
            a built-in primitive action, an installed macOS Shortcut, or a remote HTTP MCP server. If it can:
            - Call kt_create_primitive, kt_create_shortcut, or kt_create_http_mcp as your ONLY tool call.
            - These are terminating — do NOT call any other tools before or after.
            - Prefer primitives, then shortcuts, then HTTP MCP when more than one could apply.

            ### HTTP MCP guidance
            If the user wants to connect a remote service (e.g. "connect Linear", "add the GitHub MCP", \
            or provides an https URL), use kt_create_http_mcp:
            - If the prompt contains an https URL, use it directly.
            - If the prompt names a service whose MCP endpoint you know with high confidence, use that URL.
            - Otherwise call kt_require_http_url(service_name) to ask the user for the endpoint, then \
              call kt_create_http_mcp with the URL they provide.
            - OAuth scope selection and authentication are handled by the app — do NOT prompt for credentials.

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
            - For each external resource the skill needs from the user, choose carefully:
              * kt_require_directory — only when the skill walks or reads many files \
                under a folder (e.g. "project_root", "input_dir", "output_dir").
              * kt_require_file — when the skill targets ONE specific file (a launch \
                script, an executable, a config file, a video to process). Pass UTI \
                content_types to constrain the picker when you can.
              These are NOT interchangeable: pick the one that matches what the user \
              actually needs to point at. If a step needs both a working directory \
              AND a specific file inside (or unrelated to) it, call BOTH tools — \
              once per resource, with distinct labels.
            - For each remote host the skill must reach (HTTP APIs, etc.), call kt_require_network \
              with the bare hostname and a short purpose. The user grants access per host.
            - For each script callable as a named tool, call kt_register_script.
            - If bootstrapping a new skill, call kt_suggest_script for each file to create.
            - You are allowed to be interactive: when intent is genuinely ambiguous, \
              call kt_ask_user with a specific question and a one-sentence context. \
              Do this BEFORE making assumptions that would lock the action into the \
              wrong shape. Do not over-ask — only when the answer changes the plan.
            - You may refuse: if you lack the permission or information to build a \
              correct action (user denied a required scope, no matching primitive, \
              critical info still missing after asking), call kt_refuse with a clear \
              reason. Do not finalize a half-built plan as a fallback.
            - You MUST call kt_finalize as your final tool call when you DO produce a \
              plan. (Refusal via kt_refuse is the alternative terminal call.)
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

    private func makePlannerTools() -> [KeepTalkingActionToolDefinition] {
        [
            tool(
                name: Self.readFileTool,
                description: "Read a file within the skill directory. Use relative paths.",
                properties: ["path": (.string, "Path relative to the skill directory.")],
                required: ["path"]),

            tool(
                name: Self.declareToolTool,
                description:
                    "Declare one atomic tool/step the skill performs. For execute/call-tool steps that wrap a script with named arguments, also pass `arguments_schema` so the resulting MCP tool exposes the script's real input shape instead of a generic blob.",
                properties: [
                    "verb": (.string, "One of: read, write, execute, network, grep, ls, call-tool"),
                    "intent": (.string, "Why this step is needed."),
                    "subject_description": (.string, "Who or what performs this step (optional)."),
                    "object_description": (.string, "Human-readable description of what is accessed."),
                    "object_kind": (.string, "One of: file, url, command"),
                    "object_paths": (.array, "File paths when object_kind is 'file'."),
                    "object_urls": (.array, "URLs when object_kind is 'url'."),
                    "object_command": (.array, "Command tokens when object_kind is 'command'."),
                    "arguments_schema": (
                        .object,
                        "Optional JSON Schema (object) describing the tool's full input. When present this is used verbatim as the MCP tool's inputSchema. Use this for execute/call-tool steps that wrap a script with named arguments — e.g. {\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}."
                    ),
                ],
                required: ["verb", "intent", "object_description", "object_kind"]),

            tool(
                name: Self.requireEnvTool,
                description: "Declare an environment variable the skill needs at runtime. Use UPPER_SNAKE_CASE.",
                properties: ["name": (.string, "Environment variable name, e.g. OPENAI_API_KEY.")],
                required: ["name"]),

            tool(
                name: Self.requireDirTool,
                description:
                    "Declare an external DIRECTORY the skill needs access to. Use ONLY when the skill walks or reads many files under a folder. If the skill needs ONE specific file (a script entry point, a config file, etc.), use kt_require_file instead. ALWAYS pass a `purpose` — the user sees it on the picker.",
                properties: [
                    "label": (.string, "Short label, e.g. project_root or output_dir."),
                    "purpose": (
                        .string,
                        "One-sentence reason this directory is needed. Shown to the user on the folder picker so they know which scope is being requested."
                    ),
                ],
                required: ["label", "purpose"]),

            tool(
                name: Self.requireFileTool,
                description:
                    "Declare a single FILE the skill needs the user to point at. Prefer this over kt_require_directory whenever the skill targets one specific file (e.g. an executable launch script, a config file, a video to process). The host opens a file picker, not a folder picker. ALWAYS pass a `purpose` — the user sees it on the picker.",
                properties: [
                    "label": (.string, "Short label, e.g. entry_script or config_file."),
                    "purpose": (
                        .string,
                        "One-sentence reason this file is needed. Shown to the user on the file picker so they know what to pick."
                    ),
                    "content_types": (
                        .array,
                        "Optional list of UTI identifiers that constrain the picker (e.g. 'public.shell-script', 'public.python-script', 'public.executable', 'com.apple.applescript.text'). Omit for any file."
                    ),
                ],
                required: ["label", "purpose"]),

            tool(
                name: Self.requireNetworkTool,
                description:
                    "Request network egress to a specific host the skill needs to reach. The user grants per host.",
                properties: [
                    "host": (.string, "Hostname only, e.g. 'api.github.com'. Do not include scheme or path."),
                    "purpose": (.string, "Short reason this host is needed."),
                ],
                required: ["host", "purpose"]),

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
                description:
                    "Create a companion primitive action (built-in system capability). Some kinds accept a `scope` object that constrains what the action may touch — e.g. `access-calendar` accepts `{\"calendars\": [\"Work\", \"Personal\"]}` to limit reads/writes to those calendar titles. Omit `scope` (or pass an empty object) to leave the action unscoped.",
                properties: [
                    "action_kind": (.string, "One of the available primitive action kinds."),
                    "name": (.string, "Display name for the action."),
                    "description": (.string, "What this action does."),
                    "scope": (
                        .object,
                        "Optional kind-specific scope. Each value MUST be an array of strings. Keys depend on action_kind; for access-calendar use the key `calendars` with calendar titles."
                    ),
                ],
                required: ["action_kind", "description"]),

            tool(
                name: Self.requireHTTPURLTool,
                description:
                    "Ask the user for an HTTP MCP endpoint URL when the prompt does not include one and you do not know a well-known URL for the named service.",
                properties: [
                    "service_name": (.string, "The service the user wants to connect, e.g. 'Linear', 'GitHub'.")
                ],
                required: ["service_name"]),

            tool(
                name: Self.createHTTPMCPTool,
                description:
                    "Create an HTTP MCP action. Use when the user wants to connect a remote MCP server over HTTP. Terminating — do NOT call other tools after.",
                properties: [
                    "url": (.string, "Full https URL of the MCP endpoint."),
                    "name": (.string, "Display name (e.g. 'Linear', 'GitHub MCP')."),
                    "description": (.string, "One-sentence description of what this MCP exposes."),
                    "headers": (
                        .object,
                        "Optional fixed request headers (e.g. API tokens). OAuth is handled separately by the app."
                    ),
                ],
                required: ["url", "name", "description"]),

            tool(
                name: Self.askUserTool,
                description:
                    "Ask the user a free-form clarifying question when intent is ambiguous, when there are multiple reasonable interpretations, or when you need information that isn't covered by the other request_* tools (e.g. which of two scripts to wrap, what flag to default to). Prefer this over guessing. Do NOT use it for paths the user can pick — use kt_require_file / kt_require_directory for those.",
                properties: [
                    "question": (.string, "The question to ask the user, in plain English."),
                    "context": (
                        .string,
                        "Optional one-sentence context shown alongside the question so the user understands why you're asking."
                    ),
                ],
                required: ["question"]),

            tool(
                name: Self.refuseTool,
                description:
                    "Refuse to plan because you lack the permission or information needed to proceed safely. Use when: the user denied a required directory/file/network grant; the request asks for a capability not exposed (no matching primitive, no scriptable path); critical info is still missing after kt_ask_user. Terminating — do NOT call any other tool after.",
                properties: [
                    "reason": (
                        .string,
                        "One-paragraph explanation of what's blocking, what would unblock it, and what the user can try next. Shown verbatim."
                    )
                ],
                required: ["reason"]),

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

    private enum ParamType { case string, array, object }

    private func tool(
        name: String, description: String,
        properties: [String: (ParamType, String)],
        required: [String]
    ) -> KeepTalkingActionToolDefinition {
        let schemaProps: [String: AIProxyJSONValue] = properties.mapValues { (type, desc) in
            switch type {
                case .string:
                    return .object([
                        "type": .string("string"),
                        "description": .string(desc),
                    ])
                case .array:
                    return .object([
                        "type": .string("array"),
                        "description": .string(desc),
                        "items": .object(["type": .string("string")]),
                    ])
                case .object:
                    return .object([
                        "type": .string("object"),
                        "description": .string(desc),
                    ])
            }
        }
        let parameters: [String: AIProxyJSONValue] = [
            "type": .string("object"),
            "properties": .object(schemaProps),
            "required": .array(required.map(AIProxyJSONValue.string)),
        ]
        return .init(
            functionName: name,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: description,
            parameters: parameters
        )
    }

    // MARK: - Message helper

    private func assistantMessage(from turn: AITurnResult) -> AIMessage? {
        let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (text?.isEmpty == false)
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        guard hasText || toolCalls != nil else { return nil }
        return AIMessage(
            role: .assistant,
            content: hasText ? .text(text!) : nil,
            toolCalls: toolCalls ?? []
        )
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

    /// Derive a stable, user-readable tool name when the planner skipped
    /// `kt_register_script`. Prefer the script's basename (without extension)
    /// since that's usually a meaningful verb (`run_command_script`); fall
    /// back to slugified intent if the path is too generic.
    private func synthesizeToolName(for cmd: KTSkillAtomicCommand, fallback path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "-", with: "_")
        if !cleaned.isEmpty && cleaned != "index" && cleaned != "main" {
            return cleaned
        }
        let slug = cmd.intent
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "_")
        return slug.isEmpty ? "run_script" : slug
    }

    /// Re-encode an `MCP.Value` (which is itself JSON-compatible) into a compact
    /// JSON string. Used to capture the `arguments_schema` blob the planner LLM
    /// supplies on `kt_declare_tool` so it can be stored verbatim on the command.
    private func jsonString(from value: MCP.Value) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
