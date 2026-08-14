//
//  SkillPlanner+Tools.swift
//  KeepTalking
//
//  The tool list handed to the model each turn, plus the small schema builder
//  the definitions are written against. Platform- and capability-gated tools
//  (macOS probes/shell, `kt_run_action`, `web_search`) are appended only when
//  their backing facility is available.
//

import AIProxy
import Foundation

extension KeepTalkingSkillPlanner {

    // MARK: - Tool definitions

    func makePlannerTools() -> [KeepTalkingActionToolDefinition] {
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
                    "Declare a FIXED external DIRECTORY the skill always works in — the SAME folder on every run. Use ONLY when the skill walks or reads many files under one fixed folder. For ONE fixed file use kt_require_file instead. Do NOT use this for per-call inputs the caller supplies (those arrive under $KT_ATTACHMENTS at runtime, not via a folder picked now). ALWAYS pass a `purpose` — the user sees it on the picker.",
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
                    "Declare ONE FIXED file the skill needs the user to point at — a file that is the SAME on every run (the skill's own entry script, a config file, an executable). The host opens a file picker. Do NOT use this for the per-call data the skill processes (the document/video/text that differs each invocation) — that arrives at runtime under $KT_ATTACHMENTS and must not be pinned to one path here. ALWAYS pass a `purpose` — the user sees it on the picker.",
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
                    "Request RUNTIME network egress to a host the skill needs to reach WHEN IT EXECUTES (e.g. an API it calls every run). The user grants per host. This is distinct from setup-time network: hosts contacted only while installing dependencies go through kt_shell's `network_hosts`, not here.",
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
        if webSearchProvider != nil {
            tools.append(KeepTalkingClient.makeWebSearchTool())
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
                name: Self.shellTool,
                description:
                    "Your shell — available every turn. Run any command to BOTH inspect the machine (verify a tool works, read a file) AND provision the skill's environment (install dependencies, create a virtualenv, fetch assets). Runs unsandboxed in a login shell with the user's real PATH; captures exit code, stdout, and stderr. Setting up the environment is YOUR job — do it here before you finalize, and verify each step from the output. If a command reaches the network (a package index, a download), list those hosts in `network_hosts`: the user grants SETUP network access SEPARATELY from the skill's runtime network (kt_require_network), and a denied host blocks that command.",
                properties: [
                    "command": (
                        .string,
                        "The full shell command to run, e.g. 'uv sync', 'python3 -m venv .venv && .venv/bin/pip install -r requirements.txt', or 'uv --version'."
                    ),
                    "network_hosts": (
                        .array,
                        "Hosts this command will contact (e.g. ['pypi.org', 'files.pythonhosted.org']). Each triggers a one-time SETUP-network consent before the command runs. Omit for a purely local command."
                    ),
                    "cwd": (
                        .string,
                        "Optional working directory (absolute path). Defaults to a directory the user already granted, else a temp dir."
                    ),
                    "purpose": (
                        .string,
                        "Short reason for this command. Shown to the user on any setup-network prompt it triggers."
                    ),
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
}
