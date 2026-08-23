//
//  WorkspacePlanner.swift
//  KeepTalking
//
//  Core of the workspace planner: tool-name vocabulary, session state, and the
//  public entry points (`plan` / `continuePlanning`). The turn loop, tool
//  definitions, and prompts live in the sibling `WorkspacePlanner+*.swift`
//  files.
//
//  The planner decomposes a free-form user intent ("I want to track and review
//  ML papers weekly") into a `KeepTalkingWorkspacePlan`: one context, tags,
//  actions (existing / to create / expected from a ghost peer), ghost peer
//  slots, and SOP side notes. It never touches persistence — the app stores
//  the result in a `WorkspacePlanRecord` (SwiftData) and drives fulfillment.
//
//  TWO ORCHESTRATORS, deliberately separate: this planner works at the
//  COLLABORATION level — it slots actions by name but never builds one. Each
//  `.create` slot is later handed to `KeepTalkingSkillPlanner` (the Auto
//  Curate flow) as its own run, seeded with the slot's name + description.
//  Keep action-building tools (shell, probes, env/scope) out of this loop.
//

import AIProxy
import Foundation

public actor KeepTalkingWorkspacePlanner {

    // MARK: - Tool names

    static let proposeContextTool = "kt_propose_context"
    static let proposeTagsTool = "kt_propose_tags"
    static let proposeGhostPeerTool = "kt_propose_ghost_peer"
    static let useExistingActionTool = "kt_use_existing_action"
    static let proposeNewActionTool = "kt_propose_new_action"
    static let proposePeerActionTool = "kt_propose_peer_action"
    static let grantToPeerTool = "kt_grant_to_peer"
    static let proposeSideNoteTool = "kt_propose_side_note"
    static let removeTool = "kt_remove"
    static let askUserTool = "kt_ask_user"
    static let refuseTool = "kt_refuse"
    static let finalizeTool = "kt_finalize"

    static let maxTurns = 16

    let aiConnector: any AIConnector
    /// Model identifier to send to the connector — same value the rest of the
    /// agent loop uses (provider-specific naming).
    let model: String
    /// Optional web search, sourced from the same self-node configuration the
    /// main agent uses. Adds the shared `web_search` tool when set.
    let webSearchProvider: KeepTalkingClient.WebSearchProvider?

    /// Mutable state for the currently-open planning session. Persisted across
    /// turns on the actor so `continuePlanning` resumes the same transcript and
    /// accumulated plan atoms. A fresh `plan(...)` call replaces it.
    ///
    /// Atom identity is stable across revisions: re-proposing an action with
    /// the same (name, source-kind), a ghost with the same alias, or a note
    /// with the same key updates the existing atom in place, keeping its UUID —
    /// which is what lets `WorkspacePlanRecord.revise` preserve fulfillments.
    final class PlanningRun {
        let intent: String
        let existingActions: [WorkspacePlannerExistingAction]
        let existingTags: [String]
        /// Name of the existing context this plan targets; nil plans a new one.
        let targetContext: String?
        let tools: [KeepTalkingActionToolDefinition]

        var messages: [AIMessage]

        var contextName: String?
        var contextDescription: String?
        var tags: [String] = []
        var peers: [KeepTalkingWorkspacePlan.Peer] = []
        var actions: [KeepTalkingWorkspacePlan.Action] = []
        var sideNotes: [KeepTalkingWorkspacePlan.SideNoteEntry] = []
        var rationale: String?

        init(
            intent: String,
            existingActions: [WorkspacePlannerExistingAction],
            existingTags: [String],
            targetContext: String?,
            tools: [KeepTalkingActionToolDefinition],
            messages: [AIMessage]
        ) {
            self.intent = intent
            self.existingActions = existingActions
            self.existingTags = existingTags
            self.targetContext = targetContext
            self.tools = tools
            self.messages = messages
        }
    }

    /// The open planning session, if any. Replaced by `plan`, resumed by
    /// `continuePlanning`.
    var run: PlanningRun?

    public init(
        aiConnector: any AIConnector,
        model: String = "gpt-5-codex",
        webSearchProvider: KeepTalkingClient.WebSearchProvider? = nil
    ) {
        self.aiConnector = aiConnector
        self.model = model
        self.webSearchProvider = webSearchProvider
    }

    // MARK: - Public

    /// Plans a workspace from a free-form intent. `existingActions` is the
    /// caller's action inventory — the planner slots these instead of
    /// proposing duplicates. `existingTags` is the user's tag vocabulary —
    /// the planner selects from it rather than inventing labels. `onEvent`
    /// mirrors the skill planner's contract: informational events return nil;
    /// `.askingUser` awaits the typed answer.
    public func plan(
        intent: String,
        existingActions: [WorkspacePlannerExistingAction] = [],
        existingTags: [String] = [],
        targetContext: String? = nil,
        onEvent: (@Sendable (KeepTalkingWorkspacePlannerEvent) async -> String?)? = nil
    ) async throws -> KeepTalkingWorkspacePlannerResult {
        let messages: [AIMessage] = [
            .system(
                makeSystemPrompt(
                    existingActions: existingActions,
                    existingTags: existingTags,
                    targetContext: targetContext)),
            .user(makeUserPrompt(intent: intent)),
        ]
        let run = PlanningRun(
            intent: intent,
            existingActions: existingActions,
            existingTags: existingTags,
            targetContext: targetContext,
            tools: makePlannerTools(),
            messages: messages
        )
        self.run = run
        return try await drive(onEvent: onEvent)
    }

    /// Resumes the open planning session with a free-form user message. The
    /// planner sees the full prior transcript and every accumulated atom, so it
    /// revises the plan in place instead of starting over. Throws
    /// `noActiveSession` if `plan(...)` has not been called yet.
    public func continuePlanning(
        userMessage: String,
        onEvent: (@Sendable (KeepTalkingWorkspacePlannerEvent) async -> String?)? = nil
    ) async throws -> KeepTalkingWorkspacePlannerResult {
        guard let run else { throw KeepTalkingWorkspacePlannerError.noActiveSession }
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        run.messages.append(.user(makeContinuationPrompt(trimmed)))
        return try await drive(onEvent: onEvent)
    }
}
