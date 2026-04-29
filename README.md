# KeepTalking SDK

Swift package providing the core engine for KeepTalking — a distributed AI conversation platform with P2P transport, semantic threading, multi-provider AI, and MCP-based skill execution.

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
│   │   ├── AIOrchestrator.swift    # Multi-turn loop driver
│   │   ├── OpenAIConnector.swift   # OpenRouter + OpenAI + custom endpoints
│   │   ├── AnthropicConnector.swift # Anthropic Messages API
│   │   ├── ACTAgent.swift          # Autonomous tool-calling agent
│   │   └── ActionToolAbstraction.swift # Tool definition + catalog
│   ├── Executors/                  # Skill & MCP tool execution
│   ├── SkillPlanner.swift          # Multi-step skill planning
│   ├── ContextSyncing/             # Cross-node context sync
│   └── SemanticStore/              # Vector / BM25 hybrid search
├── Transport/
│   ├── ContextTransport.swift      # P2P transport orchestrator
│   ├── RTC/                        # WebRTC (ion-sfu) data channels
│   └── Models/                     # Envelope, routing, sync shapes
├── Envelope/                       # Message framing & serialization
├── Migrations/                     # SQLite schema (Fluent)
├── Cryptos/                        # Key management & node identity
└── Helpers/                        # Shared utilities
```

## Key Dependencies

| Dependency | Purpose |
|---|---|
| `FluentKit` + `FluentSQLiteDriver` | ORM + SQLite persistence |
| `LiveKitWebRTC` | WebRTC for P2P data channels (ion-sfu compatible) |
| `swift-sdk` (MCP) | MCP server/client for tool integration |
| `AIProxyMultiPlatform` | Chat completions + embeddings client (local fork — see below) |

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

The message IR (`AIMessage`, `AIToolCall`, `AIToolChoice`) supports multimodal content — text + image URLs — and maps cleanly to all three vendor formats (OpenAI Chat Completions, Anthropic Messages, Apple FoundationModels).

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

## Transport

The transport layer uses `ion-sfu` JSON-RPC signaling (`/ws`) plus WebRTC DataChannels. Each context gets its own SFU session and channel namespace:

| Channel | Label |
|---|---|
| Signaling | `keep-talking.signaling` |
| Chat | `keep-talking.chat.<context-id>` |
| Action/envelope | `keep-talking.action_call.<context-id>` |

**Prerequisites:** a running ion-sfu JSON-RPC server, e.g.:
```bash
docker run --name ion-sfu -d -p 17000:7000 -p 5000-5200:5000-5200/udp \
  pionwebrtc/ion-sfu:latest-jsonrpc
```

## Build

```bash
swift build
# Release
swift build -c release
```

## Tests

```bash
swift test
```

## CLI

The `KeepTalking` executable is a development tool for exercising the SDK interactively.

**Interactive session:**
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

Package a runnable folder with the `KeepTalking` binary and `LiveKitWebRTC.framework`:

```bash
./scripts/package-macos.sh
# Output: dist/KeepTalking-macos/

# Optional code signing
KT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-macos.sh

# Skip rebuild
KT_SKIP_BUILD=1 ./scripts/package-macos.sh
```
