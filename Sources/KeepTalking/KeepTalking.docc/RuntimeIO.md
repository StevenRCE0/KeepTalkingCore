# Runtime I/O and Skills

How a single action run receives its inputs, declares what it may touch, executes under a sandbox, and returns what it produced.

## Overview

Every action KeepTalking executes — a skill, an MCP tool, an ACP agent, a platform
primitive — runs once, against a concrete set of files, and hands back a concrete
set of results. That whole lifecycle is one contract, centralised under
`Services/IO` so there is exactly one place where inputs are materialised, one
place where a run's reachable resources are described, and one place where
outputs are harvested and delivered back into the conversation.

The internal `KeepTalkingIOManager` owns that contract. For each call it stages
the inputs, binds the action's declared objects to real local paths, resolves a
sandbox policy, allocates output slots, and builds the run's
``KTResourceManifest``; once the executor has run it harvests whatever landed in
those slots, delivers the results, and tears the scratch state down. Its
transcript half owns the other direction: turning attachments, staged files,
voice transcripts, and produced resources into messages the model actually sees.

### The per-run I/O contract

A run begins with a ``KeepTalkingActionCallRequest``: a context, a caller node, a
target node, and a ``KeepTalkingActionCall``. The call carries three things that
shape I/O. `inputHandles` names files the caller previously staged onto the
executing node. `inputTransfers` carries one-time blobs, and is used only by the
`stage-file` preflight that delivers those bytes — real tool calls reference
staged files by handle, never by inlining them. `outputHandles` is the caller's
statement of what it expects back: each ``KeepTalkingActionOutputHandle`` has a
caller-minted id, a logical name, a `persistence` (a durable synced attachment or
a private ephemeral one-time blob), and a `multiple` flag for handles that may
resolve to zero or many files.

Because the caller mints output ids, an output can be re-fed as a later call's
input without a round trip through the user — the A→B chaining the staging store
is careful not to break.

A run is observable from outside while it happens.
``KeepTalkingActionCallActivity`` brackets a provider-side execution with a
`began` and an `ended` phase, carrying the request id, the context, the action,
and both node ids; it is delivered on the client's `onActionCallActivity`
callback, and the `ended` phase fires whether the run returned or threw. The
bracket wraps *action* execution only — the `stage-file` preflight and the
cross-node cancellation request are short-circuited before it and raise no
activity — so a host counting in-flight runs is not misled by the transport-level
traffic that surrounds them.

Binding turns the declaration into paths. ``KTCallBinding`` is the provider-side
result of resolving one action's declared objects against this run: which staged
file backs which declared input, which workspace path backs which declared
output, and which directories the sandbox must grant. It lives only on the
provider for the duration of the run and never crosses the wire — a remote caller
sees ``KeepTalkingObjectContract``, the path-free projection of a declared object,
so a compromised orchestrator prompt cannot name a provider-side path because none
is ever rendered device-side.

Output slots are allocated under the run's thread workspace before the executor
starts. Afterwards, any file present at a slot path is harvested. Attachment-kind
slots become durable context attachments; one-time-blob slots are either staged
locally (when the caller is this node) for immediate re-use, or streamed to the
remote caller as ``KeepTalkingOneTimeBlobRef`` transfers. Everything produced is
reported back on ``KeepTalkingActionCallResult`` as `producedResources`, in the
same handle vocabulary the rest of the system uses.

### KTResourceManifest: what it is, and what it is not

``KTResourceManifest`` is the per-run description handed to the executing agent.
It answers one question: *what may this run read and write?*

Each granted resource becomes an entry with a canonical handle,
`KT_<KIND>_<HEX>`. That single token is simultaneously the identifier the agent
references in prose and tool arguments, and the environment-variable key the
sandboxed shell sees as `$KT_<KIND>_<HEX>` — the same string, by construction, so
the agent's handle and the skill's variable can never drift apart. The handle
carries the full 32-hex id, which makes it globally unique and exactly reversible.

The same entry array drives both emission paths.
``KTResourceManifest/environmentVariables()`` produces the dictionary merged into
the subprocess environment; ``KTResourceManifest/promptBlock()`` produces the
agent-facing description. Two renderings, one source — they cannot diverge.

```swift
let manifest = KTResourceManifest.build(
    grantedCandidates: [
        KTResourceManifest.Candidate(
            kind: .otb,
            id: inputHandle,
            path: stagedURL,
            direction: .read,
            displayName: "quarterly.csv",
            isDirectory: false,
            objectName: "source")
    ],
    umbrellaAttachmentsDir: attachmentsDir)

let environment = manifest.environmentVariables()
let resourcesPrompt = manifest.promptBlock()
```

What the manifest is **not** is equally important. It is not a staging mechanism
and not a fetching mechanism. `build` accepts *already-granted* candidates: the
caller passes only resources whose path the sandbox actually granted, and the
manifest never re-derives reachability. Advertising stays coupled to the real
grant, so the manifest cannot promise access the sandbox will deny. It does not
copy bytes, materialise attachments, resolve handles into files, or reach out for
anything. Staging happens before the manifest exists; the manifest only describes
the outcome.

``KTResourceManifest/Kind`` names the resource family — `attachment` (durable,
synced), `otb` (private, ephemeral), `fs` (reached through filesystem operations
rather than a local path). ``KTResourceManifest/Direction`` names the data flow,
and it is deliberately mono-directional: it has only `.read` and `.write`, so a
declared in-place (`.inputOutput`) file object is bound as a single output slot
and folded to `.write` as it becomes a manifest candidate. A read-write scratch
directory — the thread workspace, an ACP working root — projects to `.write` for
the same reason.

Display names are sanitised on the way in. Control characters, line and paragraph
separators, double quotes, backticks, and dollar signs are stripped, because the
prompt block renders names inside quotes and a wire-controlled filename must not
be able to close that field and append an instruction the agent would read as
trusted manifest text.

``KTResourceManifest/AgentResource`` is the path-free, codable projection the
orchestrating agent operates on — the same vocabulary for a context attachment, a
produced output, or any manifest resource. Its identity is the handle, never a
filename and never a path: filenames repeat, and two resources with the same name
are different files.

```swift
let handle = KTResourceManifest.agentHandle(kind: .attachment, id: attachmentID)
if let resolved = KTResourceManifest.resolveAgentHandle(handle) {
    // resolved.kind == .attachment, resolved.id == attachmentID
}
```

Handle resolution is lenient on ingest and strict on presentation: the agent is
always shown `KT_…` handles, but a bare UUID still resolves.

### The staging runtime

Staging is the IO manager's input surface, and it is deliberately separate from
the manifest. It collects the context's ready blob attachments into a scratch
directory (hard-linking from the blob store, falling back to a copy), resolves the
call's staged one-time-blob handles into that same directory, tracks which scratch
directories the run owns, and removes exactly those on cleanup.

Underneath sits the staged-file store, an actor that holds files peers have
preflighted onto this node ahead of a call, keyed by opaque handle. Staging is the
acceptance point, so the store enforces the limits there: handles are
caller-scoped, time-bounded by TTL, and quota-bounded by entry count, aggregate
bytes, and bytes per caller. An over-quota stage is refused before any bytes are
decrypted, and one caller can never evict another caller's staged file.

The store distinguishes two lifetimes. An ephemeral input relay — a peer preflight,
or a file staged just ahead of one call — is consume-on-use and destroyed the first
time a call consumes it. A produced output staged for re-feeding is not: consuming
it once must not destroy it, or A→B chaining silently breaks. Those entries are
reclaimed by TTL and quota instead.

Handles also survive a hop. When a call carries `inputHandles` that resolve to
files staged on *this* node but the action runs on another, the execution layer
relays each one to the target ahead of the call and re-stages it there **under the
same handle**, so the agent's `KT_OTB_<HEX>` still equals the executor's
`$KT_OTB_<HEX>` environment key. Handles that are not local staged files — already
target-side from an earlier stage, or context-attachment handles — are left
untouched, `inputHandles` itself is never rewritten, and a relay failure is logged
rather than raised. The agent only ever holds a handle; the execution layer moves
the bytes.

Resolution failures degrade rather than fail the run. A handle that does not
resolve is logged with a diagnosis that distinguishes a local self-call (expired or
discarded) from a remote caller (the handle lives on the caller's node and was
never shipped here), and the call proceeds without that input.

### Presentation: how resources reach the model

The transcript layer is the only path by which run resources reach the model. It
renders tool-result messages, injects attachment bytes as native user messages,
serves context-resource readouts in metadata, preview-text, or native mode, renders
voice transcripts as virtual attachments, reads staged files back, and injects
produced resources into the transcript after a run.

Injected content carries the resource's identity with it, and says plainly that the
content *is* the file — so the model references the resource by handle and does not
call another tool to fetch what it already has.

Oversized resources are skipped rather than truncated, and unreadable ones are
logged and skipped; neither aborts the turn.

The README states the rule this design exists to enforce:

> Resources are emitted and collected through the IO runtime. Models should
> receive available run resources through the turn context/presentation path,
> not discover OTBs by calling extra retrieval tools. If this pipeline exposes a
> bug, fix the bug in this model rather than adding another client-side staging
> or attachment shim.

That is a maintenance rule as much as a design one. A client-side shim that
re-stages or re-fetches a resource hides the defect, duplicates the handle
vocabulary, and reintroduces exactly the divergence the single-entry-array design
removes.

### Skill lifecycle and planning

``SkillManager`` executes skill-backed actions. Registration validates the skill
directory and its manifest and caches the ``KeepTalkingSkillBundle`` by action id;
`registerIfNeeded` makes execution self-healing after a restart.

Execution runs an inner agent loop. The manager loads the skill manifest —
substituting the bundle's `{{PARAM}}` values before anything is exposed to the
model — builds the tool set, and appends the resource manifest's prompt block as a
user message so the run's `$KT_…` handles are visible. The tool set is small on
purpose: read a UTF-8 file, list a directory, and run a command line in a sandboxed
shell. Per-declared-script tools are retired; a real shell is the single execution
surface, because a genuine shell expands handles, pipes, redirections, and globs
natively.

Two things are scrubbed on the way back out. Absolute paths in the command line and
in stdout/stderr are rewritten to their stable handles — manifest paths to their
`$KT_…` keys, the workspace to `$KT_WORKSPACE`, the skill directory to `$SKILL_DIR`,
home to `~` — with both the `/var` and `/private/var` firmlink forms registered, so
a path that a symlink-resolving tool printed in the other form does not leak.
Bundle parameters are filtered out of the `KT_` namespace before injection, so an
author-supplied parameter can never shadow a generated resource key. And the last
structured `command / exit_code / stdout / stderr` block is returned alongside the
inner agent's summary, so the outer conversation shows real terminal output rather
than only prose about it.

``KeepTalkingSkillPlanner`` is the other half of the lifecycle. It determines a
skill's sandbox scope — environment variables, directories, files, network egress —
by driving a model through structured tools, and classifies the user's intent into a
primitive, a shortcut, an HTTP MCP action, or a skill. It does not enumerate
per-operation tools, because skills execute through one shell.

Planning is observable and resumable. Each ask surfaces as a
``KeepTalkingSkillPlannerEvent`` whose callback returns the user's answer: a chosen
directory, an environment value, a file, permission for an executable found on PATH,
or consent for a network host. Runtime egress and setup-time egress are separate
consents — granting one does not grant the other. The planner may also decline, and
``KeepTalkingSkillPlannerDeclineKind`` distinguishes *blocked* (it lacks permission
or information) from *too broad* (the request should be narrowed rather than built as
stated); that reason is meant to be surfaced verbatim, not treated as an error.
`plan` opens a session and `continuePlanning` resumes it with the full prior
transcript and every accumulated declaration, so the plan is revised in place and
already-granted resources are never re-requested.

### MCP and ACP bridging

``MCPManager`` bridges Model Context Protocol servers. It owns registration,
transport connection, tool discovery, and invocation, and it tracks real
availability through ``MCPActionHealth`` rather than a binary registered flag.
Concurrent connects for the same action are coalesced onto one task, so a single
OAuth consent runs instead of one per caller. Tool calls are scope-gated: an
unrestricted grant or a `.callTool` class wildcard permits every tool, otherwise
only explicitly named tools pass.

Calls wait patiently. After a grace period the manager keeps waiting as long as the
executor stays alive, polling liveness; cancelling the surrounding run resumes the
local wait with a cancellation *and* sends the MCP `notifications/cancelled`, so an
aborted agent turn actually stops the running tool.

MCP tool calls deliberately do **not** receive a per-call resource manifest. A stdio
server is launched once with a static environment and reused for every call, so
per-call resource injection does not apply — resources reach an MCP tool as tool
arguments, or through the filesystem actions.

`ACPManager` drives external Agent Client Protocol agents in the opposite
direction: KeepTalking is the *client*, and the external program is a full
autonomous coding agent spawned as a stdio JSON-RPC subprocess. It is compiled
only on macOS — `ACPManager` and `ACPManagerError` are absent from a build for any
other platform, while ``KeepTalkingACPBundle`` is not, so an ACP action can be
described and advertised anywhere and executed only on a Mac. Its containment
model is explicit and worth stating plainly — the agent runs **unsandboxed**, just
like stdio MCP. ACP enforces no containment of its own and neither does KeepTalking;
for hard isolation, run the agent in a container or VM and point the action at it.

What the granted scope does shape is *advice*. The bundle's working directory is
passed via `session/new` as the recommended root. The advertised `fs.*` capabilities
derive from the scope, so a read-only grant advertises read-only. When the agent
routes a file operation *through* KeepTalking, the KT-served `fs/read_text_file` and
`fs/write_text_file` are scope-gated and path-contained to the working root plus the
bundle's additional directories — though the agent can still touch the disk directly.
`session/request_permission` is auto-resolved against the scope by tool kind. The
working root is also advertised as a `KT_FS_<HEX>` manifest resource, so an ACP agent
sees the same handle convention a sandboxed skill does, rendered by the same code.

The prompt turn has no deadline — a coding agent may legitimately work for many
minutes — so liveness is polled instead of counting down, and a dead agent surfaces
its exit status and stderr tail rather than an opaque "transport closed".

For remote callers, an owner may attach a `remoteSystemPrompt` to the bundle. It is
injected ahead of the caller's prompt as the host operator's constraint. Local and
owner calls are unconstrained.

### The sandboxed execution model

Confinement is a protocol, ``ProcessSandboxing``, with a macOS backend today. It
compiles an action descriptor's verbs and object resources into a ``KTSandboxPolicy``
and applies that policy to a process immediately before launch. The protocol and the
policy value are cross-platform; the backend, the scope manager, and the process
runner described below are compiled only on macOS and are absent from a build for
any other platform.

`SeatbeltSandbox` is that backend. It compiles a Scheme profile and applies it by
rewriting the launch to go through `sandbox-exec`. The profile starts from
`(deny default)` and imports the low-level BSD floor that dyld and any real binary
need — without it even a trivial command aborts before running — then re-opens only
what the action declared: read and write grants per file path and per named
directory, outbound network only for hosts the `network` or `callTool` verb
opened, and process execution of the system binary directories when the `execute`
verb is present.

Granting the system binary directories is not a hole. The read and write rules still
gate what those tools can touch, network stays denied unless a verb opened it, and
Apple-event sending is never granted, so a tool like `osascript` cannot drive other
applications.

Path canonicalisation is load-bearing throughout. Grants are compiled from
`realpath`-resolved paths, because seatbelt matches the kernel-resolved form and
Foundation's symlink resolution does not collapse the `/var` → `/private/var`
firmlink. Environment values, by contrast, carry the standardized form, so they match
what the output scrubber rewrites.

`ScopeManager` sits between the executors and the backend. It holds active grants,
surfaces creation requests for user approval, and resolves the final policy at
execution time — including the variant that injects extra directories with a
per-direction grant, which is how the staged-attachments directory arrives read-only
and the thread workspace arrives read-write. If the extended policy cannot be
resolved, the run falls back to the plain policy and the workspace is dropped rather
than silently ungranted.

`SandboxedProcessRunner` is the execution primitive. It runs either an argv or a
real shell command line under the compiled policy. The patient-wait model applies
here too: it waits the grace period quietly, then waits for as long as the process
runs, polling for incremental output. Child stdout and stderr are redirected to temp
files through inherited descriptors rather than in-memory pipes, which is what makes
an unbounded wait safe — a full 64 KB pipe buffer can't deadlock it. Cancelling the
surrounding task sends SIGTERM and escalates to SIGKILL out of band, so a script that
ignores SIGTERM cannot wedge the cancellation.

```swift
let policy = try SeatbeltSandbox().compilePolicy(descriptor: descriptor)
let execution = try await SandboxedProcessRunner.runShell(
    command: "wc -l \"$KT_ATTACHMENTS\"/*.csv",
    currentDirectory: workspace,
    environment: manifest.environmentVariables(),
    actionID: actionID,
    sandboxPolicy: policy)
print(execution.exitCode, execution.stdout)
```

The argv path additionally expands `$NAME` and `${NAME}` references against the
*injected* environment only — manifest keys, `SKILL_DIR`, bundle parameters — never
the inherited parent environment, so only KeepTalking-provisioned handles resolve.
The shell path needs no such workaround, because a genuine shell does the expansion.

``KeepTalkingThreadWorkspaceManager`` owns the writable side. A workspace is
thread-scoped, not per-call: it persists across a thread's turns, which is what lets
a long-running task bridge them. It is separate from the read-only skill directory,
so a script writing a relative file can no longer pollute the installed skill, and
separate from per-call input staging, which stays the fail-closed surface cleaned
after every call. Runs are bracketed with `beginRun` and `endRun`, and sealing defers
while a run is in flight so a workspace is never deleted out from under a script
holding it as its working directory. Orphans — directories whose thread row no longer
exists — are swept selectively, never by blanket prefix delete. The workspace root
sits beside the databases rather than inside one, so it is shared by every identity
on the device: ``KeepTalkingThreadWorkspaceManager/threadIDsOnDisk()`` enumerates
every thread *anyone* has a workspace for, and reclamation narrows that maximal set
by subtracting the threads the readable identities still own — which is what lets a
deleted identity's workspaces be reclaimed without touching a surviving one's.

Stdio process launching goes through ``MCPStdioTransportLaunching``, which carries an
optional sandbox policy on the platforms where `Process` exists. Skill script
execution goes through ``SkillScriptExecuting``, whose macOS conformance is the
sandboxed shell and whose non-macOS form is empty by design — there is no
`sandbox-exec` off macOS, so the executor is simply absent and the shell tool is not
offered.

One further grant surface belongs here even though it is not a sandbox one: which
peer node may call which action, in which context, and narrowed to what
``KeepTalkingActionScope``. Those changes move as a batch.
``KeepTalkingGrantTransaction`` accumulates grant and revoke entries keyed by
(context, action, node), collapsing repeats so the last write for a key wins, and the
client applies the whole set inside one database transaction — either every entry
lands or none does. A context-scoped grant additionally stages a trust invitation
when the target peer is not trusted yet, so granting into a context is a single call
rather than a trust step followed by a grant step. `reverted()` returns the inverse
transaction, with the caveat it documents: a reverted revoke restores an
*unrestricted* grant, because the narrowed permission the original carried is not
recorded in the transaction. Pair it with that permission at the call site when the
distinction matters.

### Attachments

Attachments are the durable, synced end of the resource spectrum, and there are two
ways to introduce one.

``KeepTalkingLocalAttachmentInput`` describes a file on disk that the SDK should
ingest: a source URL, plus an optional filename and MIME type when the URL's own
values are not what should be recorded. This is the ordinary path — reading, hashing,
and registering the bytes happens for you.

```swift
try await client.send(
    "Here is the export",
    attachments: [
        KeepTalkingLocalAttachmentInput(
            sourceURL: exportURL,
            filename: "quarterly.csv",
            mimeType: "text/csv")
    ],
    in: context)
```

``KeepTalkingExistingBlobReference`` describes a blob that some other process — a
share extension, typically — has *already* written to the blob store and the blob
records table. It carries only blob identity and per-message metadata; the byte count
is recovered from the existing record. Sending with existing blobs skips the read,
hash, and upsert pass entirely, so the caller must guarantee each blob row exists and
is ready.

```swift
try await client.send(
    "Shared from the extension",
    existingBlobs: [
        KeepTalkingExistingBlobReference(
            blobID: blobID,
            filename: "scan.pdf",
            mimeType: "application/pdf")
    ],
    in: context)
```

The same shape is used on the way out: a primitive action reports its produced files
as ``KeepTalkingLocalAttachmentInput`` values, and the IO manager decides — from the
requested persistence and whether the caller is this node — whether each becomes a
durable attachment, a locally staged handle, or a streamed one-time blob.

``KeepTalkingContextAttachmentMetadata`` is the enrichment carried alongside a stored
attachment: a text preview, an image description, tags, and pixel or page dimensions.
It is what makes an attachment describable without reading its bytes. Preview text
and image descriptions feed the `summary` of an ``KTResourceManifest/AgentResource``
and the preview-text read mode, so the model can reason about an attachment's content
before deciding whether to pull the whole thing into the turn — which matters, because
native injection is capped by a byte budget and an oversized attachment is refused
rather than truncated.

## Topics

### The Per-Run Resource Manifest

- ``KTResourceManifest``
- ``KTResourceManifest/Kind``
- ``KTResourceManifest/Direction``
- ``KTResourceManifest/Candidate``
- ``KTResourceManifest/Entry``
- ``KTResourceManifest/build(grantedCandidates:umbrellaAttachmentsDir:)``
- ``KTResourceManifest/environmentVariables()``
- ``KTResourceManifest/promptBlock()``

### Resource Handles

- ``KTResourceManifest/agentHandle(kind:id:)``
- ``KTResourceManifest/parseAgentHandle(_:)``
- ``KTResourceManifest/resolveAgentHandle(_:)``
- ``KTResourceManifest/AgentResource``

### Binding Declared Objects to a Run

- ``KTCallBinding``
- ``KTCallBinding/BoundObject``
- ``KTCallBinding/GrantedDirectory``
- ``KeepTalkingObjectContract``
- ``KeepTalkingActionObject``
- ``KeepTalkingResourceDirection``

### Call Inputs and Outputs

- ``KeepTalkingActionCall``
- ``KeepTalkingActionCallRequest``
- ``KeepTalkingActionCallResult``
- ``KeepTalkingActionCallActivity``
- ``KeepTalkingActionOutputHandle``
- ``KeepTalkingOneTimeBlobRef``

### Attachments

- ``KeepTalkingLocalAttachmentInput``
- ``KeepTalkingExistingBlobReference``
- ``KeepTalkingContextAttachmentMetadata``
- ``KeepTalkingContextAttachment``
- ``KeepTalkingContextAttachmentDTO``
- ``KeepTalkingClient/send(_:attachments:in:sender:type:agentTurnID:emitLocalEnvelope:)-(_,_,UUID,_,_,_,_)``
- ``KeepTalkingClient/send(_:existingBlobs:in:sender:type:agentTurnID:emitLocalEnvelope:)-(_,_,UUID,_,_,_,_)``

### Skill Execution

- ``SkillManager``
- ``SkillManagerError``
- ``KeepTalkingSkillBundle``
- ``SkillManager/registerSkillAction(_:)``
- ``SkillManager/refreshSkillAction(_:)``
- ``SkillManager/registerIfNeeded(_:)``
- ``SkillManager/unregisterAction(actionID:)``
- ``SkillManager/listActionToolNames(action:)``

### Skill Planning

- ``KeepTalkingSkillPlanner``
- ``KeepTalkingSkillPlanner/plan(skillActionID:bundle:call:onEvent:)``
- ``KeepTalkingSkillPlanner/continuePlanning(userMessage:onEvent:)``
- ``KeepTalkingSkillPlannerEvent``
- ``KeepTalkingSkillPlannerResult``
- ``KeepTalkingSkillPlannerDeclineKind``
- ``KeepTalkingSkillPlannerError``
- ``KTSkillCommandPlan``

### MCP Bridging

- ``MCPManager``
- ``MCPManager/callAction(action:call:scope:)``
- ``MCPManager/listActionTools(action:)``
- ``MCPManager/listActionToolNames(action:)``
- ``MCPManager/actionHealth(actionID:)``
- ``MCPManager/preflightHTTPAuthentication(action:)``
- ``MCPActionHealth``
- ``MCPManagerError``
- ``KeepTalkingMCPHTTPAuthResult``
- ``KeepTalkingMCPCredentialStore``
- ``KeepTalkingMCPCredentials``

### ACP Bridging

`ACPManager`, its `callAction(action:call:scope:callerIsRemote:)` entry point, and
`ACPManagerError` exist only on macOS; the bundle that describes an ACP action is
cross-platform.

- ``KeepTalkingACPBundle``

### Sandboxing and Scope

`SeatbeltSandbox`, its `compilePolicy(descriptor:)` entry point, and `ScopeManager`
exist only on macOS.

- ``ProcessSandboxing``
- ``KTSandboxPolicy``
- ``KeepTalkingActionScope``
- ``KeepTalkingActionDescriptor``
- ``KeepTalkingActionGrant``
- ``KeepTalkingGrantTransaction``

### Process Execution and Workspaces

`SandboxedProcessRunner` and its `run`/`runShell` primitives exist only on macOS.

- ``SkillScriptExecuting``
- ``SkillScriptExecutionResult``
- ``DefaultSkillScriptExecutor``
- ``KeepTalkingThreadWorkspaceManager``
- ``KeepTalkingThreadWorkspaceManager/workspace(for:)``
- ``KeepTalkingThreadWorkspaceManager/seal(threadID:)``
- ``KeepTalkingThreadWorkspaceManager/reapOrphans(liveThreadIDs:maxAge:)``
- ``KeepTalkingThreadWorkspaceManager/threadIDsOnDisk()``
- ``MCPStdioTransportLaunching``
- ``MCPStdioTransportHandle``
- ``MCPStdioProcessHandling``
- ``DefaultMCPStdioTransportLauncher``

### Other Executors

- ``PrimitiveActionManager``
- ``PrimitiveActionManagerError``
- ``KeepTalkingPrimitiveBundle``
- ``KeepTalkingPrimitiveRegistry``
- ``FilesystemActionManager``

### JavaScript Evaluation

- ``KeepTalkingJSRuntime``
- ``KeepTalkingJSRuntime/evaluate(_:options:)``
- ``KeepTalkingJSEvaluationOptions``
- ``KeepTalkingJSEvaluationResult``
- ``KeepTalkingJSRuntimeError``
- ``KeepTalkingClient/setJSRuntime(_:)``
