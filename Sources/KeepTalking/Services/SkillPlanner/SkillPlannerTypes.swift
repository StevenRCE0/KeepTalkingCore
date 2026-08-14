//
//  SkillPlannerTypes.swift
//  KeepTalking
//
//  Public vocabulary of the skill planner: the errors it throws, the events it
//  emits to the host mid-plan, and the terminal result of a planning run.
//

import Foundation

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
    /// SETUP-time network ask — a `kt_shell` command needs to reach `host` while
    /// the planner provisions the environment (e.g. a package index). A SEPARATE
    /// consent from `requiringNetwork`: granting setup egress does not grant
    /// runtime egress, and vice-versa. Return "granted" to permit.
    case requiringSetupNetwork(host: String, purpose: String)
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
    /// The planner is searching the web for current information (API docs,
    /// package names, service capabilities) to inform the plan. Informational
    /// — return nil.
    case searchingWeb(query: String)
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
