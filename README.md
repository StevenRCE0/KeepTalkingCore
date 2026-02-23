# KeepTalking

Swift package for `ion-sfu` text chat over WebRTC data channels.

It includes:
- `KeepTalkingSDK` (library product) for app integration
- `KeepTalking` (CLI executable) built on top of the SDK

The transport uses `ion-sfu` JSON-RPC signaling (`/ws`) plus WebRTC DataChannels.

## Prerequisites

- macOS with Swift 6+
- A running ion-sfu JSON-RPC server (for your setup: `ws://127.0.0.1:17000/ws`)
  - Example: `docker run --name ion-sfu-jsonrpc -d -p 17000:7000 -p 5000-5200:5000-5200/udp pionwebrtc/ion-sfu:latest-jsonrpc`

## Build

```bash
cd /Users/steven/Developer/Example/KeepTalking
swift build
```

## SDK Usage

Add the package and import `KeepTalkingSDK`, then:

```swift
import KeepTalkingSDK

let config = KeepTalkingConfig(
    signalURL: URL(string: "ws://127.0.0.1:17000/ws")!,
    session: "room1",
    participantID: "alice",
    channel: "keep-talking.chat",
    userID: "alice-user"
)

let kv = KeepTalkingHTTPKVService(baseURL: URL(string: "https://your-kv.example.com")!)
let store = KeepTalkingFileStore()

let client = KeepTalkingClient(config: config, kvService: kv, localStore: store)
client.onMessage = { message in
    print("[\(message.from)] \(message.text)")
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
swift run KeepTalking --signal-url ws://127.0.0.1:17000/ws --session room1 --id alice --channel keep-talking.chat
```

One-shot message:

```bash
swift run KeepTalking --session room1 --id alice --message "hello from swift"
```

Environment variables are supported:

```bash
export KT_SIGNAL_URL="ws://127.0.0.1:17000/ws"
export KT_SESSION="room1"
export KT_ID="alice"
export KT_USER_ID="alice-user"
export KT_CHANNEL="keep-talking.chat"
swift run KeepTalking
```

Interactive commands:
- `/peer <id>` set a default target peer for outgoing messages
- `/peer all` clear target and broadcast to all peers
- `/peer` show current target
- `/stats` show local send/receive counters and outbound channel state
- `/quit` disconnect

Notes:
- Targeting is an app-level filter on top of shared data channels. Messages still traverse the session, but non-target peers ignore envelopes with a different `to` value.
- SDK now supports P2P envelopes for `node`, `friendNode`, `conversation`, `stateBundle`, and `stateRequest`.
- Local persistence stores `myNodes`, `conversations`, and `friendNodes` in `~/Library/Application Support/KeepTalking/state.json` by default.
- `KeepTalkingKVService` is protocol-based; implement your own KV backend, or use `KeepTalkingHTTPKVService`.
