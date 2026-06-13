import AIProxy
import Foundation
import MCP

public enum KeepTalkingSkillPlannerError: LocalizedError {
    case missingManifest(URL)
    case planNotFinalized
    case noActiveSession

    public var errorDescription: String? {
        switch self {
            case .missingManifest(let url):
                return "Skill manifest not found: \(url.path)"
            case .planNotFinalized:
                return "Analysis did not complete — the model did not call kt_finalize."
            case .noActiveSession:
                return
                    "No planning session is open. Call plan(...) before continuePlanning(...)."
        }
    }
}

/// Why the planner declined to build an action. The planner categorises its own
/// decline when it calls `kt_refuse`; the host frames the message accordingly.
public enum KeepTalkingSkillPlannerDeclineKind: String, Sendable {
    /// Blocked: the request is legitimate but the planner lacks the permission or
    /// information to complete it (a denied grant, missing info after asking).
    case blocked
    /// Too broad: the request demands access too broad or inappropriate for a
    /// narrow, dedicated skill — it should not be built as stated.
    case tooBroad = "too_broad"

    /// Maps the free-form `category` argument the model supplies to a known kind,
    /// defaulting to `.blocked` for anything unrecognised.
    public init(rawCategory: String?) {
        switch rawCategory?.lowercased() {
            case "too_broad", "toobroad", "too-broad", "broad", "reject", "rejected", "overbroad":
                self = .tooBroad
            default:
                self = .blocked
        }
    }
}

/// A single observable event emitted by `KeepTalkingSkillPlanner` during planning.
public enum KeepTalkingSkillPlannerEvent: Sendable {
    case readingFile(path: String)
    case requiringEnv(name: String)
    case requiringDirectory(label: String, purpose: String)
    /// Mid-plan request for a single file. `contentTypes` is a list of UTI
    /// identifiers (e.g. "public.shell-script", "public.python-script"). Empty
    /// means any file. `purpose` is a short human-readable explanation of why
    /// the skill needs this file — the host MUST surface it on the picker so
    /// the user knows which path is being asked for.
    case requiringFile(label: String, purpose: String, contentTypes: [String])
    /// Mid-plan request to permit running a system executable the planner found
    /// on PATH (via `kt_probe_command`) but that sits outside the sandbox exec
    /// allowlist. `path` is the resolved absolute path the probe reported, so
    /// the host shows an Allow/Deny prompt for that known path rather than a
    /// file picker. Return "granted" to permit; anything else (or nil) denies.
    case requiringExecutable(name: String, path: String, purpose: String)
    /// RUNTIME network ask — the skill needs egress to `host` when it executes.
    case requiringNetwork(host: String, purpose: String)
    /// SETUP-time network ask — the planner's `setup_environment` step needs to
    /// reach `host` while provisioning the environment (e.g. a package index).
    /// A SEPARATE consent from `requiringNetwork`: granting setup egress does
    /// not grant runtime egress, and vice-versa. Return "granted" to permit.
    case requiringSetupNetwork(host: String, purpose: String)
    /// The planner ran a `setup_environment` command to provision the env.
    /// `summary` is a short activity line (e.g. "exit 0"); `detail` carries the
    /// command. Informational — return nil.
    case settingUpEnvironment(summary: String, detail: String)
    case requiringHTTPURL(serviceName: String)
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
    /// The planner is inspecting the runtime environment — checking whether a
    /// command is on PATH, stat'ing a path, or dry-running a candidate command.
    /// `summary` is a short human description; `detail` is the finding (e.g.
    /// "uv 0.4.18 at /opt/homebrew/bin/uv"). Informational — return nil.
    case probing(summary: String, detail: String)
    /// Planner declined to plan. `category` distinguishes "blocked" (missing
    /// permission/info) from "too broad" (the request demands inappropriate
    /// access for a dedicated skill). The host surfaces `reason` to the user and
    /// can frame it by category. Return value is ignored.
    case refusing(reason: String, category: KeepTalkingSkillPlannerDeclineKind)
}

/// The outcome of a planner run: either a full skill plan or a direct primitive/shortcut/HTTP-MCP action.
public enum KeepTalkingSkillPlannerResult: Sendable {
    case plan(KTSkillCommandPlan)
    case directAction(KeepTalkingPrimitiveBundle)
    case directHTTPMCP(url: URL, name: String, indexDescription: String, headers: [String: String])
    /// Planner declined to build an action. `category` says whether it was
    /// blocked (lacks permission/info — supply what's missing) or the request was
    /// too broad (should be narrowed, not built as stated). Surface `reason`
    /// verbatim instead of treating this as an error.
    case refused(reason: String, category: KeepTalkingSkillPlannerDeclineKind)
}

/// AI-driven planner that determines a skill's SANDBOX SCOPE (env, directories,
/// files, network egress) by calling structured tools — and classifies the user's
/// intent into a primitive / shortcut / HTTP-MCP / skill action. It does NOT
/// enumerate per-operation tools: skills execute through one sandboxed shell.
///
/// The model reads skill files via `kt_read_skill_file`, then calls scope tools
/// (`kt_require_env`, `kt_require_directory`, `kt_require_network`, …) to build the
/// plan incrementally. It must call `kt_finalize(rationale:)` to complete.
/// No prose output is expected or rendered.
public actor KeepTalkingSkillPlanner {

    // MARK: - Tool names

    private static let readFileTool = "kt_read_skill_file"
    private static let requireEnvTool = "kt_require_env"
    private static let requireDirTool = "kt_require_directory"
    private static let requireFileTool = "kt_require_file"
    private static let requireNetworkTool = "kt_require_network"
    private static let createShortcutTool = "kt_create_shortcut"
    private static let createPrimitiveTool = "kt_create_primitive"
    private static let requireHTTPURLTool = "kt_require_http_url"
    private static let createHTTPMCPTool = "kt_create_http_mcp"
    private static let askUserTool = "kt_ask_user"
    static let probeCommandTool = "kt_probe_command"
    static let checkPathTool = "kt_check_path"
    static let tryRunTool = "kt_try_run"
    static let setupEnvironmentTool = "setup_environment"
    private static let requireExecutableTool = "kt_require_executable"
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
    /// Optional ACT agent. When set, `kt_run_action` is added to the planner's
    /// tool list and delegated to this agent, letting the planner call existing
    /// actions to gather context before finalising a skill plan.
    private let actAgent: AIOrchestrator.ACTAgent?

    /// Mutable state for the currently-open planning session. Persisted across
    /// turns on the actor so `continuePlanning` can resume the same transcript
    /// and accumulated declarations instead of starting from scratch. A fresh
    /// `plan(...)` call replaces it.
    private final class PlanningRun {
        // Static per-session config
        let bundle: KeepTalkingSkillBundle
        let skillActionID: UUID
        let tools: [KeepTalkingActionToolDefinition]

        // Conversation transcript (system + user + assistant + tool messages)
        var messages: [AIMessage]

        // Accumulated sandbox scope / grants
        var requiredEnv: [String] = []
        var requiredDirectories: [String] = []
        var requiredFiles: [String] = []
        var requiredNetworkHosts: [String] = []
        var grantedNetworkHosts: [String] = []
        var setupNetworkHosts: [String] = []
        var grantedSetupNetworkHosts: [String] = []
        var collectedParameters: [String: String] = [:]
        var skillName: String
        var rationale: String?

        init(
            bundle: KeepTalkingSkillBundle,
            skillActionID: UUID,
            tools: [KeepTalkingActionToolDefinition],
            messages: [AIMessage]
        ) {
            self.bundle = bundle
            self.skillActionID = skillActionID
            self.tools = tools
            self.messages = messages
            self.skillName = bundle.name
        }
    }

    /// The open planning session, if any. Replaced by `plan`, resumed by
    /// `continuePlanning`.
    private var run: PlanningRun?

    public init(
        aiConnector: any AIConnector,
        model: String = "gpt-5-codex",
        actAgent: AIOrchestrator.ACTAgent? = nil
    ) {
        self.skillManager = SkillManager(aiConnector: aiConnector)
        self.model = model
        self.actAgent = actAgent
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

        let messages: [AIMessage] = [
            .system(
                makeSystemPrompt(
                    bundle: bundle, isExisting: isExisting, manifest: manifest,
                    fileIndex: fileIndex, availableShortcuts: availableShortcuts)
            ),
            .user(makeUserPrompt(bundle: bundle, call: call, isExisting: isExisting)),
        ]

        let run = PlanningRun(
            bundle: bundle,
            skillActionID: skillActionID ?? UUID(),
            tools: makePlannerTools(),
            messages: messages
        )
        self.run = run
        return try await drive(onEvent: onEvent)
    }

    /// Resumes the open planning session with a free-form user message. The
    /// planner sees the full prior transcript and every accumulated declaration,
    /// so it can revise the plan in place — add steps, change tools, or drop
    /// now-wrong steps via `kt_drop_tool` — instead of starting over. Resources
    /// the user already granted are not re-requested. Throws `noActiveSession`
    /// if `plan(...)` has not been called yet.
    public func continuePlanning(
        userMessage: String,
        onEvent: (@Sendable (KeepTalkingSkillPlannerEvent) async -> String?)? = nil
    ) async throws -> KeepTalkingSkillPlannerResult {
        guard let run else { throw KeepTalkingSkillPlannerError.noActiveSession }
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        run.messages.append(.user(makeContinuationPrompt(trimmed)))
        return try await drive(onEvent: onEvent)
    }

    /// Runs the model/tool loop on the open session until it terminates
    /// (finalize, refuse, or a direct action). Loads accumulated state from the
    /// run, then persists it back before returning a `.plan` result so a later
    /// `continuePlanning` builds on it rather than starting fresh.
    ///
    /// Assumes serial use — the host gates new turns on the previous one
    /// completing (the action-creation UI disables its composer while planning).
    private func drive(
        onEvent: (@Sendable (KeepTalkingSkillPlannerEvent) async -> String?)?
    ) async throws -> KeepTalkingSkillPlannerResult {
        guard let run else { throw KeepTalkingSkillPlannerError.noActiveSession }
        guard let aiConnector = skillManager.aiConnector else {
            throw SkillManagerError.missingAIConnector
        }
        let bundle = run.bundle
        let tools = run.tools

        var messages = run.messages
        var requiredEnv = run.requiredEnv
        var requiredDirectories = run.requiredDirectories
        var requiredFiles = run.requiredFiles
        var requiredNetworkHosts = run.requiredNetworkHosts
        var grantedNetworkHosts = run.grantedNetworkHosts
        var setupNetworkHosts = run.setupNetworkHosts
        var grantedSetupNetworkHosts = run.grantedSetupNetworkHosts
        var collectedParameters = run.collectedParameters
        var skillName = run.skillName
        var rationale = run.rationale
        var finalized = false

        // Writes the working state back onto the session so the next
        // continuePlanning turn resumes from here. Called on every terminal
        // path that can be continued (a finalized plan, or a refusal the user
        // may argue with).
        func persist() {
            run.messages = messages
            run.requiredEnv = requiredEnv
            run.requiredDirectories = requiredDirectories
            run.requiredFiles = requiredFiles
            run.requiredNetworkHosts = requiredNetworkHosts
            run.grantedNetworkHosts = grantedNetworkHosts
            run.setupNetworkHosts = setupNetworkHosts
            run.grantedSetupNetworkHosts = grantedSetupNetworkHosts
            run.collectedParameters = collectedParameters
            run.skillName = skillName
            run.rationale = rationale
        }

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
                                + "Record any remaining required env/dirs/files/network first, "
                                + "then call kt_finalize with a rationale."
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

                    case Self.requireEnvTool:
                        let name = string(args["name"]) ?? ""
                        if !name.isEmpty && !requiredEnv.contains(name) { requiredEnv.append(name) }
                        if let existing = collectedParameters[name], !existing.isEmpty {
                            // Already supplied earlier this session — don't re-prompt on revise.
                            result = "Already provided earlier: \(existing)"
                            break
                        }
                        let providedValue = await onEvent?(.requiringEnv(name: name))
                        if let value = providedValue, !value.isEmpty {
                            collectedParameters[name] = value
                            result = "Noted. User provided value: \(value)"
                        } else {
                            result = "Noted. User skipped — use built-in defaults."
                        }

                    case Self.requireDirTool:
                        let label = string(args["label"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        if !label.isEmpty && !requiredDirectories.contains(label) { requiredDirectories.append(label) }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier: \(existing)"
                            break
                        }
                        let providedPath = await onEvent?(
                            .requiringDirectory(label: label, purpose: purpose))
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
                        if !label.isEmpty && !requiredFiles.contains(label) { requiredFiles.append(label) }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier: \(existing)"
                            break
                        }
                        let providedPath = await onEvent?(
                            .requiringFile(
                                label: label, purpose: purpose, contentTypes: contentTypes))
                        if let path = providedPath, !path.isEmpty {
                            collectedParameters[label] = path
                            result = "Noted. User selected file: \(path)"
                        } else {
                            result = "Noted. User skipped — no file granted."
                        }

                    case Self.requireExecutableTool:
                        let name = string(args["name"]) ?? ""
                        let path = string(args["path"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        let label = name.isEmpty ? path : name
                        guard path.hasPrefix("/") else {
                            result =
                                "Error: kt_require_executable needs the absolute `path` that kt_probe_command reported."
                            break
                        }
                        // Store the grant exactly like kt_require_file so it flows
                        // to the runtime exec allowlist identically — ScopeResolver
                        // maps a requiredFiles-keyed absolute-path parameter to a
                        // [.read, .execute] resource. The only difference is the
                        // path comes from the probe (Allow/Deny), not a picker.
                        if !label.isEmpty && !requiredFiles.contains(label) {
                            requiredFiles.append(label)
                        }
                        if let existing = collectedParameters[label], !existing.isEmpty {
                            result = "Already granted earlier. The skill may run \(existing)."
                            break
                        }
                        let execGranted = await onEvent?(
                            .requiringExecutable(name: label, path: path, purpose: purpose))
                        if let execGranted, execGranted.lowercased() == "granted" {
                            collectedParameters[label] = path
                            result = "Granted. The skill may run \(label) at \(path) at runtime."
                        } else {
                            result =
                                "User denied — \(label) stays unrunnable. Pick another tool or kt_refuse."
                        }

                    case Self.requireNetworkTool:
                        let host = string(args["host"]) ?? ""
                        let purpose = string(args["purpose"]) ?? ""
                        if !host.isEmpty && !requiredNetworkHosts.contains(host) {
                            requiredNetworkHosts.append(host)
                        }
                        if grantedNetworkHosts.contains(host) {
                            result = "Already granted earlier. The skill may reach \(host)."
                            break
                        }
                        let granted = await onEvent?(.requiringNetwork(host: host, purpose: purpose))
                        if let granted, granted.lowercased() == "granted" {
                            if !grantedNetworkHosts.contains(host) { grantedNetworkHosts.append(host) }
                            result = "Granted. The skill may reach \(host) at runtime."
                        } else {
                            result = "User denied or skipped network access to \(host)."
                        }

                    #if os(macOS)
                        case Self.probeCommandTool:
                            let name = (string(args["name"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let grantedRoots = collectedParameters.values.filter { $0.hasPrefix("/") }
                            let probe = await probeCommand(name, grantedRoots: Array(grantedRoots))
                            _ = await onEvent?(.probing(summary: "Probe \(name)", detail: probe.summary))
                            result = probe.toolResult

                        case Self.checkPathTool:
                            let path = (string(args["path"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let info = checkPath(path)
                            _ = await onEvent?(.probing(summary: "Check \(path)", detail: info.summary))
                            result = info.toolResult

                        case Self.tryRunTool:
                            let command = string(args["command"]) ?? ""
                            let cwd = string(args["cwd"])
                            let outcome = await tryRun(command: command, cwd: cwd)
                            _ = await onEvent?(.probing(summary: "Run: \(command)", detail: outcome.summary))
                            result = outcome.toolResult

                        case Self.setupEnvironmentTool:
                            let command = (string(args["command"]) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let purpose = string(args["purpose"]) ?? ""
                            let cwd = string(args["cwd"])
                            let hosts =
                                (arrayOfStrings(args["network_hosts"] ?? .null) ?? [])
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            guard !command.isEmpty else {
                                result = "Error: setup_environment needs a non-empty `command`."
                                break
                            }
                            // Setup-time network is a SEPARATE consent from runtime
                            // network: ask for each declared host BEFORE running the
                            // provisioning command. A denied host blocks the run — the
                            // user did not consent to reaching it during setup.
                            var deniedSetupHost: String?
                            for host in hosts {
                                if !setupNetworkHosts.contains(host) { setupNetworkHosts.append(host) }
                                if grantedSetupNetworkHosts.contains(host) { continue }
                                let granted = await onEvent?(
                                    .requiringSetupNetwork(host: host, purpose: purpose))
                                if let granted, granted.lowercased() == "granted" {
                                    grantedSetupNetworkHosts.append(host)
                                } else {
                                    deniedSetupHost = host
                                    break
                                }
                            }
                            if let deniedSetupHost {
                                result =
                                    "User denied setup network access to \(deniedSetupHost). The setup "
                                    + "command was NOT run. Try an approach that doesn't reach "
                                    + "\(deniedSetupHost), or decline with kt_refuse (category \"blocked\")."
                                break
                            }
                            // Default cwd to a granted directory when the agent didn't
                            // pass one, so installs land in the project the user pointed at.
                            let grantedDir =
                                requiredDirectories
                                .compactMap { collectedParameters[$0] }
                                .first(where: { $0.hasPrefix("/") })
                            let outcome = await runSetup(command: command, cwd: cwd ?? grantedDir)
                            _ = await onEvent?(
                                .settingUpEnvironment(summary: outcome.summary, detail: command))
                            result = outcome.toolResult
                    #endif

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
                        let reason = string(args["reason"]) ?? "Planner declined."
                        let category = KeepTalkingSkillPlannerDeclineKind(
                            rawCategory: string(args["category"]))
                        _ = await onEvent?(.refusing(reason: reason, category: category))
                        // Flush this turn's tool results (the decline included) so
                        // the transcript stays valid — every tool call needs a
                        // matching result — if the user argues back next turn.
                        toolResults.append(.tool("Declined.", toolCallID: call.id))
                        messages.append(contentsOf: toolResults)
                        persist()
                        return .refused(reason: reason, category: category)

                    case Self.finalizeTool:
                        rationale = string(args["rationale"]) ?? ""
                        if let n = string(args["name"]), !n.isEmpty { skillName = n }
                        _ = await onEvent?(.finalizing)
                        finalized = true
                        result = "Done."

                    case KeepTalkingClient.runActionToolFunctionName:
                        if let actAgent {
                            let executions = try await actAgent.execute([call], model)
                            for exec in executions {
                                toolResults.append(contentsOf: exec.messages)
                            }
                            continue
                        }
                        result = "{\"ok\":false,\"error\":\"act_not_configured\"}"

                    default:
                        result = "Unknown tool: \(call.name)"
                }

                toolResults.append(.tool(result, toolCallID: call.id))
            }

            messages.append(contentsOf: toolResults)
            if finalized { break }
        }

        guard finalized else { throw KeepTalkingSkillPlannerError.planNotFinalized }

        // Persist the (possibly revised) session state so a later
        // continuePlanning resumes from here instead of re-deriving it.
        persist()

        // The plan is the skill's SANDBOX RESOURCE — its scope (env/dirs/files/
        // network) and collected parameters. No per-operation command list: skills
        // execute via kt_shell, and the seatbelt boundary comes from this scope.
        var planResult = KTSkillCommandPlan(
            skillActionID: run.skillActionID,
            skillName: skillName,
            rationale: rationale ?? "",
            requiredEnv: requiredEnv,
            requiredDirectories: requiredDirectories,
            requiredFiles: requiredFiles,
            requiredNetworkHosts: requiredNetworkHosts,
            grantedNetworkHosts: grantedNetworkHosts,
            setupNetworkHosts: setupNetworkHosts,
            grantedSetupNetworkHosts: grantedSetupNetworkHosts
        )
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
                You are determining the SANDBOX SCOPE for an existing KeepTalking skill.
                The skill directory is at: \(bundle.directory!.path)
                Read the available files to understand what the skill does, then record the
                env vars, directories, files, and network hosts it needs to run. The skill is
                executed by an agent through a single sandboxed shell — you do NOT declare
                per-operation tools or register scripts; you define the boundary it runs inside.
                """
        } else {
            modeContext = """
                You are creating a new KeepTalking skill from a description.
                No skill directory exists yet. Determine the sandbox scope (env/dirs/files/
                network) the skill will need. The skill is executed by an agent through a single
                sandboxed shell; you define the boundary, not a tool list.
                """
        }

        // Probe tools only exist where script execution does (macOS); only then
        // do we instruct the planner to verify the environment.
        #if os(macOS)
        let probeGuidance = """

            ## Verify before you scope — assume nothing about this machine
            You have NO prior knowledge of what is installed or where. Before relying on \
            any external command-line tool (uv, ffmpeg, node, etc.):
            - Call kt_probe_command(name) to confirm it is installed AND runnable inside \
            the skill's runtime sandbox. The sandbox only executes tools under \
            /opt/homebrew/bin, /usr/local/bin, the standard interpreters, or a path the \
            user permits via kt_require_executable.
            - If the skill needs a project or working directory (e.g. a uv / npm project), \
            call kt_require_directory for the root and kt_check_path to confirm it exists.
            - Use kt_try_run for a safe, read-only smoke check (e.g. `uv --version`, \
            `uv tree`) to confirm the actual invocation works.
            - If a tool is found but NOT runnable from the sandbox, permit it with \
            kt_require_executable(name, path, purpose) — pass the exact path the probe \
            reported so the user just taps Allow (no file picker). If it's missing \
            entirely, kt_ask_user where it lives or kt_refuse with the install command. \
            Never scope in a command you have not verified can run.

            ## Set up the environment — you own provisioning
            You are responsible for getting the skill's environment ready, not just \
            describing it. When the skill needs dependencies installed, a virtualenv \
            created, or assets fetched:
            - Call setup_environment(command, …) to actually run the provisioning step \
            (e.g. `uv sync`, `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`). \
            Verify it worked from the returned exit_code/stdout/stderr; re-run a fixed \
            command if it failed.
            - Network during setup is a SEPARATE consent from runtime network. If a \
            setup command downloads anything, pass the hosts it contacts in \
            `network_hosts` (e.g. ['pypi.org', 'files.pythonhosted.org']) — the user \
            permits SETUP access once. Hosts the skill calls every time it RUNS go \
            through kt_require_network instead. Don't conflate the two.
            - Do setup BEFORE you finalize, so the action is ready to run the moment \
            it's created.
            """
        #else
        let probeGuidance = ""
        #endif

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
            - Determine the skill's sandbox scope: what it needs to read/run/reach. You do
              NOT enumerate operations or register scripts — the skill runs in one sandboxed
              shell. Your job is to bound that shell with the env/dirs/files/network below.
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
            - For each remote host the skill must reach AT RUNTIME (an API it calls \
              every time it runs), call kt_require_network with the bare hostname \
              and a short purpose. The user grants access per host. Do NOT use it \
              for hosts contacted only while installing dependencies — those belong \
              to setup_environment's setup-time network, a separate consent.
            - You are allowed to be interactive: when intent is genuinely ambiguous, \
              call kt_ask_user with a specific question and a one-sentence context. \
              Do this BEFORE making assumptions that would lock the action into the \
              wrong shape. Do not over-ask — only when the answer changes the plan.
            - You may decline with kt_refuse — do not finalize a half-built plan as \
              a fallback. Set `category`: \
              * "blocked" — the request is legitimate but you can't complete it \
                (user denied a required scope, no matching primitive, critical info \
                still missing after asking). Say what would unblock it. \
              * "too_broad" — a skill must be a narrow, dedicated task; if the \
                request only makes sense with sweeping access (read/write/exec over \
                `/`, the whole home directory, "control the entire computer"), \
                decline rather than scoping that in, and explain what a properly \
                bounded version would look like.
            - You MUST call kt_finalize as your final tool call when you DO produce a \
              plan. (Refusal via kt_refuse is the alternative terminal call.)
            - If the skill needs no special scope, still call kt_finalize explaining why.
            - Planning is a CONVERSATION. After you finalize, the user may send \
              follow-up messages to revise the scope. Everything you already \
              recorded stays in effect across turns, so on a revision only add \
              what's changing. Don't re-ask for resources the user already \
              granted. Finalize again when the revision is complete.
            \(probeGuidance)
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
            return "Analyse this skill and determine its sandbox scope.\(args)"
        }
        return "Create an action for: \(bundle.indexDescription)\(args)"
    }

    /// Wraps a free-form follow-up message from the user with the revise
    /// contract so the model updates the existing plan in place rather than
    /// rebuilding it or re-asking for resources it already has.
    private func makeContinuationPrompt(_ userMessage: String) -> String {
        """
        The user wants to revise the plan you already built. Apply this request:

        \(userMessage)

        Rules for revising:
        - The scope so far (every env, directory, file, and network grant \
        you recorded) is STILL IN EFFECT. Do not re-record things that are \
        unchanged, and do not re-ask for resources the user already granted.
        - If the request needs a resource you don't have yet, use the \
        kt_require_* / kt_ask_user tools as usual.
        - When the revised plan is complete, call kt_finalize again. If the \
        request can't be satisfied, call kt_refuse.
        """
    }

    // MARK: - Tool definitions

    private func makePlannerTools() -> [KeepTalkingActionToolDefinition] {
        var tools: [KeepTalkingActionToolDefinition] = [
            tool(
                name: Self.readFileTool,
                description: "Read a file within the skill directory. Use relative paths.",
                properties: ["path": (.string, "Path relative to the skill directory.")],
                required: ["path"]),

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
                    "Request RUNTIME network egress to a host the skill needs to reach WHEN IT EXECUTES (e.g. an API it calls every run). The user grants per host. This is distinct from setup_environment's network: hosts contacted only while installing dependencies belong to setup_environment, not here.",
                properties: [
                    "host": (.string, "Hostname only, e.g. 'api.github.com'. Do not include scheme or path."),
                    "purpose": (.string, "Short reason the skill reaches this host at runtime."),
                ],
                required: ["host", "purpose"]),

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
                    "Decline to build the action. Set `category` to say WHY: \"blocked\" — the request is legitimate but you can't complete it (user denied a required directory/file/network grant, a capability isn't exposed, critical info still missing after kt_ask_user); or \"too_broad\" — the request demands access too broad or inappropriate for a narrow, dedicated skill (read/write/exec over `/` or the whole home directory, \"control the entire computer\"), so it should not be built as stated. Terminating — do NOT call any other tool after.",
                properties: [
                    "category": (
                        .string,
                        "Why you're declining: \"blocked\" (lack permission/info to proceed) or \"too_broad\" (request demands inappropriately broad access for a dedicated skill). Defaults to \"blocked\"."
                    ),
                    "reason": (
                        .string,
                        "One-paragraph explanation shown verbatim. For \"blocked\": what's blocking, what would unblock it, what to try next. For \"too_broad\": why the access is too broad and what a narrower, acceptable version would scope to."
                    ),
                ],
                required: ["reason"]),

            tool(
                name: Self.finalizeTool,
                description: "Finalize the analysis. MUST be called once the sandbox scope is determined.",
                properties: [
                    "name": (
                        .string,
                        "Short, descriptive skill name (e.g. 'FFmpeg Video Converter', 'PDF Merger'). Do NOT use the user's prompt as the name."
                    ),
                    "rationale": (.string, "One-sentence explanation of what this skill does."),
                ],
                required: ["name", "rationale"]),
        ]
        #if os(macOS)
        // Environment-probing tools let the planner verify the runtime instead
        // of declaring on faith — only available where script execution is.
        tools.append(contentsOf: makeProbeTools())
        tools.append(
            tool(
                name: Self.setupEnvironmentTool,
                description:
                    "Provision the skill's runtime environment by running a shell command (install dependencies, create a virtualenv, fetch a model, etc.). Runs in a login shell with the user's real PATH. If the command needs to reach the network during setup (a package index, a download), list those hosts in `network_hosts` — the user is asked to permit SETUP network access SEPARATELY from runtime network (kt_require_network). A denied setup host blocks the run. Use this to prepare the environment BEFORE you finalize; verify it worked via the returned exit_code/stdout/stderr.",
                properties: [
                    "command": (
                        .string,
                        "The shell command to run, e.g. 'uv sync' or 'python3 -m venv .venv && .venv/bin/pip install -r requirements.txt'."
                    ),
                    "network_hosts": (
                        .array,
                        "Hosts this setup step will contact (e.g. ['pypi.org', 'files.pythonhosted.org']). Each triggers a one-time SETUP-network consent. Omit for a purely local setup step."
                    ),
                    "cwd": (
                        .string,
                        "Optional working directory (absolute path). Defaults to a directory the user already granted, else a temp dir."
                    ),
                    "purpose": (
                        .string,
                        "Short reason for this setup step. Shown to the user on any setup-network prompt it triggers."
                    ),
                ],
                required: ["command"]))
        tools.append(
            tool(
                name: Self.requireExecutableTool,
                description:
                    "Permit the skill to run a system executable that kt_probe_command found on PATH but reported as runnable_in_skill_sandbox: false. Pass the exact `path` the probe resolved — the host shows the user a one-tap Allow/Deny prompt for that path (NOT a file picker; the path is already known). Use this for executables on PATH; reserve kt_require_file for files the user must locate themselves (config files, videos, scripts not on PATH).",
                properties: [
                    "name": (.string, "The command name, e.g. 'screencapture'. Used as the grant label."),
                    "path": (
                        .string,
                        "Absolute path the probe resolved, e.g. '/usr/sbin/screencapture'. Must start with '/'."
                    ),
                    "purpose": (
                        .string,
                        "One-sentence reason the skill needs to run it. Shown to the user on the Allow/Deny prompt."
                    ),
                ],
                required: ["name", "path", "purpose"]))
        #endif
        if actAgent != nil {
            tools.append(KeepTalkingClient.makeRunActionTool())
        }
        return tools
    }

    #if os(macOS)
    private func makeProbeTools() -> [KeepTalkingActionToolDefinition] {
        [
            tool(
                name: Self.probeCommandTool,
                description:
                    "Check whether a command-line tool is installed and runnable BEFORE you declare a step that uses it. Runs `command -v <name>` and `<name> --version` in a login shell, then reports the resolved path, version, and whether it is runnable inside the skill's runtime sandbox. The sandbox only allows executing tools under /opt/homebrew/bin, /usr/local/bin, the standard interpreters, or a path the user explicitly permits. If a tool is found on PATH but not runnable, permit it with kt_require_executable (pass the reported path).",
                properties: [
                    "name": (.string, "The command to look for, e.g. 'uv', 'ffmpeg', 'node'. Bare name only.")
                ],
                required: ["name"]),

            tool(
                name: Self.checkPathTool,
                description:
                    "Stat an absolute path to confirm it exists before relying on it — reports whether it exists, is a directory or file, and whether it is readable/executable. Use this to validate a project root or entry script the user pointed at.",
                properties: [
                    "path": (.string, "Absolute filesystem path to check.")
                ],
                required: ["path"]),

            tool(
                name: Self.tryRunTool,
                description:
                    "Dry-run a candidate command to verify it actually works before declaring it as a tool — captures exit code, stdout, and stderr. Runs unsandboxed in a login shell with a short timeout, so use ONLY safe, read-only smoke checks (e.g. `uv --version`, `uv tree`, `ffmpeg -version`), never anything that mutates state. Prefer this over assuming a command line is correct.",
                properties: [
                    "command": (.string, "The full shell command to run, e.g. 'uv run python -V'."),
                    "cwd": (.string, "Optional working directory (absolute path). Defaults to a temp dir."),
                ],
                required: ["command"]),
        ]
    }
    #endif

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

    /// Re-encode an `MCP.Value` (which is itself JSON-compatible) into a compact
    /// JSON string. Used to capture kind-specific scope blobs (e.g. the primitive
    /// `scope` object) verbatim.
    private func jsonString(from value: MCP.Value) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
