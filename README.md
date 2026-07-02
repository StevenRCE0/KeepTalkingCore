# KeepTalking SDK

Swift package providing the core engine for KeepTalking — a distributed AI conversation platform with P2P transport, semantic threading, multi-provider AI, MCP-based skill execution, and sandboxed script running.

## Products

| Product | Kind | Description |
|---|---|---|
| `KeepTalkingSDK` | library | Core SDK consumed by `KeepTalkingApp` and any other host |
| `KeepTalking` | executable | Development CLI for testing SDK features, MCP tools, and skills |

## Platforms

iOS 17+, macOS 13+, visionOS 1+, Swift 6.1+

## Architecture

```
Sources/KeepTalking/
├── Client.swift                    # KeepTalkingClient — main SDK entry point
├── ClientControllers/              # Action orchestration, thread ops, AI controller
├── Models/                         # Core domain models
│   ├── KeepTalkingContextMessage   # Raw conversation history rows
│   ├── KeepTalkingThread           # Semantic memory unit
│   ├── KeepTalkingContext          # Conversation container
│   ├── KeepTalkingNode             # P2P node identity
│   ├── KeepTalkingAction           # Distributed function call + ACLs
│   └── KeepTalkingMapping          # Tag/alias abstractions
├── Services/
│   ├── AIConnectors/               # LLM provider abstraction layer
│   │   ├── AIConnector.swift       # Protocol — completeTurn(messages:tools:...)
│   │   ├── AIMessage.swift         # KT-native message IR (multimodal)
│   │   ├── OpenAIConnector.swift   # OpenRouter + OpenAI + custom endpoints
│   │   ├── AnthropicConnector.swift # Anthropic Messages API
│   │   ├── MetaTools/              # Agent-facing built-in tools (attachments, JS eval, semantic search)
│   │   └── *WebSearchTool.swift    # Exa, OpenAI, and OpenRouter web search backends
│   ├── Orchestrators/              # Multi-agent orchestration
│   │   ├── MainAgent.swift         # Primary conversation agent
│   │   ├── ACTAgent.swift          # Autonomous tool-calling agent loop
│   │   └── AudioInterfaceAgent.swift # Voice-mode agent
│   ├── IO/                         # Runtime action I/O, staging, transcript injection
│   │   ├── KeepTalkingIOManager.swift # Typed action I/O, manifests, output delivery
│   │   ├── KeepTalkingIOManager+Transcript.swift # AIMessage/readout presentation
│   │   ├── KeepTalkingStagingManager.swift # Skill-run resource collection/staging
│   │   └── KeepTalkingStagedFileStore.swift # OTB/staged-file handle backend
│   ├── AgentCoordinator.swift      # Cross-context agent run queue + suspension/resume
│   ├── Executors/                  # Skill & tool execution managers
│   │   ├── SkillManager.swift      # Skill lifecycle: planning, prompting, tool dispatch
│   │   ├── ACPManager.swift        # Agent Communication Protocol
│   │   ├── MCPManager.swift        # MCP server/client bridge
│   │   ├── JSRuntime.swift         # JavaScript execution (JSCore host bridge)
│   │   ├── KTResourceManifest.swift # Per-run I/O manifest (file grant + OTB routing)
│   │   └── PrimitiveActionManager.swift # Platform primitive actions
│   ├── Process/                    # Sandboxed script + process execution
│   │   ├── SandboxedProcessRunner.swift # zsh/bash sandbox runner
│   │   ├── SeatbeltSandbox.swift   # macOS sandbox-exec seatbelt profiles
│   │   └── MCPStdioTransportLaunching.swift # Sandboxed MCP stdio launch
│   ├── SkillPlanner.swift          # Multi-step, resumable skill planning
│   ├── VoiceSession/               # P2P voice call session management
│   ├── ContextLiveness/            # Peer liveness + presence state machine
│   ├── ContextSyncing/             # Cross-node context sync controller
│   └── SemanticStore/              # Vector / BM25 hybrid search protocol
├── Transport/
│   ├── ContextTransport.swift      # Routing orchestrator (SFU broadcast + P2P direct)
│   ├── Channels/                   # Channel protocol + state machines
│   │   ├── SFU/                    # SFU broadcast channel (KeepTalkingSFU package)
│   │   └── P2P/                    # libjuice direct channel (SwiftNIO framing)
│   ├── Models/                     # Envelope, routing, sync shapes
│   └── Routes/                     # Routing strategy definitions
├── Envelope/                       # Message framing & serialization
├── Migrations/                     # SQLite schema (Fluent)
├── Cryptos/                        # Key management & node identity (swift-crypto)
└── Helpers/                        # Shared utilities (UUIDv7, extensions)
```

## Key Dependencies

| Dependency | Purpose |
|---|---|
| `FluentKit` + `FluentSQLiteDriver` | ORM + SQLite persistence |
| `KeepTalkingSFU` (local) | SFU client + protocol for broadcast transport channel |
| `swift-libjuice` / `SwiftJUICE` | ICE/STUN/TURN for P2P direct channels |
| `swift-nio` suite | NIO event loops, HTTP/2, TLS — framing the P2P channel |
| `swift-crypto` | Cross-platform crypto |
| `swift-certificates` + `swift-asn1` | X.509 / TLS identity |
| `swift-sdk` (MCP) | MCP server/client for tool integration |
| `AIProxyMultiPlatform` (local fork) | Chat completions + embeddings client (BYOK) |
| `swift-uuidv7` | Time-ordered (RFC 9562 v7) UUIDs for primary keys |

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

The message IR (`AIMessage`, `AIToolCall`, `AIToolChoice`) supports multimodal content — text + image URLs — and maps cleanly to all vendor formats. `AITurnResult` surfaces optional reasoning (`thinking`) and audio output in addition to the assistant text and tool calls.

## Runtime I/O Model

Action and skill I/O is centralized under `Services/IO`.

- `KeepTalkingIOManager` owns the per-run contract: binding declared action objects to concrete inputs/outputs, building `KTResourceManifest`, granting directories, harvesting outputs, delivering produced resources, and cleaning up after a run.
- `KeepTalkingStagingManager` is the IO manager's staging runtime. It collects ready context attachments, resolves staged OTB handles into the same run directory, records owned scratch directories, and delegates persistent staged-handle storage to `KeepTalkingStagedFileStore`.
- `KeepTalkingIOManager+Transcript` owns AI-facing presentation: tool-result messages, native attachment/user-message injection, context-resource readouts, voice transcript readouts, staged-file readouts, and produced-resource transcript injection.
- `KTResourceManifest` remains the per-run description handed to the skill agent. It describes what the run can read/write; it is not the place to stage files or fetch attachments.

The intended rule is simple: resources are emitted and collected through the IO runtime. Models should receive available run resources through the turn context/presentation path, not discover OTBs by calling extra retrieval tools. If this pipeline exposes a bug, fix the bug in this model rather than adding another client-side staging or attachment shim.

## Transport

The transport layer is protocol-abstracted: `ContextTransport` only knows about `KeepTalkingTransportChannelProtocol` and routing strategies — it has no WebRTC, ICE, or data-channel knowledge.

Two concrete channel types sit below it:

- **SFU broadcast** (`KeepTalkingSFU` package) — always-on backbone for context distribution.
- **P2P direct** (`SwiftJUICE` + `SwiftNIO`) — optional direct upgrade for lower latency; negotiated via libjuice ICE on top of the SFU signaling path.

Routing is envelope-level:

| Strategy | Behavior |
|---|---|
| `.sfuOnly` | SFU broadcast only |
| `.preferDirect` | direct → fallback broadcast |
| `.conservative` | broadcast → fallback direct |

**Prerequisites:** a running KeepTalkingSFU signaling server (see `../KeepTalkingSFU`).

## SDK Usage

```swift
import KeepTalkingSDK

let config = KeepTalkingConfig(
    signalURL: URL(string: "ws://127.0.0.1:17000/ws")!,
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!
)

let client = try KeepTalkingClient(config: config, kvService: nil, localStore: store)
try await client.connect()
```

## Build

Use Xcode (`BuildProject` / ⌘B) or the Xcode MCP for compilation. Avoid `swift build` while the Xcode persistent build server is running — both processes share the `.build` lock and the CLI will hang indefinitely.

For package tests independent of Xcode:

```bash
swift test --scratch-path /tmp/kt-test
```

## CLI

The `KeepTalking` executable is a development tool for exercising the SDK interactively.

```bash
swift run KeepTalking \
  --signal-url ws://127.0.0.1:17000/ws \
  --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 \
  --context 11111111-2222-3333-4444-555555555555
```

**Environment variables:**
```bash
export KT_SIGNAL_URL="ws://127.0.0.1:17000/ws"
export KT_NODE="2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9"
export KT_CONTEXT="11111111-2222-3333-4444-555555555555"
export KT_DB_PATH="$HOME/Library/Application Support/KeepTalking/custom.sqlite"
swift run KeepTalking
```

**Interactive commands:**
- `/new` — create and join a new context
- `/join <context-uuid>` — join an existing context
- `/trust <node-uuid>` — mark a node relation as trusted
- `/stats` — send/receive counters + channel state
- `/p2p` — manually trigger a direct P2P upgrade
- `/quit` — disconnect

## Formatting and Linting

```bash
swift-format format --in-place --recursive Sources
swift-format lint --recursive Sources
```

## Distribution (macOS)

Package a runnable folder with the `KeepTalking` binary:

```bash
./scripts/package-macos.sh
# Output: dist/KeepTalking-macos/

# Optional code signing
KT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-macos.sh

# Skip rebuild
KT_SKIP_BUILD=1 ./scripts/package-macos.sh
```
