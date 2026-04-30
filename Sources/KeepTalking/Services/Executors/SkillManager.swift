//
//  SkillManager.swift
//  KeepTalking
//
//  Created by 砚渤 on 28/02/2026.
//

import AIProxy
import Foundation
import MCP

public enum SkillManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case missingAIConnector
    case invalidSkillDirectory(URL)
    case missingSkillManifest(URL)
    case invalidToolArguments(String)
    case invalidSkillPath(String)
    case scriptExecutionUnavailableOnThisPlatform
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
            case .scriptExecutionUnavailableOnThisPlatform:
                return "Skill script execution is unavailable on this platform."
            case .toolCallTimedOut(let actionID, let timeout):
                return
                    "Timed out waiting for skill script action=\(actionID) after \(Int(timeout))s."
        }
    }
}

struct SkillManifestContext: Sendable {
    let manifestURL: URL
    let manifestText: String
    let manifestMetadata: [String: String]
    let referencesFiles: [String]
    let scripts: [String]
    let assets: [String]
    /// Tool name → script relative path, parsed from `scripts.<name>` frontmatter keys.
    /// These are the only tools the agent is allowed to call.
    let declaredTools: [String: String]
}

/// Executes skill-backed actions by exposing skill files and scripts as AI tools.
public actor SkillManager {
    static let getFileToolName = "kt_skill_get_file"
    static let listFilesToolName = "kt_skill_list_files"
    static let runScriptToolName = "kt_skill_run_script"
    static let manifestMaxCharacters = 20_000
    static let fileReadMaxCharacters = 30_000
    static let scriptOutputMaxCharacters = 18_000

    public nonisolated let aiConnector: (any AIConnector)?
    let scriptExecutor: (any SkillScriptExecuting)?
    let scriptTimeoutSeconds: TimeInterval

    private(set) public var onLog: ((String) -> Void)?
    var skillBundlesByActionID: [UUID: KeepTalkingSkillBundle] = [:]

    /// Creates a skill manager for a node runtime.
    public init(
        nodeConfig _: KeepTalkingConfig,
        aiConnector: (any AIConnector)?,
        scriptExecutor: (any SkillScriptExecuting)? =
            DefaultSkillScriptExecutor.current,
        scriptTimeoutSeconds: TimeInterval = 20
    ) {
        self.aiConnector = aiConnector
        self.scriptExecutor = scriptExecutor
        self.scriptTimeoutSeconds = scriptTimeoutSeconds
    }

    /// Creates a standalone skill manager with only an AI connector.
    /// Intended for planning and analysis tasks that do not require script execution.
    public init(aiConnector: any AIConnector) {
        self.aiConnector = aiConnector
        self.scriptExecutor = nil
        self.scriptTimeoutSeconds = 20
        self.onLog = nil
    }

    public func setLogHandler(_ handler: ((String) -> Void)?) {
        self.onLog = handler
    }

    /// Registers a skill action so it can be resolved and executed later.
    public func registerSkillAction(_ action: KeepTalkingAction) async throws {
        guard case .skill(let skillBundle) = action.payload else {
            throw SkillManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        if let directory = skillBundle.directory {
            try validateSkillDirectory(directory)
        }
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

    #if os(macOS)
    /// Executes a skill action by planning tool usage with the configured AI connector.
    ///
    /// `model` should match the active provider's model identifier (e.g.
    /// `openai/gpt-5-codex` for OpenRouter, plain `gpt-5-codex` for direct
    /// OpenAI). Defaults to `gpt-5-codex` for backward compatibility but
    /// callers routing through the SDK's `KeepTalkingClient` thread the
    /// configured model through automatically.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        sandboxPolicy: KTSandboxPolicy? = nil,
        model: String = "gpt-5-codex"
    ) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        guard let actionID = action.id else {
            throw SkillManagerError.missingActionID
        }
        guard case .skill(let skillBundle) = action.payload else {
            throw SkillManagerError.invalidAction
        }
        guard let aiConnector else {
            throw SkillManagerError.missingAIConnector
        }

        try await registerIfNeeded(action)

        var manifestContext = try loadManifestContext(
            for: skillBundle.directory,
            parameters: skillBundle.parameters
        )
        // Tool declarations come from the bundle's atomicTools (persisted in DB),
        // not from SKILL.md frontmatter parsing.
        let bundleTools = skillBundle.declaredTools
        if !bundleTools.isEmpty {
            var merged = manifestContext.declaredTools
            for (name, path) in bundleTools { merged[name] = path }
            manifestContext = SkillManifestContext(
                manifestURL: manifestContext.manifestURL,
                manifestText: manifestContext.manifestText,
                manifestMetadata: manifestContext.manifestMetadata,
                referencesFiles: manifestContext.referencesFiles,
                scripts: manifestContext.scripts,
                assets: manifestContext.assets,
                declaredTools: merged
            )
        }
        let resolvedContext = manifestContext
        let tools = makeSkillTools(context: resolvedContext)
        var messages: [AIMessage] = [
            .system(
                makeSkillSystemPrompt(
                    actionID: actionID,
                    bundle: skillBundle,
                    call: call,
                    manifestContext: resolvedContext
                )
            ),
            .user(makeSkillUserPrompt(call: call)),
        ]

        var latestAssistantText: String?
        let scriptTrace = SkillScriptTraceCollector()
        for _ in 0..<8 {
            let turn = try await aiConnector.completeTurn(
                messages: messages,
                tools: tools,
                model: model,
                toolChoice: nil,
                stage: .execution,
                toolExecutor: { [weak self] toolCalls in
                    guard let self = self else { return [] }
                    return try await self.executeSkillToolCalls(
                        toolCalls,
                        actionID: actionID,
                        skillDirectory: skillBundle.directory,
                        manifestContext: resolvedContext,
                        sandboxPolicy: sandboxPolicy,
                        scriptTrace: scriptTrace
                    )
                }
            )

            if let assistantMessage = assistantMessage(from: turn) {
                messages.append(assistantMessage)
            }
            if let assistantText = turn.assistantText,
                !assistantText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
            {
                latestAssistantText = assistantText
            }

            guard !turn.toolCalls.isEmpty else { break }

            messages.append(
                contentsOf: try await executeSkillToolCalls(
                    turn.toolCalls,
                    actionID: actionID,
                    skillDirectory: skillBundle.directory,
                    manifestContext: resolvedContext,
                    sandboxPolicy: sandboxPolicy,
                    scriptTrace: scriptTrace
                )
            )
        }

        // If a script actually ran, return its structured result block as
        // the final tool content. The outer chat's Output parser splits
        // `command:\n…\nexit_code: N\nstdout:\n…\nstderr:\n…` into the
        // collapsible parameter rows so the user sees real terminal
        // output instead of just the inner agent's prose summary.
        let summary = latestAssistantText ?? "Skill execution completed."
        let finalText: String
        if let block = scriptTrace.lastResultBlock() {
            finalText = "\(block)\n\nsummary: \(summary)"
        } else {
            finalText = summary
        }
        return (
            content: [.text(text: finalText, annotations: nil, _meta: nil)],
            isError: false
        )
    }
    #endif

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
}
