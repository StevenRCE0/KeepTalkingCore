//
//  SkillPlanner.swift
//  KeepTalking
//
//  Core of the skill planner: tool-name vocabulary, session state, and the
//  public entry points (`plan` / `continuePlanning`). The turn loop, prompts,
//  tool definitions, environment probes, and helpers live in the sibling
//  `SkillPlanner+*.swift` files.
//

import AIProxy
import Foundation

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

    static let readFileTool = "kt_read_skill_file"
    static let requireEnvTool = "kt_require_env"
    static let requireDirTool = "kt_require_directory"
    static let requireFileTool = "kt_require_file"
    static let requireNetworkTool = "kt_require_network"
    static let createShortcutTool = "kt_create_shortcut"
    static let createPrimitiveTool = "kt_create_primitive"
    static let requireHTTPURLTool = "kt_require_http_url"
    static let createHTTPMCPTool = "kt_create_http_mcp"
    static let askUserTool = "kt_ask_user"
    static let probeCommandTool = "kt_probe_command"
    static let checkPathTool = "kt_check_path"
    static let shellTool = "kt_shell"
    static let requireExecutableTool = "kt_require_executable"
    static let refuseTool = "kt_refuse"
    static let finalizeTool = "kt_finalize"

    static let maxTurns = 20
    static let manifestMaxCharacters = 20_000

    static let primitiveActionList: String = {
        KeepTalkingPrimitiveBundle.availablePrimitiveActions
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
    static func renderJSONSchema(_ value: AIProxyJSONValue) -> String? {
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

    let skillManager: SkillManager
    /// Model identifier to send to the connector. Provider-specific (e.g.
    /// `openai/gpt-5-codex` for OpenRouter, `gpt-5-codex` for direct OpenAI).
    /// Pass the same value the rest of the agent loop uses so the planner
    /// doesn't 404 on providers that don't recognise the default.
    let model: String
    /// Optional ACT agent. When set, `kt_run_action` is added to the planner's
    /// tool list and delegated to this agent, letting the planner call existing
    /// actions to gather context before finalising a skill plan.
    let actAgent: AIOrchestrator.ACTAgent?
    /// Optional web search provider, sourced from the same self-node search
    /// configuration the main agent uses (`KeepTalkingClient.webSearchProvider`).
    /// When set, the SAME `web_search` tool the main orchestrator exposes
    /// (`KeepTalkingClient.makeWebSearchTool()`) is added to the planner's
    /// tool list so it can look up current information (API docs, package
    /// names, service capabilities) while planning.
    let webSearchProvider: KeepTalkingClient.WebSearchProvider?

    /// Mutable state for the currently-open planning session. Persisted across
    /// turns on the actor so `continuePlanning` can resume the same transcript
    /// and accumulated declarations instead of starting from scratch. A fresh
    /// `plan(...)` call replaces it.
    final class PlanningRun {
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
    var run: PlanningRun?

    public init(
        aiConnector: any AIConnector,
        model: String = "gpt-5-codex",
        actAgent: AIOrchestrator.ACTAgent? = nil,
        webSearchProvider: KeepTalkingClient.WebSearchProvider? = nil
    ) {
        self.skillManager = SkillManager(aiConnector: aiConnector)
        self.model = model
        self.actAgent = actAgent
        self.webSearchProvider = webSearchProvider
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
    /// so it can revise the plan in place — declaring further steps or tools —
    /// instead of starting over. Resources
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
}
