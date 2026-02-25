# KeepTalking

Swift package for `ion-sfu` collaboration over WebRTC data channels.

It includes:
- `KeepTalkingSDK` (library product) for app integration
- `KeepTalking` (CLI executable) built on top of the SDK

The transport uses `ion-sfu` JSON-RPC signaling (`/ws`) plus WebRTC DataChannels:
- `signaling` channel: `keep-talking.signaling`
- `chat` channel for chat messages
- `action_call` channel for non-chat envelopes (context/node/action flow)

`chat` and `action_call` labels are suffixed with the context ID:
- `keep-talking.chat.<context-id>`
- `keep-talking.action_call.<context-id>`

The SFU session ID is also context-scoped:
- `<context-id>`

## Prerequisites

- macOS with Swift 6+
- A running ion-sfu JSON-RPC server (for your setup: `ws://127.0.0.1:17000/ws`)
  - Example: `docker run --name ion-sfu-jsonrpc -d -p 17000:7000 -p 5000-5200:5000-5200/udp pionwebrtc/ion-sfu:latest-jsonrpc`

## Build

```bash
cd /Users/steven/Developer/Example/KeepTalking
swift build
```

## Package For Distribution (macOS)

Create a runnable distribution folder containing `KeepTalking` and `LiveKitWebRTC.framework`:

```bash
cd /Users/steven/Developer/Example/KeepTalking
./scripts/package-macos.sh
```

Output defaults to:

`/Users/steven/Developer/Example/KeepTalking/dist/KeepTalking-macos`

Optional signing identity:

```bash
KT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-macos.sh
```

If artifacts are already built and you want to package without rebuilding:

```bash
KT_SKIP_BUILD=1 ./scripts/package-macos.sh
```

## SDK Usage

Add the package and import `KeepTalkingSDK`, then:

```swift
import KeepTalkingSDK

let config = KeepTalkingConfig(
    signalURL: URL(string: "ws://127.0.0.1:17000/ws")!,
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!
)

let kv = KeepTalkingPassKVService(baseURL: URL(string: "https://your-kv.example.com")!)
let store = try KeepTalkingModelStore()

let client = KeepTalkingClient(config: config, kvService: kv, localStore: store)
client.onMessage = { message in
    print("[\(message.senderNodeID)] \(message.text)")
}

try await client.connect()
try client.send(text: "hello from sdk")

// Persist/share node metadata + local graph/context snapshots
try await client.registerCurrentNodeID()
try client.announceCurrentNode()
try client.requestPeerState()
try client.syncLocalState()

let nodeIDs = try await client.fetchNodeIDs()
let snapshot = try client.loadLocalSnapshot()
```

## Run

Interactive mode:

```bash
swift run KeepTalking --signal-url ws://127.0.0.1:17000/ws --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --context 11111111-2222-3333-4444-555555555555
```

Custom DB location:

```bash
swift run KeepTalking --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --db-path ~/Library/Application\ Support/KeepTalking/custom.sqlite
```

One-shot message:

```bash
swift run KeepTalking --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --message "hello from swift"
```

Environment variables are supported:

```bash
export KT_SIGNAL_URL="ws://127.0.0.1:17000/ws"
export KT_NODE="2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9"
export KT_CONTEXT="11111111-2222-3333-4444-555555555555"
export KT_DB_PATH="$HOME/Library/Application Support/KeepTalking/custom.sqlite"
swift run KeepTalking
```

For P2P upgrade tests, run peers with distinct node IDs:

```bash
swift run KeepTalking --context 11111111-2222-3333-4444-555555555555 --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9
swift run KeepTalking --context 11111111-2222-3333-4444-555555555555 --node E3BD62F8-4C27-4E66-B9D2-1F7D27F57102
```

Interactive commands:
- `/new` create and join a new context (new sid + channel suffix)
- `/join <context-uuid>` join another context (sid + channel suffix)
- `/trust <node-uuid>` mark a node relation as trusted
- `/stats` show local send/receive counters and outbound channel state
- `/p2p` manually start a new direct P2P upgrade trial
- `/quit` disconnect

Notes:
- Messages are broadcast as context updates; no peer-level `from/to` targeting is used.
- SDK now supports P2P envelopes for `node`, `context`, `stateBundle`, and `stateRequest`.
- Local persistence stores `nodes` and `contexts` in Fluent SQLite (`~/Library/Application Support/KeepTalking/state.sqlite`) by default.
- `KeepTalkingClient` defaults to `KeepTalkingModelStore`; if initialization fails, it falls back to `KeepTalkingInMemoryStore`.
- `KeepTalkingKVService` is protocol-based; implement your own KV backend, or use `KeepTalkingPassKVService`.
