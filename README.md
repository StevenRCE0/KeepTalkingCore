# KeepTalking SDK

Swift package providing the core engine for KeepTalking — a distributed AI conversation platform with P2P transport, semantic threading, multi-provider AI, MCP-based skill execution, and sandboxed script running.

## Products

| Product | Kind | Description |
|---|---|---|
| `KeepTalkingSDK` | library | Core SDK consumed by `KeepTalkingApp` and any other host |
| `KeepTalking` | executable | Development CLI for testing SDK features, MCP tools, and skills |

## Platforms

iOS 17+, macOS 13+, visionOS 1+ — swift-tools-version 6.1, built with the Swift 6.3.2 toolchain (`.swift-version`).

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
│   ├── BlobStorage/                # Blob store, chunked transfer queue, one-time blobs (OTB)
│   │   └── KeepTalkingBlobReferenceIndex.swift # Which blob files the DB still references
│   ├── VoiceSession/               # Group (N-peer) voice session over P2P
│   ├── ContextLiveness/            # Edge-triggered peer liveness (last-seen, connect edges)
│   ├── ContextSyncing/             # Message / voice-transcript / side-note reconciliation
│   │   ├── ContextSyncSingleFlight.swift # One reconcile in flight per peer
│   │   ├── ContextSyncEvent.swift  # KeepTalkingContextSyncEvent — started/messagesApplied/completed/failed
│   │   └── SideNoteSync.swift      # KeepTalkingSideNoteVersion — (counter, writer) LWW, clock-free
│   └── SemanticStore/              # Host-injected hybrid (semantic + keyword) search protocol
│       └── SemanticIndexTrace.swift # DEBUG-only index tracing
├── Transport/
│   ├── ContextTransport.swift      # Fan-out orchestrator — broadcast / directed / fan-out,
│   │                               #   chosen from envelope kind; no SFU/ICE/WebRTC knowledge
│   ├── KeepTalkingTransportClient.swift # Internal transport-client protocol the client talks to
│   ├── NetworkEnvironment.swift    # Interface digest — re-arms direct-path verdicts on network change
│   ├── Channels/                   # Channel protocols + pure-value state machines
│   ├── Models/                     # Route enum, envelope channel, P2P signal payloads, runtime stats
│   └── Routes/                     # Concrete channel implementations
│       ├── SFU/                    # SFU broadcast channel (KeepTalkingSFU package)
│       └── P2P/                    # libjuice ICE + HTTP/2-over-TLS direct channel (SwiftNIO)
├── Envelope/                       # Wire contract: kinds, kind-tagged packet coding, typed dispatch
│   ├── Models/                     # Per-kind envelope payload conformances
│   ├── Controllers/                # Inbound handlers (messaging, node, sync, action call/catalog)
│   └── Helpers/                    # Advertised actions, node & relation status
├── Migrations/                     # SQLite schema (Fluent)
├── Cryptos/                        # Keychain, node identity, packet/frame ciphers, trust handshake
├── Helpers/                        # Shared utilities (UUIDv7, MIME, patient wait, provisioning)
└── KeepTalking.docc/               # DocC catalog — `swift package generate-documentation`
```

## Key Dependencies

| Dependency | Purpose |
|---|---|
| `FluentKit` + `FluentSQLiteDriver` | ORM + SQLite persistence |
| `KeepTalkingSFU` (local, `../KeepTalkingSFU`) | `KeepTalkingSFUClient` + `KeepTalkingSFUProtocol` for the broadcast backbone |
| `swift-libjuice` / `SwiftJUICE` | ICE/STUN/TURN for P2P direct channels |
| `swift-nio` / `swift-nio-http2` / `swift-nio-ssl` | Event loops + HTTP/2-over-TLS carrier for the direct P2P channel |
| `swift-crypto` | Cross-platform crypto (Apple-free SDK) |
| `swift-certificates` + `swift-asn1` | Per-session self-signed X.509 / TLS identity |
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

Per-run action and skill I/O is centralized under `Services/IO`; the cross-node staging *call flow* that wraps a remote call sits alongside it in `ClientControllers` (`KeepTalkingClient+StagedFileController`, `KeepTalkingClient+OneTimeBlobController`). All of these types are **internal** — the public surface a host sees is `KTResourceManifest`, the `KeepTalkingActionCall*` models, and the `onActionCallActivity` callback.

- The internal `KeepTalkingIOManager` owns the per-run contract: staging inputs, binding an action's declared objects to concrete input paths and workspace-backed output slots (`KTCallBinding`), resolving the sandbox policy with the run's granted directories (`KT_ATTACHMENTS` read-only, `KT_WORKSPACE` read-write), building `KTResourceManifest` from the *already-granted* candidates, harvesting whatever landed in the output slots, delivering the produced resources, and tearing the run's scratch state down. Binding, policy resolution, manifest construction and output harvesting are macOS-only (`#if os(macOS)`); produced-resource delivery and staged-resource lookup are cross-platform.
- `KeepTalkingStagingIOManager` is the IO manager's staging runtime. It materialises the context's *ready* blob attachments into a scratch directory (hard-linking from the blob store, falling back to a copy), resolves the call's staged OTB input handles into that same directory, tracks which scratch directories the run owns, and removes exactly those on cleanup. Underneath it, `KeepTalkingStagingIOStore` is a TTL- and quota-bounded actor holding files peers preflighted onto this node, keyed by opaque handle — caller-scoped, refused before decryption when over quota, and split into consume-on-use input relays versus produced outputs that survive consumption so an output can be re-fed as a later call's input.
- `KeepTalkingIOManager+Transcript` owns AI-facing presentation: tool-result messages, native attachment/user-message injection, context-resource readouts, voice transcript readouts, staged-file readouts, and produced-resource transcript injection. Oversized resources are skipped rather than truncated and unreadable ones are logged and skipped; neither aborts the turn.
- `KTResourceManifest` (the one public type here) is the per-run description handed to the executing agent — a sandboxed skill shell or an ACP agent alike; MCP tool calls deliberately get none, since a stdio server is launched once with a static environment and reused. Each granted resource becomes an entry with a canonical `KT_<KIND>_<HEX>` handle, and the same entry array drives both `environmentVariables()` and `promptBlock()`, so the handle the agent cites and the `$KT_…` variable the shell sees can never drift apart. It describes what the run may read and write; it accepts only already-granted candidates and is not the place to stage files or fetch attachments.

The intended rule is simple: resources are emitted and collected through the IO runtime. Models should receive available run resources through the turn context/presentation path, not discover OTBs by calling extra retrieval tools. If this pipeline exposes a bug, fix the bug in this model rather than adding another client-side staging or attachment shim.

## Transport

The transport layer is protocol-abstracted: `KeepTalkingContextTransport` knows only `KeepTalkingTransportChannelProtocol` and its broadcast/peer refinements — no WebRTC, ICE, SDP, or data-channel vocabulary. It routes on two declarative properties of the envelope's `kind` plus the envelope's optional target.

Two concrete channel types sit below it:

- **SFU broadcast** (`KeepTalkingSFU` package) — always-on backbone over HTTP/2, authenticated per connection with a fresh ephemeral Ed25519 key. Every node stays joined, so every send can fall back to it.
- **P2P direct** (`SwiftJUICE` + `SwiftNIO`) — optional per-peer upgrade, created lazily on a reachability edge and signaled over the backbone (never a bootstrap dependency). libjuice ICE only proves the path; payload then rides a single long-lived bidirectional HTTP/2 stream over TLS, and the ICE session is closed.

Routing is envelope-level, and the envelope's *kind* — not the call site — declares the policy. `sendEnvelope` picks one of three shapes:

| Shape | Trigger | Behavior |
|---|---|---|
| Broadcast only | `kind.allowsDirect == false` | SFU, or throw `.allChannelsUnavailable` when the backbone is down |
| Directed | `allowsDirect` + `targetPeerNodeID` set | that peer's direct channel when ready, else SFU |
| Fanned out | `allowsDirect` + no target | every ready direct channel, with SFU covering peers that have none |

| Kind property | Meaning | `true` for |
|---|---|---|
| `allowsDirect` | may use a direct channel at all — a permission, not a route | `.message`, `.attachment`, `.voiceCallTranscriptLine`, action-call request/ack/result (plain + encrypted) |
| `isFanOutEligible` | safe to deliver twice; gates the fan-out shape | `.message`, `.attachment`, `.voiceCallTranscriptLine` |

Signaling, presence, trust, voice-call, `.contextSync`, node-status, action-catalog and agent-continuation kinds are `allowsDirect == false`: they must reach peers no direct channel exists for yet, or have no direct-path delivery ack. An untargeted kind that is direct-capable but not fan-out eligible degrades to broadcast rather than trapping.

Fallback is per-leg. A failed direct send is logged and retried on the SFU; one failed fan-out leg never stops the others; with the backbone down a fan-out succeeds only if at least one leg landed. The one exception is `.envelopeTooLarge`, rethrown as itself — every route fails the same size check.

Blob bytes are never fanned out: `sendBlobData(_:targetPeerNodeID:)` is directed when a target is named and broadcast-only otherwise.

| Concern | Where it lives now |
|---|---|
| Route label | `KeepTalkingTransportRoute` (`.sfu` / `.p2p`) — physical "which wire carried the bytes" for stats, logs and `currentRoute()`; never a routing decision |
| Fragmentation | none — one envelope caps at 1 MiB, checked on the sealed bytes (`PacketTransportCrypto.maxOutboundPayloadBytes`); over that fails `.envelopeTooLarge`. Blobs chunk on their own channel |
| Dedup | none at transport — no sequence numbers, no dedup table. Duplicates are absorbed at persistence by row id, which is why fan-out is restricted to idempotent kinds |
| Mesh cap | `KeepTalkingConfig.maxDirectMeshSize` (default 4). Exceeding it tears the whole direct mesh down and stays on the SFU; sticky until transport start or a network change |
| Network change | `KeepTalkingNetworkEnvironment.digest()` fingerprints up, non-loopback interfaces (IPv6 counted by /64 prefix only), sampled each ~13s heartbeat. A change clears the mesh cap and retries abandoned/backing-off channels |

Receive is one dispatch on `KeepTalkingEnvelopeChannel`: `.signaling` is consumed inside the transport (trust → trust handler, voice-call forwarded on, p2p signal/presence into the direct channels and liveness state), everything else is delivered to the app.

**Prerequisites:** a reachable KeepTalkingSFU server (see `../KeepTalkingSFU`), configured through `KeepTalkingConfig.sfuEndpoint` — `SFUEndpoint(host:port:)`, port defaults to 9701. Without it the broadcast channel cannot start, and since P2P is signaled over the backbone, no direct channel forms either.

## SDK Usage

`KeepTalkingClient` is the single long-lived entry point. Its initializer is **not** throwing and **not** async — but `localStore` has no default, because constructing a store is async and a Swift default argument cannot `await`. Build the store first, then inject it.

```swift
import Foundation
import KeepTalkingSDK

// 1. Storage. `make` constructs *and* migrates — an unmigrated store must not be queried.
let store = try await KeepTalkingModelStore.make()

// 2. Configuration. `sfuEndpoint` is not optional in practice: the SFU broadcast
//    channel is the transport backbone, and `connect()` throws
//    `KeepTalkingTransportError.sfuEndpointMissing` without it.
//    Persist and reuse `node` across launches — peers key trust off it.
let config = KeepTalkingConfig(
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!,
    sfuEndpoint: KeepTalkingConfig.SFUEndpoint(host: "127.0.0.1", port: 9701)
)

// 3. Client. The default keychain is in-memory and forgets every secret on exit;
//    Apple-platform hosts should pass the SecItem-backed store.
let client = KeepTalkingClient(
    config: config,
    localStore: store,
    keychain: KeepTalkingSecItemKeychainStore.shared
)
client.onLog = { line in print(line) }

// 4. Bring the transport up, then create a context and send.
try await client.connect()
let context = try await client.createContext(named: "First context")
try await client.send("Hello from my first node.", in: context)

// 5. Tear down: stop the transport, then drain the store.
await client.disconnectAndWait()
await store.shutdown()
```

`KeepTalkingSecItemKeychainStore` is Apple-only (`#if canImport(Security)`); on Linux and Windows supply your own `KeepTalkingKeychainStore`, or accept the in-memory default and its consequences.

To join a context this node did not create, install the out-of-band secret instead of calling `createContext`:

```swift
try await client.setGroupChatSecret(sharedSecret, for: config.contextID)
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

The `KeepTalking` executable is a development tool for exercising the SDK. It has three distinct modes.

**SFU broadcast harness** — any run that configures an SFU endpoint (`--sfu`, `--sfu-juice`, or `KT_SFU`) enters a minimal stdin↔SFU loop: each stdin line is broadcast to the context as opaque bytes and inbound payloads are printed to stderr. Slash commands are not available here.

```bash
swift run KeepTalking \
  --sfu 127.0.0.1:9701 \
  --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 \
  --context 11111111-2222-3333-4444-555555555555
```

**Blob lab** — direct HTTP/2 blob transfer over libjuice-discovered candidates, signaled through the SFU:

```bash
swift run KeepTalking bloblab listen  --sfu 127.0.0.1:9701 --context <uuid> [--node <uuid>] [--timeout 30]
swift run KeepTalking bloblab connect --sfu 127.0.0.1:9701 --context <uuid> [--peer <hex>] [--bytes 4096]
```

**Action management** — runs before the transport comes up, so no SFU endpoint is needed:

```bash
swift run KeepTalking --mcp list
swift run KeepTalking --mcp add-http linear https://mcp.linear.app --header Authorization=Bearer_token
swift run KeepTalking --mcp add-stdio foo --env MODEL=gpt-4.1 -- npx -y @modelcontextprotocol/server-github
swift run KeepTalking --skill add-directory doc-summarizer ~/.codex/skills/doc-summarizer "Local summarizer"
swift run KeepTalking --skill list
```

**Flags:** `--sfu host:port` (alias `--sfu-juice`; port defaults to 9701), `--node <uuid>` (alias `--id`), `--context <uuid>`, `--db-path <sqlite-file>`, `--message <text>` (one-shot send, then exit), `--p2p-timeout <seconds>`, `--openai-api-key <key>`, `--openai-endpoint <url>`, `--mcp …`, `--skill …`, `--diagnose`, `--help`.

**Environment variables:**
```bash
export KT_SFU="127.0.0.1:9701"                           # optional host:port, default port 9701
export KT_NODE="2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9"    # default: random UUID
export KT_CONTEXT="11111111-2222-3333-4444-555555555555" # default: all-zero UUID
export KT_DB_PATH="$HOME/Library/Application Support/KeepTalking/custom.sqlite"
export KT_P2P_TIMEOUT=5
export OPENAI_API_KEY="..."             # enables /ai
export KT_OPENAI_ENDPOINT="..."         # or OPENAI_ENDPOINT / OPENAI_BASE_URL
swift run KeepTalking
```

**Interactive commands.** The full interactive client lives behind `KeepTalkingCLIController`, but is currently unreachable: configuring an SFU endpoint diverts to the broadcast harness above, and omitting one makes `connect()` fail with `sfuEndpointMissing`. The implemented command set is:

- `/new` — create and join a new context; prints the invite `/join` line and the base64 key
- `/join <context-uuid>` — join an existing context (prompts on stdin for the encryption key)
- `/trust <node-uuid> [all|context|<context-uuid>]` — mark a node as trusted (default `all`)
- `/lure <node-uuid> <pubkey>` — record a node→pubkey trust entry
- `/actions list` · `/actions grant <node-id> <action-id> [context|all]`
- `/mcp list` · `/mcp remove <action-id>` · `/mcp add http …` · `/mcp add stdio …`
- `/skill list` · `/skill remove <action-id>` · `/skill add directory <name> <path> [description]`
- `/ai <prompt>` — run AI tool planning/execution in the active context
- `/stats` — route, send/receive counters, channel labels and states
- `/p2p` (alias `/p2p-trial`) — manually start a direct P2P upgrade trial
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
