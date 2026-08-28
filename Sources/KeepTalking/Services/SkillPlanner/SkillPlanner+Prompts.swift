//
//  SkillPlanner+Prompts.swift
//  KeepTalking
//
//  Prompt construction for the planner: the system prompt (classification
//  rules, sandbox-scope contract, and the platform-gated probe/web-search
//  guidance), the opening user prompt, and the revise contract used when the
//  user sends a follow-up.
//

import Foundation

extension KeepTalkingSkillPlanner {

    // MARK: - Prompts

    func makeSystemPrompt(
        bundle: KeepTalkingSkillBundle,
        isExisting: Bool,
        manifest: String,
        fileIndex: [String: [String]],
        availableShortcuts: [String]
    ) -> String {
        func listing(_ key: String) -> String {
            let files = fileIndex[key] ?? []
            return files.isEmpty ? "<none>" : files.joined(separator: "\n")
        }

        let modeContext: String
        if isExisting {
            modeContext = """
                You are determining the SANDBOX SCOPE for an existing KeepTalking skill.
                The skill directory is at: \(bundle.directory!.path)
                Read the available files to understand what the skill does, then record the
                env vars, directories, files, and network hosts it needs to run. The skill is
                executed by an agent through a single sandboxed shell — you do NOT declare
                per-operation tools or register scripts; you define the boundary it runs inside.
                """
        } else {
            modeContext = """
                You are creating a new KeepTalking skill from a description.
                No skill directory exists yet. Determine the sandbox scope (env/dirs/files/
                network) the skill will need. The skill is executed by an agent through a single
                sandboxed shell; you define the boundary, not a tool list.
                """
        }

        // Probe tools only exist where script execution does (macOS); only then
        // do we instruct the planner to verify the environment.
        #if os(macOS)
        let probeGuidance = """

            ## You have a shell — verify and provision with it
            You have NO prior knowledge of what is installed or where, and a `kt_shell` \
            you can call EVERY turn. Use it to find out and to make things ready:
            - To check a tool is installed AND runnable inside the skill's RUNTIME \
            sandbox, prefer kt_probe_command(name) — it reports the resolved path and \
            whether it sits in the sandbox exec allowlist (/opt/homebrew/bin, \
            /usr/local/bin, the standard interpreters, or a path the user permits via \
            kt_require_executable). For anything else, just run it in kt_shell \
            (`uv --version`, `cat pyproject.toml`, `ls`).
            - If the skill needs a fixed project/working directory, call \
            kt_require_directory for the root and kt_check_path to confirm it exists.
            - If a tool is found but NOT runnable from the runtime sandbox, permit it \
            with kt_require_executable(name, path, purpose) — pass the exact path the \
            probe reported so the user just taps Allow (no file picker). If it's missing \
            entirely, install it via kt_shell, kt_ask_user where it lives, or kt_refuse. \
            Never scope in a command you have not verified can run.

            ## Setting up the environment is YOUR job — do it in the shell
            Don't just describe the setup; perform it. When the skill needs dependencies \
            installed, a virtualenv created, or assets fetched, run those commands in \
            kt_shell (e.g. `uv sync`, `python3 -m venv .venv && .venv/bin/pip install \
            -r requirements.txt`) and confirm each worked from the exit_code/stdout/stderr; \
            re-run a fixed command if it failed. Do this BEFORE you finalize, so the \
            action is ready to run the moment it's created.
            - SETUP network is a SEPARATE consent from runtime network. When a kt_shell \
            command downloads anything, pass the hosts it contacts in `network_hosts` \
            (e.g. ['pypi.org', 'files.pythonhosted.org']) — the user permits SETUP access \
            for that command. Hosts the skill calls every time it RUNS go through \
            kt_require_network instead. Don't conflate the two.

            ## Write scripts — wrap commands in atomic, narrow functions
            When creating a NEW skill, write script files into scripts/ via kt_shell \
            rather than leaving the runtime agent to improvise command lines. Each \
            script should expose small, single-purpose functions (or subcommands) that \
            do ONE thing and exit cleanly:
            - One function per operation — "validate input", "convert format", \
            "upload result" — not one monolith that does everything.
            - Each function checks its own preconditions (file exists, tool on PATH, \
            required env var set) and exits non-zero with a clear message on failure, \
            so the runtime agent sees exactly what broke.
            - Prefer a thin entry-point script (e.g. scripts/run.sh or scripts/run.py) \
            that calls the atomic functions in sequence. The runtime agent invokes \
            the entry point; the functions handle the details.
            - Keep each function short enough to read at a glance — if it scrolls, \
            split it.
            - Use the language that fits: shell for file plumbing and CLI orchestration, \
            Python/Node for anything with logic or parsing.
            After writing the scripts, run them once in kt_shell with a dry-run or \
            --help flag to confirm they parse and their dependencies are met.
            """
        #else
        let probeGuidance = ""
        #endif

        let webSearchGuidance =
            webSearchProvider != nil
            ? """


            ## Web search
            You have web_search for current information not in your training — API \
            docs, package names, service capabilities. Use it when it would materially \
            improve the plan; don't search for things you already know confidently.
            """
            : ""

        return """
            You are a KeepTalking action classifier and planner.

            ## Step 1 — Check primitives, shortcuts, and HTTP MCP FIRST

            Before doing ANYTHING else, check whether the user's intent can be fulfilled by \
            a built-in primitive action, an installed macOS Shortcut, or a remote HTTP MCP server. If it can:
            - Call kt_create_primitive, kt_create_shortcut, or kt_create_http_mcp as your ONLY tool call.
            - These are terminating — do NOT call any other tools before or after.
            - Prefer primitives, then shortcuts, then HTTP MCP when more than one could apply.

            ### HTTP MCP guidance
            If the user wants to connect a remote service (e.g. "connect Linear", "add the GitHub MCP", \
            or provides an https URL), use kt_create_http_mcp:
            - If the prompt contains an https URL, use it directly.
            - If the prompt names a service whose MCP endpoint you know with high confidence, use that URL.
            - Otherwise call kt_require_http_url(service_name) to ask the user for the endpoint, then \
              call kt_create_http_mcp with the URL they provide.
            - OAuth scope selection and authentication are handled by the app — do NOT prompt for credentials.

            Available Primitive Actions:
            \(Self.primitiveActionList)
            \(availableShortcuts.isEmpty ? "" : "\nAvailable macOS Shortcuts:\n\(availableShortcuts.joined(separator: "\n"))")

            ## Step 2 — Skill analysis (only if no primitive/shortcut matched)

            \(modeContext)

            Skill name: \(bundle.name)
            \(manifest.isEmpty ? "" : "Manifest (SKILL.md):\n\(manifest)\n")
            \(isExisting ? "Available scripts:\n\(listing("scripts"))\n\nAvailable references:\n\(listing("references"))" : "")

            Rules:
            - Do NOT output prose, explanations, or commentary. Use ONLY the provided tools.
            - Read only the files you need — typically the manifest and scripts.
            - Determine the skill's sandbox scope: what it needs to read/run/reach. You do
              NOT enumerate operations or register scripts — the skill runs in one sandboxed
              shell. Your job is to bound that shell with the env/dirs/files/network below.
            - For each env var needed at runtime (API keys, tokens), call kt_require_env.
            - DYNAMIC per-call inputs flow in at runtime — do NOT collect them now. \
              The skill is invoked by ANOTHER agent that ATTACHES the data to process \
              to each call. At runtime those inputs are staged read-only and gathered \
              under $KT_ATTACHMENTS/ (different files EVERY run); $KT_WORKSPACE is the \
              skill's writable scratch dir (its cwd) for intermediate files. So for \
              the file/content the skill OPERATES ON — the thing that differs each \
              invocation (the PDF to convert, the video to transcode, the text to \
              summarise) — do NOT call kt_require_file or kt_require_directory. \
              Pinning ONE fixed path into a reusable skill is wrong; the skill reads \
              its input from $KT_ATTACHMENTS. It returns its RESULT as TEXTUAL output \
              (what it prints / its summary) — files left in $KT_WORKSPACE are NOT \
              automatically sent back to the caller, so emit any result the caller \
              needs to stdout. Reflect that in the manifest/scripts.
            - Only collect a path at creation for a FIXED resource — one that is the \
              SAME across every run. Choose carefully:
              * kt_require_directory — a fixed folder the skill always works in (a \
                specific "project_root" it operates on every run).
              * kt_require_file — ONE fixed file the skill always uses (its own entry \
                script, a config file, an executable). Pass UTI content_types to \
                constrain the picker when you can.
              These are NOT interchangeable. If a step needs both a fixed directory \
              AND a fixed file, call BOTH — once per resource, with distinct labels. \
              If you're unsure whether an input is per-call or fixed, kt_ask_user \
              before asking the user to pick a path.
            - For each remote host the skill must reach AT RUNTIME (an API it calls \
              every time it runs), call kt_require_network with the bare hostname \
              and a short purpose. The user grants access per host. Do NOT use it \
              for hosts contacted only while installing dependencies — those go \
              through kt_shell's `network_hosts` (setup-time consent), a separate ask.
            - You are allowed to be interactive: when intent is genuinely ambiguous, \
              call kt_ask_user with a specific question and a one-sentence context. \
              Do this BEFORE making assumptions that would lock the action into the \
              wrong shape. Do not over-ask — only when the answer changes the plan.
            - You may decline with kt_refuse — do not finalize a half-built plan as \
              a fallback. Set `category`: \
              * "blocked" — the request is legitimate but you can't complete it \
                (user denied a required scope, no matching primitive, critical info \
                still missing after asking). Say what would unblock it. \
              * "too_broad" — a skill must be a narrow, dedicated task; if the \
                request only makes sense with sweeping access (read/write/exec over \
                `/`, the whole home directory, "control the entire computer"), \
                decline rather than scoping that in, and explain what a properly \
                bounded version would look like.
            - You MUST call kt_finalize as your final tool call when you DO produce a \
              plan. (Refusal via kt_refuse is the alternative terminal call.)
            - If the skill needs no special scope, still call kt_finalize explaining why.
            - Planning is a CONVERSATION. After you finalize, the user may send \
              follow-up messages to revise the scope. Everything you already \
              recorded stays in effect across turns, so on a revision only add \
              what's changing. Don't re-ask for resources the user already \
              granted. Finalize again when the revision is complete.
            \(probeGuidance)
            \(webSearchGuidance)
            """
    }

    func makeUserPrompt(
        bundle: KeepTalkingSkillBundle,
        call: KeepTalkingActionCall,
        isExisting: Bool
    ) -> String {
        let args: String
        if let data = try? JSONEncoder().encode(call.arguments),
            let json = String(data: data, encoding: .utf8), json != "{}"
        {
            args = " Arguments: \(json)"
        } else {
            args = ""
        }
        if isExisting {
            return "Analyse this skill and determine its sandbox scope.\(args)"
        }
        return "Create an action for: \(bundle.indexDescription)\(args)"
    }

    /// Wraps a free-form follow-up message from the user with the revise
    /// contract so the model updates the existing plan in place rather than
    /// rebuilding it or re-asking for resources it already has.
    func makeContinuationPrompt(_ userMessage: String) -> String {
        """
        The user wants to revise the plan you already built. Apply this request:

        \(userMessage)

        Rules for revising:
        - The scope so far (every env, directory, file, and network grant \
        you recorded) is STILL IN EFFECT. Do not re-record things that are \
        unchanged, and do not re-ask for resources the user already granted.
        - If the request needs a resource you don't have yet, use the \
        kt_require_* / kt_ask_user tools as usual.
        - When the revised plan is complete, call kt_finalize again. If the \
        request can't be satisfied, call kt_refuse.
        """
    }
}
