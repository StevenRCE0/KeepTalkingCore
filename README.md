# KeepTalking SDK

Swift package providing the core engine for KeepTalking — a distributed AI conversation platform with an iroh-based P2P transport, semantic threading, multi-provider AI, MCP-based skill execution, and sandboxed script running.

## Products

| Product | Kind | Description |
|---|---|---|
| `KeepTalkingSDK` | library | Core SDK consumed by `KeepTalkingApp` and any other host |
| `KeepTalking` | executable | Development CLI for testing SDK features, MCP tools, and skills |

## Platforms

iOS 17.5+, macOS 14.5+, visionOS 1+ — swift-tools-version 6.1, built with the Swift 6.3.2 toolchain (`.swift-version`). The iOS and macOS floors are those of the vendored iroh library; visionOS builds without a transport.

## Architecture

```
Sources/KeepTalking/
├── Client.swift                    # KeepTalkingClient — main SDK entry point
├── FluentManager.swift             # Fluent database handle + connection lifecycle
├── ClientControllers/              # 35 files, one `extension KeepTalkingClient` per concern:
│                                   #   messaging, pagination, threads, workspaces, mappings,
│                                   #   nodes/aliases, action call/cancel/catalog, sealed params,
│                                   #   agent-turn continuation, context & transcript sync,
│                                   #   maintenance, trust, blobs/OTB, outbox, push wake,
│                                   #   staged files, side notes, semantic memory, voice, AI
├── Models/                         # Fluent models + the value types that travel with them
│   ├── KeepTalkingContextMessage   # Raw conversation history rows
│   ├── KeepTalkingThread           # Conversation segment — live tail, or frozen at a turning point
│   ├── KeepTalkingContext          # Conversation container
│   ├── KeepTalkingNode             # P2P node identity
│   ├── KeepTalkingAction           # Distributed function call + grants/ACLs
│   ├── KeepTalkingMapping          # Alias/tag mappings onto node/context/thread/action
│   ├── KeepTalkingSideNote         # Replicated per-context notes (counter+writer versioned)
│   └── KeepTalkingOutboxEntry      # "Existence is retry" send ledger
├── Services/
│   ├── AIConnectors/               # LLM provider abstraction layer
│   │   ├── AIConnector.swift       # Protocol — completeTurn(messages:tools:...)
│   │   ├── AIMessage.swift         # KT-native message IR (multimodal)
│   │   ├── OpenAIConnector.swift   # OpenRouter + OpenAI + custom endpoints
│   │   ├── AnthropicConnector.swift # Anthropic Messages API
│   │   ├── MetaTools/              # Agent-facing built-in tools (attachments, JS eval, semantic search)
│   │   ├── *WebSearchTool.swift    # OpenAI + OpenRouter provider-native web search
│   │   └── *WebSearchBackend.swift # Standalone backend protocol + Exa implementation
│   ├── Orchestrators/              # Multi-agent orchestration
│   │   ├── MainAgent.swift         # AIOrchestrator — primary conversation loop
│   │   ├── ACTAgent.swift          # ACT sub-agent — resolve/call/distil behind one kt_run_action tool
│   │   ├── AudioInterfaceAgent.swift # Voice-mode agent
│   │   ├── EnvironmentContext.swift # Host/environment facts injected into prompts
│   │   └── PromptPresets.swift     # AIPromptPresets — shared system-prompt text
│   ├── IO/                         # Runtime action I/O, staging, transcript injection
│   │   ├── KeepTalkingIOManager.swift # Typed action I/O, manifests, output delivery
│   │   ├── KeepTalkingIOManager+Transcript.swift # AIMessage/readout presentation
│   │   ├── KeepTalkingStagingIOManager.swift # Per-call staging: attachments, OTB resolve, scratch dirs
│   │   └── KeepTalkingStagingIOStore.swift # Caller-scoped, TTL/quota-bounded staged-handle actor
│   ├── AgentCoordinator.swift      # Cross-context agent run queue + suspension/resume
│   ├── KeepTalkingDelegationCoordinator.swift # Delegated (on-behalf-of) execution seam
│   ├── ModelStore.swift            # KeepTalkingModelStore / KeepTalkingInMemoryStore
│   ├── Executors/                  # Skill & tool execution managers
│   │   ├── SkillManager.swift      # Skill lifecycle (+Manifest / +Prompting / +ToolCalls)
│   │   ├── ACPManager.swift        # Agent Client Protocol — drives external coding agents (macOS only)
│   │   ├── MCPManager.swift        # MCP server/client bridge
│   │   ├── MCPStdioTransportLaunching.swift # MCP stdio launcher protocol + handle
│   │   ├── MCPCredentialStore.swift # Keychain-only HTTP MCP headers + OAuth client secret
│   │   ├── JSRuntime.swift         # JS evaluation seam — engine injected by the host (setJSRuntime)
│   │   ├── KTResourceManifest.swift # Per-run I/O manifest — KT_<KIND>_<H8> handles, env + prompt block
│   │   ├── KTCallBinding.swift     # Path-free device-side projection of one declared object
│   │   ├── FilesystemActionManager.swift # Filesystem actions + OTB transfer bridge
│   │   ├── SemanticRetrievalActionManager.swift # Retrieval-backed actions
│   │   ├── ScopeManager.swift      # Scoped action creation + grant requests
│   │   └── PrimitiveActionManager.swift # Platform primitive actions
│   ├── Process/                    # Sandboxed script + process execution
│   │   ├── SandboxedProcessRunner.swift # argv + shell runner under a compiled policy (zsh → bash → sh)
│   │   ├── SeatbeltSandbox.swift   # macOS sandbox-exec seatbelt profiles
│   │   ├── ProcessSandboxing.swift # Sandbox-backend protocol (non-iOS-family platforms)
│   │   ├── ScopeResolver.swift     # Action payload + granted scopes → sandbox policy
│   │   ├── KeepTalkingThreadWorkspaceManager.swift # Per-thread sealable execution workspaces
│   │   ├── DefaultMCPStdioTransportLauncher*.swift # Sandboxed MCP stdio launch
│   │   └── DefaultSkillScriptExecutor*.swift # Process-backed skill script executor
│   ├── SkillPlanner.swift          # Multi-step, resumable skill planning (+Probe)
│   ├── BlobStorage/                # Blob store, pull tracker, one-time blobs (OTB) + holder outbox
│   │   └── KeepTalkingBlobReferenceIndex.swift # Which blob files the DB still references
│   ├── VoiceSession/               # Group (N-peer) voice session: sealed datagrams on the room
│   ├── ContextLiveness/            # Edge-triggered peer liveness (last-seen, connect edges)
│   ├── ContextSyncing/             # Message / voice-transcript / side-note reconciliation
│   │   ├── ContextSyncSingleFlight.swift # One reconcile in flight per peer
│   │   ├── ContextSyncEvent.swift  # KeepTalkingContextSyncEvent — started/messagesApplied/completed/failed
│   │   └── SideNoteSync.swift      # KeepTalkingSideNoteVersion — (counter, writer) LWW, clock-free
│   └── SemanticStore/              # Host-injected hybrid (semantic + keyword) search protocol
│       └── SemanticIndexTrace.swift # DEBUG-only index tracing
├── Transport/
│   ├── KeepTalkingTransport.swift  # The seam: process-wide KeepTalkingTransport handle, room status,
│   │                               #   multiplexer / attachment / event protocols, blob streams
│   └── Iroh/                       # The iroh transport (iOS/macOS only)
│       ├── KeepTalkingIrohTransportHost*.swift # Process-wide host: SFU session, peer links,
│       │                           #   Bluetooth, per-member lane queues, instruments
│       ├── KeepTalkingIrohAttachment.swift # One context's room, from attach to detach
│       ├── KeepTalkingIrohSFUFrame / PeerFrame # Wire formats (keeptalking/sfu/2, peer/2)
│       ├── KeepTalkingIrohMembership / LinkTable / Delivery / Pacer # Pure, unit-tested cores
│       └── KeepTalkingIrohBluetooth*.swift # Process-wide Bluetooth radio + identity reader
├── Envelope/                       # Wire contract: kinds, lanes, kind-tagged packet coding, typed dispatch
│   ├── Models/                     # Per-kind envelope payload conformances
│   ├── Controllers/                # Inbound handlers (messaging, node, sync, action call/catalog, blobs)
│   └── Helpers/                    # Advertised actions, node & relation status
├── Migrations/                     # SQLite schema (Fluent)
├── Cryptos/                        # Keychain, node identity, frame ciphers, trust handshake
├── Helpers/                        # Shared utilities (UUIDv7, MIME, patient wait, provisioning)
└── KeepTalking.docc/               # DocC catalog — `swift package generate-documentation`
```

## Key Dependencies

| Dependency | Purpose |
|---|---|
| `FluentKit` + `FluentSQLiteDriver` | ORM + SQLite persistence |
| `IrohLib` (local fork, `../iroh-ffi`) | iroh bindings + locally built xcframework: QUIC endpoints, relay, hole punching, Bluetooth (iOS/macOS only) |
| `swift-nio` | Event loops for Fluent and the plugin host; `NIOLockedValueBox` for locks |
| `swift-crypto` | Cross-platform crypto (Apple-free SDK) |
| `swift-sdk` (MCP) | MCP server/client for tool integration |
| `AIProxyMultiPlatform` (local fork, `../AIProxySwift-MultiPlatform`) | Chat completions + embeddings client (BYOK) |
| `swift-uuidv7` | Time-ordered (RFC 9562 v7) UUIDs for primary keys |
| `swift-docc-plugin` | Builds the `KeepTalking.docc` catalog |

### AIProxy fork

`KeepTalking` depends on a local fork of AIProxySwift at `../AIProxySwift-MultiPlatform`. The fork strips the hosted-proxy backend and DeviceCheck/StoreKit plumbing, leaving two pure Swift targets:

- **`AIProxy`** — Foundation-only BYOK core (all platforms including Linux)
- **`AIProxyRealtime`** — OpenAI Realtime API over WebSocket + AVFoundation audio (Apple platforms only)

The SDK uses the `AIProxy` target only. The app may optionally link `AIProxyRealtime` for voice sessions.

## AI Provider Abstraction

`AIConnector` is the single seam wrapping any LLM backend. Connectors translate KT-native types into vendor wire formats internally — call sites never touch vendor shapes directly.

```swift
public protocol AIConnector: Actor, Sendable {
    nonisolated var capabilities: AIConnectorCapabilities { get }
    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
    ) async throws -> AITurnResult
}
```

Built-in connectors:

| Connector | Backends |
|---|---|
| `OpenAIConnector` | `.openRouter`, `.openAI`, `.custom(baseURL:)` |
| `AnthropicConnector` | `.anthropic`, `.custom(baseURL:)` |

The message IR (`AIMessage`, `AIToolCall`, `AIToolChoice`) is multimodal: an `AIMessage.Content` is either plain text or a list of `AIMessage.Part` values — `.text`, `.imageURL` (`data:` URLs allowed, which is how attachments are inlined for vision models), and `.inputAudio(data:format:)`. `AIMessage` additionally carries `audioReference` so a multi-turn audio conversation can cite a prior audio output by ID instead of re-sending bytes. `AIMessage.Content.text` is a lossy plain-text projection for providers that only accept a string body; callers needing vision must handle `.parts` explicitly. Connectors map what their provider supports and drop the rest deliberately rather than silently — `AnthropicConnector`, for example, substitutes a text placeholder for audio input and does not emit `responseFormat` or per-message `name`. `AITurnResult` surfaces optional reasoning (`thinking`) and audio output in addition to the assistant text and tool calls.

## Runtime I/O Model

Per-run action and skill I/O is centralized under `Services/IO`; the cross-node staging *call flow* that wraps a remote call sits alongside it in `ClientControllers` (`KeepTalkingClient+StagedFileController`, `KeepTalkingClient+OneTimeBlobController`). All of these types are **internal** — the public surface a host sees is `KTResourceManifest`, the `KeepTalkingActionCall*` models, and the `actionCallActivities` signal.

- The internal `KeepTalkingIOManager` owns the per-run contract: staging inputs, binding an action's declared objects to concrete input paths and workspace-backed output slots (`KTCallBinding`), resolving the sandbox policy with the run's granted directories (`KT_ATTACHMENTS` read-only, `KT_WORKSPACE` read-write), building `KTResourceManifest` from the *already-granted* candidates, harvesting whatever landed in the output slots, delivering the produced resources, and tearing the run's scratch state down. Binding, policy resolution, manifest construction and output harvesting are macOS-only (`#if os(macOS)`); produced-resource delivery and staged-resource lookup are cross-platform.
- `KeepTalkingStagingIOManager` is the IO manager's staging runtime. It materialises the context's *ready* blob attachments into a scratch directory (hard-linking from the blob store, falling back to a copy), resolves the call's staged OTB input handles into that same directory, tracks which scratch directories the run owns, and removes exactly those on cleanup. Underneath it, `KeepTalkingStagingIOStore` is a TTL- and quota-bounded actor holding files peers preflighted onto this node, keyed by opaque handle — caller-scoped, refused before decryption when over quota, and split into consume-on-use input relays versus produced outputs that survive consumption so an output can be re-fed as a later call's input.
- `KeepTalkingIOManager+Transcript` owns AI-facing presentation: tool-result messages, native attachment/user-message injection, context-resource readouts, voice transcript readouts, staged-file readouts, and produced-resource transcript injection. Oversized resources are skipped rather than truncated and unreadable ones are logged and skipped; neither aborts the turn.
- `KTResourceManifest` (the one public type here) is the per-run description handed to the executing agent — a sandboxed skill shell or an ACP agent alike; MCP tool calls deliberately get none, since a stdio server is launched once with a static environment and reused. Each granted resource becomes an entry with a canonical `KT_<KIND>_<HEX>` handle, and the same entry array drives both `environmentVariables()` and `promptBlock()`, so the handle the agent cites and the `$KT_…` variable the shell sees can never drift apart. It describes what the run may read and write; it accepts only already-granted candidates and is not the place to stage files or fetch attachments.

The intended rule is simple: resources are emitted and collected through the IO runtime. Models should receive available run resources through the turn context/presentation path, not discover OTBs by calling extra retrieval tools. If this pipeline exposes a bug, fix the bug in this model rather than adding another client-side staging or attachment shim.

## Transport

One transport per process, owned by the host app. A client never builds, starts, stops or restarts it: `connect()` attaches the client's context as a *room*, `disconnect()` detaches it. Everything below — the SFU session, peer links, Bluetooth, per-member queues, recovery — is shared by every attached context and outlives any one client, so a client rebuilt for a settings change never drops a connection and a hundred contexts cost one SFU session and one link per peer.

```swift
let host = KeepTalkingIrohTransportHost(configuration: .init(relayURL: "https://relay.example/"))
let client = KeepTalkingClient(config: config, transport: .iroh(host), localStore: store)
```

`KeepTalkingTransport.unavailable` (the default) is for clients that never connect — façades that only read the store — and for visionOS. The client sees the transport through a transport-neutral seam (`Transport/KeepTalkingTransport.swift`): a multiplexer of rooms and an attachment per room that sends envelopes and datagrams, opens blob streams and reports status, with one event stream coming back. Liveness, the 13 s presence heartbeat and resync-on-reachability are the client's; recovery is the host's.

| Concern | How it works |
|---|---|
| Rooms | A context's group secret derives its 32-byte topic and the key that seals every payload; no context or node id travels in the clear. A new secret moves the client to the new room. |
| Routes | `keeptalking/sfu/2` (one session; the SFU fans each publish out, `PUBLISH_TO` for one member) and `keeptalking/peer/2` links (relay first, direct when hole punching works; the lower id dials). `KeepTalkingIrohDeliveryPolicy.automatic(sfuAtMembers: 4)` puts small rooms on the mesh, larger ones on the SFU. Bluetooth (`off` / `whenNetworkFails` / `always`) carries the mesh offline; voice never rides it. |
| Membership | Only from presence sealed with the context secret, via the SFU or the hello every link opens with. The SFU roster is discovery, not membership. |
| Lanes | `KeepTalkingEnvelopeKind.delivery` gives each kind a lane and an idempotence claim: `control` (presence, trust, call state, acks, blob negotiation), `interactive` (messages, attachments, transcript lines, action traffic), `bulk` (context sync, node state; a stream per envelope). Each lane is its own QUIC stream on every route. |
| Sending | Never waits on a connection: on the mesh every member has a 16 MiB queue per lane, drained by whichever link carries it. Throws only with no route, not connected, or over the 1 MiB frame ceiling (the outbox drops that row; nothing fragments). |
| Status | `KeepTalkingTransportStatus`: `connecting` / `ready` / `degraded` / `offline` + a display path (`sfu` / `direct` / `relay` / `bluetooth`). `client.transportStatus()`, the `lifecycle` signal, `transportStats`. |
| Dedup | None at transport. Every kind but the trust request is idempotent; duplicates are absorbed at persistence by row id. Node status carries `issuedAtMs`; receivers keep the newest. |
| Blobs | Pull-only: `wanted` → `offer` → `pull` from one holder → a blob stream per transfer, point to point, resumable from an offset, digest-checked. One-time blobs are snapshotted into a holder outbox and pulled as soon as the request/result carrying the ref arrives. |
| Voice | Datagrams only; sender and target ride inside the call's seal. No modes, ICE or SDP. |

**Prerequisites:** a reachable iroh relay; the SFU id is looked up at `<relay>/kt/sfu` unless configured. See the DocC article *Transport* for the whole design.

## SDK Usage

`KeepTalkingClient` is the single long-lived entry point. Its initializer is **not** throwing and **not** async — but `localStore` has no default, because constructing a store is async and a Swift default argument cannot `await`. Build the store first, then inject it.

```swift
import Foundation
import KeepTalkingSDK

// 1. Storage. `make` constructs *and* migrates — an unmigrated store must not be queried.
let store = try await KeepTalkingModelStore.make()

// 2. The transport: one per process, shared by every client.
let host = KeepTalkingIrohTransportHost(configuration: .init(relayURL: "https://relay.example/"))

// 3. Configuration. Persist and reuse `node` across launches — peers key trust off it.
let config = KeepTalkingConfig(
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!
)

// 4. Client. The default keychain is in-memory and forgets every secret on exit;
//    Apple-platform hosts should pass the SecItem-backed store.
let client = KeepTalkingClient(
    config: config,
    transport: .iroh(host),
    localStore: store,
    keychain: KeepTalkingSecItemKeychainStore.shared
)
client.log.observe { line in print(line) }

// 5. Create the context (mints its secret), attach its room, and send.
let context = try await client.createContext(named: "First context")
try await client.connect()
try await client.send("Hello from my first node.", in: context)

// 6. Tear down: detach, stop the transport, then drain the store.
client.disconnect()
await host.shutdown()
await store.shutdown()
```

`KeepTalkingSecItemKeychainStore` is Apple-only (`#if canImport(Security)`); on Linux and Windows supply your own `KeepTalkingKeychainStore`, or accept the in-memory default and its consequences.

To join a context this node did not create, install the out-of-band secret instead of calling `createContext`:

```swift
try await client.setGroupChatSecret(sharedSecret, for: config.contextID)
try await client.connect()
try await client.send("Joining in.", in: config.contextID)
```

## Build

Use Xcode (open `Package.swift`; ⌘B) or the Xcode MCP for compilation. Avoid `swift build` while the Xcode persistent build server is running — both processes share the `.build` lock and the CLI will hang indefinitely.

For package tests independent of Xcode:

```bash
swift test --scratch-path /tmp/kt-test
```

Only the `KeepTalkingSDKTests` target is declared in `Package.swift`; sources under `Tests/KeepTalkingPackageTests/` are not part of any target and do not run.

To build the DocC catalog (`Sources/KeepTalking/KeepTalking.docc`):

```bash
swift package --scratch-path /tmp/kt-docs generate-documentation --target KeepTalkingSDK
```

`--scratch-path` must precede `generate-documentation`; anything after the plugin name is forwarded to `docc convert`, which rejects it. Note that a Linux build silently omits every symbol behind `#if canImport(Security)` / `AVFoundation` / `AppKit`, so a complete archive must be built on macOS.

## CLI

The `KeepTalking` executable is a development tool for exercising the SDK. It builds one iroh transport for the process from `--relay` (or `KT_RELAY`); switching contexts in the interactive client swaps clients while the transport stays up. Without a relay it has no transport and runs local commands only.

**Interactive client:**

```bash
swift run KeepTalking \
  --relay https://relay.example/ \
  --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 \
  --context 11111111-2222-3333-4444-555555555555
```

**Action management** — runs before anything connects, so no relay is needed:

```bash
swift run KeepTalking --mcp list
swift run KeepTalking --mcp add-http linear https://mcp.linear.app --header Authorization=Bearer_token
swift run KeepTalking --mcp add-stdio foo --env MODEL=gpt-4.1 -- npx -y @modelcontextprotocol/server-github
swift run KeepTalking --skill add-directory doc-summarizer ~/.codex/skills/doc-summarizer "Local summarizer"
swift run KeepTalking --skill list
```

**Flags:** `--relay <url>`, `--sfu-id <hex>` (default: looked up at `<relay>/kt/sfu`), `--node <uuid>` (alias `--id`), `--context <uuid>`, `--db-path <sqlite-file>`, `--message <text>` (one-shot send, then exit), `--openai-api-key <key>`, `--openai-endpoint <url>`, `--model <id>`, `--act-model <id>`, `--mcp …`, `--skill …`, `--help`.

**Environment variables:**
```bash
export KT_RELAY="https://relay.example/"                 # iroh relay; without it, no transport
export KT_SFU_ID="…"                                     # optional SFU endpoint id
export KT_NODE="2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9"    # default: random UUID
export KT_CONTEXT="11111111-2222-3333-4444-555555555555" # default: all-zero UUID
export KT_DB_PATH="$HOME/Library/Application Support/KeepTalking/custom.sqlite"
export OPENAI_API_KEY="..."             # enables /ai
export KT_OPENAI_ENDPOINT="..."         # or OPENAI_ENDPOINT / OPENAI_BASE_URL
export KT_MODEL="..."                   # node-wide main agent model, required for /ai
swift run KeepTalking
```

**Interactive commands:**

- `/new` — create and join a new context; prints the invite `/join` line and the base64 key
- `/join <context-uuid>` — join an existing context (prompts on stdin for the encryption key)
- `/trust <node-uuid> [all|context|<context-uuid>]` — mark a node as trusted (default `all`)
- `/lure <node-uuid> <pubkey>` — record a node→pubkey trust entry
- `/actions list` · `/actions grant <node-id> <action-id> [context|all]`
- `/mcp list` · `/mcp remove <action-id>` · `/mcp add http …` · `/mcp add stdio …`
- `/skill list` · `/skill remove <action-id>` · `/skill add directory <name> <path> [description]`
- `/ai <prompt>` — run AI tool planning/execution in the active context
- `/model [act] [<id>|reset]` — show or override the active context's models for this session
- `/stats` — the room's status, path, reachable members and traffic counters
- `/quit` (alias `/exit`) — disconnect
- anything else — sent as a chat message

## Formatting and Linting

Style is defined by `.swift-format` at the repo root (4-space indent, 120-column lines, indented switch case labels). Both invocations pick it up automatically:

```bash
swift-format format --in-place --recursive Sources
swift-format lint --recursive Sources
```

`scripts/git-hooks/pre-commit` formats staged Swift files in place and re-stages them. Install it once:

```bash
ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit
```

It accepts either a standalone `swift-format` or Xcode's bundled `swift format`, and skips silently with a warning if neither is on `PATH`.

## Distribution (macOS)

Package a runnable folder with the `KeepTalking` binary:

```bash
./scripts/package-macos.sh
# Output: dist/KeepTalking-macos/  (override with a positional argument)
```

The script builds with an isolated SwiftPM cache/scratch root, so it does not contend with Xcode for the shared `.build` lock. The binary is always code-signed: ad-hoc by default, or with a real identity and the hardened runtime when `KT_SIGN_IDENTITY` is set. Signatures are verified and the binary is smoke-launched with `--help`.

```bash
# Developer ID signature + hardened runtime
KT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-macos.sh

# Reuse an existing build. Defaults to .build/arm64-apple-macosx/release —
# set KT_BIN_DIR on Intel hosts or with a custom scratch path.
KT_SKIP_BUILD=1 ./scripts/package-macos.sh
```

Other environment overrides: `KT_BUILD_CONFIG` (default `release`), `KT_BIN_DIR`, `KT_CACHE_ROOT` (default `.build/package-cache`), `SWIFT_BIN` (default `swift`).
