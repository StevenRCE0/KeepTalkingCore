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

    /// Per-session agent settings, keyed by the agent's own `configOption` ids —
    /// `model`, `effort`, `fast`, `mode`, … for the Claude agent; other agents
    /// name theirs differently, which is why this is an open map rather than
    /// named fields. Applied via `session/set_config_option` right after
    /// `session/new`, before the prompt turn.
    ///
    /// Optional on purpose: a non-optional addition would fail to decode for
    /// every ACP action saved before this field existed, and `UndecodableActionSweep`
    /// deletes rows that stop decoding.
    public var configOptions: [String: String]?

    public init(
        id: UUID = UUID.v7(),
        name: String,
        indexDescription: String = "",
        command: [String] = [],
        environment: [String: String] = [:],
        cwd: URL,
        additionalDirectories: [URL] = [],
        remoteSystemPrompt: String? = nil,
        configOptions: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.remoteSystemPrompt = remoteSystemPrompt
        self.configOptions = configOptions
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

/// One setting an ACP agent exposes for a session — the shape `session/new`
/// returns in `configOptions` and `session/set_config_option` echoes back.
///
/// The Claude agent advertises `model`, `effort`, `fast`, `mode` and `agent`;
/// the ids and their legal values are the agent's own vocabulary, not ACP's, so
/// KeepTalking stores and renders whatever it is told rather than hardcoding a
/// model list that goes stale on the agent's next release.
public struct KeepTalkingACPConfigOption: Sendable, Equatable, Codable, Identifiable {
    /// One selectable value for a `select`-typed option.
    public struct Choice: Sendable, Equatable, Codable, Identifiable {
        public var id: String { value }
        public var value: String
        public var name: String
        public var detail: String?

        public init(value: String, name: String, detail: String? = nil) {
            self.value = value
            self.name = name
            self.detail = detail
        }

        init?(json: [String: Any]) {
            guard let value = json["value"] as? String else { return nil }
            self.value = value
            self.name = json["name"] as? String ?? value
            self.detail = json["description"] as? String
        }
    }

    public var id: String
    public var name: String
    public var detail: String?
    /// Agent-declared grouping (`model`, `thought_level`, `mode`, …). Advisory.
    public var category: String?
    /// `select`, `boolean`, … — only `select` is rendered as a picker today.
    public var type: String
    public var currentValue: String?
    public var choices: [Choice]

    public init(
        id: String,
        name: String,
        detail: String? = nil,
        category: String? = nil,
        type: String = "select",
        currentValue: String? = nil,
        choices: [Choice] = []
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.choices = choices
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? id
        self.detail = json["description"] as? String
        self.category = json["category"] as? String
        self.type = json["type"] as? String ?? "select"
        // `currentValue` is a string for select options; a boolean option carries
        // a Bool, which is normalised so one map type covers both.
        if let text = json["currentValue"] as? String {
            self.currentValue = text
        } else if let flag = json["currentValue"] as? Bool {
            self.currentValue = flag ? "true" : "false"
        } else {
            self.currentValue = nil
        }
        self.choices = (json["options"] as? [[String: Any]] ?? []).compactMap(Choice.init(json:))
    }
}

/// One piece of mid-turn feedback from a collaborating ACP agent.
///
/// The agent streams these over `session/update` while it works. They are NOT
/// tool-invocation traces: a collaborating agent's reasoning, plan and actions
/// are substantive output, so KeepTalking publishes them as
/// `KeepTalkingContextMessage.MessageType.thinking` rows under the agent's own
/// name rather than folding them into a parent tool row.
public struct KeepTalkingACPUpdate: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `agent_thought_chunk` — the agent's reasoning, coalesced.
        case thought
        /// `plan` — the agent's task list, re-sent whenever it changes.
        case plan
        /// `tool_call` — the agent started doing something.
        case toolCall
        /// `tool_call_update` reporting a failure.
        case toolFailure
    }

    public var kind: Kind
    /// The human-readable label: prose for a thought, a checklist for a plan,
    /// the tool's label ("Terminal", "Edit") for a tool call.
    public var text: String
    /// The tool's input, flattened. Carried separately from `text` because a
    /// command line or a file path is the caller's and the executor's business
    /// alone — published as an `.intermediate` row's sealed parameters rather
    /// than as message text everyone in the context can read. Empty for prose.
    public var parameters: [String: String]

    public init(kind: Kind, text: String, parameters: [String: String] = [:]) {
        self.kind = kind
        self.text = text
        self.parameters = parameters
    }
}

/// What a preflight learned about an agent: how it wants to be authenticated and
/// what it lets a session configure.
public struct KeepTalkingACPAgentProbe: Sendable, Equatable {
    public var authMethods: [KeepTalkingACPAuthMethod]
    /// Empty when the agent refused to open the probe session (it may still work
    /// for a real call, where authentication can be negotiated against a saved
    /// action) — the form falls back to editing settings as plain text.
    public var configOptions: [KeepTalkingACPConfigOption]

    public init(
        authMethods: [KeepTalkingACPAuthMethod] = [],
        configOptions: [KeepTalkingACPConfigOption] = []
    ) {
        self.authMethods = authMethods
        self.configOptions = configOptions
    }
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
