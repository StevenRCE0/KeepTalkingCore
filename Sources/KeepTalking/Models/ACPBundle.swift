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

    /// Non-secret environment variables for the agent subprocess.
    ///
    /// Secrets do NOT live here: an agent's env is where its API keys go, so
    /// `saveConstructedAction` relocates this into the keychain via
    /// `KeepTalkingACPCredentialStore` and persists the bundle with an empty
    /// environment — the same treatment HTTP MCP request headers get. The
    /// runtime merges the stored values back in at spawn time.
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

/// One authentication method an ACP agent advertised in its `initialize`
/// response. KeepTalking replays the chosen method's `id` on later spawns via
/// the keychain-backed `KeepTalkingACPCredentialStore`, so the owner is asked
/// once rather than once per call.
///
/// Cross-platform on purpose (like ``KeepTalkingACPBundle``): the driver that
/// negotiates auth is macOS-only, but the UI that renders a method picker is not.
public struct KeepTalkingACPAuthMethod: Sendable, Equatable, Codable, Identifiable {
    /// Opaque `AuthMethodId` — what `authenticate` takes as `methodId`.
    public var id: String
    /// Human-readable label for a picker.
    public var name: String
    /// Optional longer explanation from the agent.
    public var detail: String?
    /// `"agent"` (the default) or `"terminal"`. A terminal method asks the
    /// client to run a login command in a terminal; KeepTalking advertises no
    /// terminal capability, so it cannot drive those — see `isDrivable`.
    public var type: String

    public init(id: String, name: String, detail: String? = nil, type: String = "agent") {
        self.id = id
        self.name = name
        self.detail = detail
        self.type = type
    }

    /// Parses one `AuthMethod` object off the wire. Returns nil for a malformed
    /// entry so one bad element doesn't poison the whole advertised set.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? id
        self.detail = json["description"] as? String
        self.type = json["type"] as? String ?? "agent"
    }

    /// False for `terminal`-type methods, which require running a command in a
    /// terminal KeepTalking does not offer the agent.
    public var isDrivable: Bool { type != "terminal" }
}

/// How the owner answered an ACP authentication prompt. Mirrors
/// `KeepTalkingMCPHTTPAuthResult`, the equivalent seam on the MCP side.
public enum KeepTalkingACPAuthResult: Sendable, Equatable {
    /// Authenticate with this advertised method's `id`.
    case selected(methodID: String)
    /// Prompt dismissed without a choice.
    case cancelled
    /// Owner refused to authenticate this agent.
    case declined
}
