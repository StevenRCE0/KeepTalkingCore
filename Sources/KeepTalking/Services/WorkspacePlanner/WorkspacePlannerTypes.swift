//
//  WorkspacePlannerTypes.swift
//  KeepTalking
//
//  Public vocabulary of the workspace planner: the errors it throws, the
//  events it emits to the host mid-plan, and the terminal result of a run.
//

import Foundation

public enum KeepTalkingWorkspacePlannerError: LocalizedError {
    case planNotFinalized
    case noActiveSession

    public var errorDescription: String? {
        switch self {
            case .planNotFinalized:
                return "Planning did not complete — the model did not call kt_finalize."
            case .noActiveSession:
                return
                    "No planning session is open. Call plan(...) before continuePlanning(...)."
        }
    }
}

/// A single observable event emitted by `KeepTalkingWorkspacePlanner` while it
/// decomposes the user's intent. All events are informational (return nil)
/// except `.askingUser`, which awaits the user's typed answer.
public enum KeepTalkingWorkspacePlannerEvent: Sendable {
    /// The planner proposed the workspace's context.
    case proposingContext(name: String)
    /// The planner proposed tags for the context.
    case proposingTags(tags: [String])
    /// The planner opened a ghost peer slot — a role alias with expected
    /// capabilities, not a real node.
    case proposingGhostPeer(alias: String)
    /// The planner slotted an action. `kind` distinguishes "existing" /
    /// "create" / "peer" for the host's card rendering.
    case proposingAction(name: String, kind: String)
    /// The planner granted a local action to a ghost peer.
    case grantingAction(name: String, toPeer: String)
    /// The planner attached an SOP side note.
    case proposingSideNote(key: String)
    /// Free-form clarifying question. The host should surface `question` (with
    /// `context` if provided) and resume with the user's typed answer, or nil
    /// if they decline to answer.
    case askingUser(question: String, context: String)
    /// The planner is searching the web for current information. Informational.
    case searchingWeb(query: String)
    /// Planner declined to plan. Reuses the skill planner's decline taxonomy.
    case refusing(reason: String, category: KeepTalkingSkillPlannerDeclineKind)
    case finalizing
}

/// The outcome of a workspace planner run.
public enum KeepTalkingWorkspacePlannerResult: Sendable {
    case plan(KeepTalkingWorkspacePlan)
    /// Planner declined. Surface `reason` verbatim; `category` says whether it
    /// was blocked (missing info) or the request was too broad.
    case refused(reason: String, category: KeepTalkingSkillPlannerDeclineKind)
}

/// One row of the caller's action inventory, handed to the planner so it can
/// slot existing actions instead of proposing duplicates.
public struct WorkspacePlannerExistingAction: Sendable {
    public var id: UUID
    public var name: String
    public var indexDescription: String

    public init(id: UUID, name: String, indexDescription: String) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
    }
}
