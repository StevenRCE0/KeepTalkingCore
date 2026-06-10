import Foundation

/// An action backed by an external **Agent Client Protocol** (ACP) agent — a
/// coding agent (Claude Code, Gemini CLI, …) that KeepTalking spawns as a stdio
/// JSON-RPC subprocess and drives as the *client*. The inverse of MCP: the
/// external program is a full autonomous agent, and KT supervises it.
///
/// ACP enforces no sandboxing itself, and — by design — neither does KT: the
/// agent runs UNsandboxed (like stdio MCP). Containment is ADVISORY, not
/// enforced; for hard isolation run the agent in a container/VM. The granted
/// scope (`KeepTalkingActionScope`) only shapes the advice — the advertised
/// `fs.*` capabilities, the KT-served fs path-containment, and the
/// `session/request_permission` auto-policy at session time. macOS-only (like
/// stdio MCP and skills). See `ACPManager` for the full containment contract.
public struct KeepTalkingACPBundle: KeepTalkingActionBundle, Equatable {
    public var id: UUID
    public var name: String
    public var indexDescription: String

    /// Argv for the agent subprocess, run via `/usr/bin/env` (e.g.
    /// `["claude", "--acp"]`). The first element is the executable.
    public var command: [String]

    /// Environment variables for the agent subprocess.
    public var environment: [String: String]

    /// Absolute working directory. Passed to the agent via `session/new` as its
    /// recommended working root, and used as the root for KT-served `fs/*`
    /// path-containment. Advisory — it does not confine the (unsandboxed) process.
    public var cwd: URL

    /// Extra absolute directories the agent may touch, beyond `cwd`. Surfaced to
    /// the agent as the session's recommended root set (advisory).
    public var additionalDirectories: [URL]

    /// Optional extra system-prompt text the owner attaches as a *manual
    /// limitation* applied only when a REMOTE node invokes this agent (the owner's
    /// own/local calls are unconstrained). Injected as a leading instruction block
    /// ahead of the caller's prompt. Since containment is advisory, this is the
    /// owner's soft guardrail on what remote callers can make the agent do.
    public var remoteSystemPrompt: String?

    public init(
        id: UUID = UUID.v7(),
        name: String,
        indexDescription: String = "",
        command: [String] = [],
        environment: [String: String] = [:],
        cwd: URL,
        additionalDirectories: [URL] = [],
        remoteSystemPrompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.remoteSystemPrompt = remoteSystemPrompt
    }
}
