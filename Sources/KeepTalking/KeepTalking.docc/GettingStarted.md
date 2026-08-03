# Getting Started

Configure a node, bring up its transport, and exchange a first message in a conversation context.

## Overview

The KeepTalking SDK is built around one long-lived object: ``KeepTalkingClient``. It owns the transport, the local database, the keychain-backed secrets, and the optional AI and action-execution machinery. Everything else in the SDK hangs off it.

A client is always scoped to exactly one conversation *context*. The context ID is part of ``KeepTalkingConfig``, which the client captures at construction and never mutates — the channel labels the transport subscribes to are derived from it. Switching contexts therefore means building a new configuration with ``KeepTalkingConfig/withContextID(_:)`` and constructing a second client, not reconfiguring the first. Note that `withContextID(_:)` carries over the context ID, node, P2P attempt timeout, SFU endpoint, and attachment lookback only — if you set `maxDirectMeshSize` or `contextSyncChunkSize` away from their defaults, re-apply them on the derived configuration.

The SDK requires iOS 17+, macOS 13+, or visionOS 1+, and builds with Swift 6.1+. The library product is `KeepTalkingSDK`; import that module name. Transport also expects a reachable KeepTalkingSFU signaling server — the SFU broadcast channel is the always-on backbone, and the optional direct P2P channel is negotiated on top of it.

### Building a configuration

``KeepTalkingConfig`` describes a single node's session. Its initializer takes seven parameters, all with defaults:

```swift
public init(
    contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
    node: UUID = UUID(),
    p2pAttemptTimeoutSeconds: TimeInterval = 5,
    sfuEndpoint: SFUEndpoint? = nil,
    recentAttachmentSyncLookback: TimeInterval = 14 * 24 * 60 * 60,
    maxDirectMeshSize: Int = 4,
    contextSyncChunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
)
```

The last two are node-local tuning knobs and are rarely worth changing. `maxDirectMeshSize` is the peer count above which the transport stops maintaining direct channels and stays on the SFU — a mesh costs one ICE agent plus one HTTP/2 channel per peer per node, so it stops paying off quickly. `contextSyncChunkSize` is how many messages a context-sync summary packs per chunk, which is the granularity at which divergence is detected.

In practice you supply `contextID` and `node` yourself and let the rest default. The `node` UUID is this device's stable identity — persist it and reuse it across launches, because peers key trust relations and action authorization off it. `sfuEndpoint` is a host/port pair (``KeepTalkingConfig/SFUEndpoint`` defaults its port to `9701`), and in practice it is not optional: the SFU broadcast channel is the transport's backbone, so leaving it `nil` makes ``KeepTalkingClient/connect()`` throw when the broadcast channel tries to build its client. Voice fails earlier and more explicitly — `makeVoiceSession(mode:maxP2PMeshSize:)` throws `KeepTalkingClientError.noSFUEndpointConfigured`, since voice requires SFU presence and signaling.

### Choosing a local store and a keychain

Persistence is split deliberately. Ordinary model state — contexts, messages, nodes, actions, threads, mappings — lives in a Fluent/SQLite database behind ``KeepTalkingLocalStore``. Anything that must never be readable from that database — group chat secrets, node identity private keys, login credentials, HTTP MCP credentials — lives behind ``KeepTalkingKeychainStore``.

Two local stores ship with the SDK. ``KeepTalkingModelStore`` is the SQLite-backed store; its initializer throws and takes an optional `databaseURL`, an optional `databaseFileName`, a `databaseID`, and a `logger`, all defaulted. With no arguments it targets `Application Support/KeepTalking/state.sqlite`. ``KeepTalkingInMemoryStore`` is the non-throwing in-memory equivalent, useful for tests and previews.

Construction and migration are deliberately separate. Both initializers are synchronous and do no database I/O — they register the database, middleware, and migration list, and nothing more. Applying the migrations is ``KeepTalkingLocalStore/migrate()``, which is async, and a store **must** be migrated before it is queried. The split exists because a construction that also migrated forced callers who could not `await` to bridge with a semaphore, and that bridge deadlocks: under parallel tests it fills the cooperative pool with waiters, and in an app the bridged work can hop to a main actor that is already blocked on it.

From an async context, prefer the one-step factories — ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:logger:)`` and ``KeepTalkingInMemoryStore/make()`` — which construct and migrate together. ``KeepTalkingClient/makeDefaultLocalStore()`` is the async convenience that tries the SQLite store and falls back to the in-memory one when it cannot be opened.

The client does not build a store for you. `localStore` is a required initializer parameter, precisely because constructing a store is async and a Swift default argument cannot `await`. Build the store first, then inject it.

For the keychain, the client's default is ``KeepTalkingInMemoryKeychainStore`` — convenient, but it forgets every secret when the process exits, which means a context's group chat secret is regenerated on the next launch and previously encrypted traffic can no longer be decrypted. Shipping apps on Apple platforms should pass `KeepTalkingSecItemKeychainStore`, which stores items via `SecItem` and honours the consuming target's `keychain-access-groups` entitlement so an app and its extensions share one set of secrets. That type is compiled only where `Security` is importable — on Apple platforms — so on other platforms supply your own ``KeepTalkingKeychainStore`` conformance if you need durable secrets. Both stores address entries through ``KeepTalkingKeychainKey``, whose kinds are group secrets, node identity private keys, login credentials, and HTTP MCP credentials.

### Instantiating the client

``KeepTalkingClient``'s initializer is **not** throwing and not `async` — only the stores you build for it can throw. Every parameter except `config` and `localStore` has a default:

```swift
public init(
    config: KeepTalkingConfig,
    kvService: (any KeepTalkingKVService)? = nil,
    openAIAPIKey: String? = nil,
    openAIEndpoint: String? = nil,
    openAIBackend: OpenAIConnectorBackend = .openRouter,
    openAIModel: String? = nil,
    responseLanguages: [String] = [],
    aiConnector: (any AIConnector)? = nil,
    actConnector: (any AIConnector)? = nil,
    stdioTransportLauncher: (any MCPStdioTransportLaunching)? = DefaultMCPStdioTransportLauncher.current,
    skillScriptExecutor: (any SkillScriptExecuting)? = DefaultSkillScriptExecutor.current,
    primitiveRegistry: KeepTalkingPrimitiveRegistry? = nil,
    logon: UUID = UUID(),
    localStore: any KeepTalkingLocalStore,
    keychain: any KeepTalkingKeychainStore = KeepTalkingInMemoryKeychainStore()
)
```

The AI parameters are entirely optional. If you pass an `aiConnector`, it is used as-is. Otherwise the client looks for an explicit `openAIAPIKey`, then the `OPENAI_API_KEY` environment variable, and builds an OpenAI-compatible connector against `openAIBackend` — ``OpenAIConnectorBackend`` defaults to `.openRouter`. The endpoint falls back to `openAIEndpoint`, then `OPENAI_ENDPOINT`, then `OPENAI_BASE_URL`. With no key anywhere, no connector is created and `aiEnabled` reports `false`; messaging and transport still work. Note that `openAIModel` should match the active provider's naming — OpenRouter model IDs are provider-prefixed — since it is the default model for agent loops the SDK drives itself, such as skill execution triggered by an incoming action call.

### Connecting

``KeepTalkingClient/connect()`` ensures the configured context row exists, opens the context-sync request registries, starts the transport, and persists this node. Only once all of that has succeeded does it commit the connection and start the maintenance heartbeat.

Two pieces of work deliberately run *after* `connect()` returns, on a post-connect task: the initial `.connected` maintenance pass (which broadcasts local node state and reconciles stale agent-turn continuations) and, if a ``KeepTalkingKVService`` was supplied, registering this node's ID with it. Neither can fail the connection — a KV registration error is logged, not thrown — so a reachable transport is never held hostage by a slow or broken discovery backend.

`connect()` is guarded against overlap. A second call while one is already in flight, or while the client is connected or mid-disconnect, throws rather than racing.

Registering local action executors is deliberately *not* part of connecting: a failing executor — an HTTP MCP server that needs re-authorization, say — must never block bringing the transport up or trigger an auth prompt as a side effect. Hosts that want executors live call ``KeepTalkingClient/registerLocalActionsInExecutors()`` explicitly, off the connection path.

### Creating or joining a context

``KeepTalkingClient/createContext(named:)`` creates the context identified by the client's own `config.contextID`, optionally gives it an alias, and generates the context's group chat secret. Use it when this node originates the conversation.

Joining an existing context is the mirror image: you already know the context UUID and you need its secret, which travels out of band or through the trust-invitation handshake. Build a configuration for that context, construct a client, install the shared secret with ``KeepTalkingClient/setGroupChatSecret(_:for:)``, and connect. ``KeepTalkingClient/ensureGroupChatSecret(for:)`` returns the stored secret or mints one when none exists, so it is the safe read path once a context is established. Both calls also persist the context row, so a freshly joined context is immediately usable.

### Sending a message

`send(_:in:)` persists the message locally, then schedules and attempts delivery to peers. Only the text and the target are required — the target may be a ``KeepTalkingContext`` or a bare context `UUID`, and the remaining parameters (`sender`, `type`, `agentTurnID`, `emitLocalEnvelope`) are defaulted. Leaving `sender` as `nil` attributes the message to this node; `type` defaults to `.message`, the ordinary conversational kind of ``KeepTalkingContextMessage``. Further overloads accept local file attachments or references to blobs already present in the blob store.

Delivery is local-first, and the split matters when you read the errors. Local persistence is what decides whether the message exists; the outbox is a retry ledger for that persisted row, not a second message store. Once the row is saved, a transport failure does *not* throw out of `send` — the entry stays on the outbox and drains when channels reopen, and context sync will replicate it regardless. What you can still get back is a persistence, metadata, or key error.

One check runs *before* the row exists: content larger than `KeepTalkingMessageLimits.maximumContentBytes` (512 KiB) is refused with `KeepTalkingClientError.messageTooLarge(bytes:limit:)`. The transport does not fragment envelopes, so a message past the envelope ceiling could neither be sent nor replicated; persisting it would leave an outbox row retrying forever and a sync page that cannot be served.

### Tearing down

``KeepTalkingClient/disconnect()`` returns immediately. It synchronously fails pending action calls, catalog requests, and context-sync requests with `KeepTalkingClientError.clientDisconnected`, cancels the maintenance and post-connect tasks, then dispatches the transport teardown to a detached task, because closing peer connections joins worker threads and would otherwise stall a `MainActor` caller for hundreds of milliseconds. A subsequent ``KeepTalkingClient/connect()`` awaits that in-flight teardown before restarting, so a tight disconnect-then-connect sequence still serializes correctly. When you need to observe a fully stopped transport — in tests, or during a controlled shutdown — use ``KeepTalkingClient/disconnectAndWait()``.

The store is torn down separately, and it is worth doing explicitly. Call ``KeepTalkingLocalStore/shutdown()`` before you drop the last reference to a store you are retiring — when switching to another identity's database, for instance. Merely releasing it runs the teardown from `deinit` on a background queue, which can pull the event loop out from under a query still in flight; NIO then trips its `EventLoopFuture.deinit` assertion and the process traps. `shutdown()` drains first, and is idempotent.

## A minimal working example

```swift
import Foundation
import KeepTalkingSDK

// 1. Storage. `make` constructs *and* migrates in one step — a store that has
//    not been migrated must not be queried. The keychain store is what keeps
//    group secrets alive across launches; the SecItem one is Apple-only.
let store = try await KeepTalkingModelStore.make()
let keychain = KeepTalkingSecItemKeychainStore.shared

// 2. Configuration. Persist and reuse `node` across launches.
let config = KeepTalkingConfig(
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!,
    sfuEndpoint: KeepTalkingConfig.SFUEndpoint(host: "127.0.0.1", port: 9701)
)

// 3. The client. The initializer does not throw, and `localStore` is required.
let client = KeepTalkingClient(
    config: config,
    localStore: store,
    keychain: keychain
)
client.onLog = { line in print(line) }

// 4. Bring the transport up.
try await client.connect()

// 5. Create the context. This also mints its group chat secret.
let context = try await client.createContext(named: "First context")

// 6. Send a message.
try await client.send("Hello from my first node.", in: context)

// 7. Shut down: wait for the transport to stop, then drain the store.
await client.disconnectAndWait()
await store.shutdown()
```

To join a context this node did not create, replace steps 5 and 6 with the shared secret you received out of band:

```swift
try await client.setGroupChatSecret(sharedSecret, for: config.contextID)
try await client.send("Joining in.", in: config.contextID)
```

## Where to go next

Once messaging works, the natural next steps are enabling AI by supplying a connector or an API key, registering local actions so peers can call them, and observing transport health with ``KeepTalkingClient/transportHealth()``. Most failures the client itself raises surface as ``KeepTalkingClientError``, whose cases name the specific problem — a missing context, an unauthorized operation, a client torn down mid-flight — rather than a generic transport error. It is not the only error type you will see: the transport, the keychain, the blob store, and the Fluent stack each throw their own, so treat `KeepTalkingClientError` as the SDK's vocabulary for client-level faults, not as an exhaustive error domain.

## Topics

### Configuring a node

- ``KeepTalkingConfig``
- ``KeepTalkingConfig/SFUEndpoint``
- ``KeepTalkingConfig/withContextID(_:)``

### Local storage and secrets

- ``KeepTalkingLocalStore``
- ``KeepTalkingLocalStore/migrate()``
- ``KeepTalkingLocalStore/shutdown()``
- ``KeepTalkingModelStore``
- ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:logger:)``
- ``KeepTalkingInMemoryStore``
- ``KeepTalkingInMemoryStore/make()``
- ``KeepTalkingKeychainStore``
- ``KeepTalkingInMemoryKeychainStore``
- ``KeepTalkingKeychainKey``

### Creating and running a client

- ``KeepTalkingClient``
- ``KeepTalkingClient/makeDefaultLocalStore()``
- ``KeepTalkingClient/connect()``
- ``KeepTalkingClient/registerLocalActionsInExecutors()``
- ``KeepTalkingClient/disconnect()``
- ``KeepTalkingClient/disconnectAndWait()``

### Contexts and messages

- ``KeepTalkingContext``
- ``KeepTalkingContextMessage``
- ``KeepTalkingMessageLimits``
- ``KeepTalkingClient/createContext(named:)``
- ``KeepTalkingClient/ensureGroupChatSecret(for:)``
- ``KeepTalkingClient/setGroupChatSecret(_:for:)``

### Transport health and reset

- ``KeepTalkingClient/transportHealth()``
- ``KeepTalkingClient/TransportHealth``
- ``KeepTalkingClient/probeTransport(timeout:)``
- ``KeepTalkingClient/reestablishTransport()``
- ``KeepTalkingClient/runtimeStats()``
- ``KeepTalkingRuntimeStats``
- ``KeepTalkingClient/eraseLocalState()``

### Optional integrations

- ``KeepTalkingKVService``
- ``OpenAIConnectorBackend``
- ``KeepTalkingClientError``
