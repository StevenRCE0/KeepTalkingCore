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
}

/// Executes skill-backed actions by exposing skill files and scripts as AI tools.
public actor SkillManager {
    static let getFileToolName = "kt_skill_get_file"
    static let runScriptToolName = "kt_skill_run_script"
    static let manifestMaxCharacters = 20_000
    static let fileReadMaxCharacters = 30_000
    static let scriptOutputMaxCharacters = 18_000

    let aiConnector: (any AIConnector)?
    let scriptExecutor: (any SkillScriptExecuting)?
    let scriptTimeoutSeconds: TimeInterval

    private var skillBundlesByActionID: [UUID: KeepTalkingSkillBundle] = [:]

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

    /// Registers a skill action so it can be resolved and executed later.
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
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        sandboxPolicy: KTSandboxPolicy? = nil
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

        let manifestContext = try loadManifestContext(for: skillBundle.directory)
        let allowScriptExecution = shouldAllowScriptExecution(
            call: call,
            manifestContext: manifestContext
        )
        let tools = makeSkillTools(allowScriptExecution: allowScriptExecution)
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
            .user(.init(content: .string(makeSkillUserPrompt(call: call)))),
        ]

        var latestAssistantText: String?
        for _ in 0..<8 {
            let turn = try await aiConnector.completeTurn(
                messages: messages,
                tools: OpenAIConnector.toResponseTools(tools: tools),
                model: "gpt-5-codex",
                toolChoice: nil,
                stage: .execution,
                toolExecutor: { [weak self] toolCalls in
                    guard let self = self else { return [] }
                    return try await self.executeSkillToolCalls(
                        toolCalls,
                        actionID: actionID,
                        skillDirectory: skillBundle.directory,
                        sandboxPolicy: sandboxPolicy
                    )
                }
            )

            if let assistantMessage = assistantMessage(from: turn) {
                messages.append(assistantMessage)
            }
            if let assistantText = turn.assistantText,
                !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                latestAssistantText = assistantText
            }

            guard !turn.toolCalls.isEmpty else { break }

            messages.append(
                contentsOf: try await executeSkillToolCalls(
                    turn.toolCalls,
                    actionID: actionID,
                    skillDirectory: skillBundle.directory,
                    sandboxPolicy: sandboxPolicy
                ).map { .tool($0) }
            )
        }

        let finalText = latestAssistantText ?? "Skill execution completed."
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
