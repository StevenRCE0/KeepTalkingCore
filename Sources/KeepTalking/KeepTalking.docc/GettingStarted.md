# Getting Started

Configure a node, attach it to the process's transport, and exchange a first message in a conversation context.

## Overview

The KeepTalking SDK is built around one long-lived object per conversation: ``KeepTalkingClient``. It owns the local database, the keychain-backed secrets, and the optional AI and action-execution machinery, and it attaches to a transport the host app builds once per process. Everything else in the SDK hangs off those two.

A client is always scoped to exactly one conversation *context*. The context ID is part of ``KeepTalkingConfig``, which the client captures at construction and never mutates — the room the client joins on the transport is derived from it. Switching contexts therefore means building a new configuration with ``KeepTalkingConfig/withContextID(_:)`` and constructing a second client, not reconfiguring the first. The new client attaches to the same transport, so switching never drops a connection.

The SDK requires iOS 17.5+, macOS 14.5+, or visionOS 1+, and builds with Swift 6.1+; the iOS and macOS floors are those of the vendored iroh library the transport is built on. The library product is `KeepTalkingSDK`; import that module name. The transport expects a reachable iroh relay, which also names the KeepTalking SFU. visionOS builds without a transport: clients there read and write the local store but never connect.

### Building a configuration

``KeepTalkingConfig`` describes a single node's session. Its initializer takes four parameters, all with defaults:

```swift
public init(
    contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
    node: UUID = UUID(),
    recentAttachmentSyncLookback: TimeInterval = 14 * 24 * 60 * 60,
    contextSyncChunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
)
```

In practice you supply `contextID` and `node` yourself and let the rest default. The `node` UUID is this device's stable identity — persist it and reuse it across launches, because peers key trust relations and action authorization off it. The last two are node-local tuning knobs and are rarely worth changing: `recentAttachmentSyncLookback` bounds how far back attachment recovery looks for missing records and bytes, and `contextSyncChunkSize` is how many messages a context-sync summary packs per chunk, which is the granularity at which divergence is detected.

Nothing about the network is configured here. The transport is process-wide, so its settings belong to the transport, not to any one client's configuration.

### Building the transport

Build one ``KeepTalkingIrohTransportHost`` for the process and hand it to every client as ``KeepTalkingTransport/iroh(_:)``:

```swift
let host = KeepTalkingIrohTransportHost(
    configuration: .init(
        relayURL: "https://relay.example/",
        sfuEndpointID: nil,          // nil: looked up at <relay>/kt/sfu
        bluetooth: .off              // or .whenNetworkFails, .always
    )
)
let transport = KeepTalkingTransport.iroh(host)
```

A client never starts, stops, or restarts the transport; connecting attaches its context as a room, and disconnecting detaches it. That is why a client rebuilt for a settings change never drops a connection, and why any number of contexts share one SFU session and one link per peer. The host binds nothing until the first context attaches. When the process is done with networking, or when new settings replace the host, call ``KeepTalkingIrohTransportHost/shutdown()``; clients built on the old host cannot connect again and must be rebuilt on the new one.

A client that never connects — a façade that only reads the store, a preview, a test with no network — takes ``KeepTalkingTransport/unavailable``, which is the initializer's default. So does every client on visionOS. Connecting such a client throws. See <doc:Transport> for how the host reaches peers.

### Choosing a local store and a keychain

Persistence is split deliberately. Ordinary model state — contexts, messages, nodes, actions, threads, mappings — lives in a Fluent/SQLite database behind ``KeepTalkingLocalStore``. Anything that must never be readable from that database — group chat secrets, node identity private keys, login credentials, HTTP MCP credentials — lives behind ``KeepTalkingKeychainStore``.

Two local stores ship with the SDK. ``KeepTalkingModelStore`` is the SQLite-backed store; its initializer throws and takes an optional `databaseURL`, an optional `databaseFileName`, a `databaseID`, and a `logger`, all defaulted. With no arguments it targets `Application Support/KeepTalking/state.sqlite`. ``KeepTalkingInMemoryStore`` is the non-throwing in-memory equivalent, useful for tests and previews.

Construction and migration are deliberately separate. Both initializers are synchronous and do no database I/O — they register the database, middleware, and migration list, and nothing more. Applying the migrations is ``KeepTalkingLocalStore/migrate()``, which is async, and a store **must** be migrated before it is queried. The split exists because a construction that also migrated forced callers who could not `await` to bridge with a semaphore, and that bridge deadlocks: under parallel tests it fills the cooperative pool with waiters, and in an app the bridged work can hop to a main actor that is already blocked on it.

From an async context, prefer the one-step factories — ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:journal:gate:logger:)`` and ``KeepTalkingInMemoryStore/make(gate:)`` — which construct and migrate together. ``KeepTalkingClient/makeDefaultLocalStore()`` is the async convenience that tries the SQLite store and falls back to the in-memory one when it cannot be opened.

The client does not build a store for you. `localStore` is a required initializer parameter, precisely because constructing a store is async and a Swift default argument cannot `await`. Build the store first, then inject it.

For the keychain, the client's default is ``KeepTalkingInMemoryKeychainStore`` — convenient, but it forgets every secret when the process exits, which means a context's group chat secret is regenerated on the next launch and previously encrypted traffic can no longer be decrypted. Shipping apps on Apple platforms should pass `KeepTalkingSecItemKeychainStore`, which stores items via `SecItem` and honours the consuming target's `keychain-access-groups` entitlement so an app and its extensions share one set of secrets. That type is compiled only where `Security` is importable — on Apple platforms — so on other platforms supply your own ``KeepTalkingKeychainStore`` conformance if you need durable secrets. Both stores address entries through ``KeepTalkingKeychainKey``, whose kinds are group secrets, node identity private keys, login credentials, and HTTP MCP credentials.

### Instantiating the client

``KeepTalkingClient``'s initializer is **not** throwing and not `async` — only the stores you build for it can throw. Every parameter except `config` and `localStore` has a default:

```swift
public init(
    config: KeepTalkingConfig,
    transport: KeepTalkingTransport = .unavailable,
    kvService: (any KeepTalkingKVService)? = nil,
    stdioTransportLauncher: (any MCPStdioTransportLaunching)? = DefaultMCPStdioTransportLauncher.current,
    skillScriptExecutor: (any SkillScriptExecuting)? = DefaultSkillScriptExecutor.current,
    primitiveRegistry: KeepTalkingPrimitiveRegistry? = nil,
    logon: UUID = UUID(),
    localStore: any KeepTalkingLocalStore,
    keychain: any KeepTalkingKeychainStore = KeepTalkingInMemoryKeychainStore()
)
```

Pass the process's transport as `transport`; leave it at `.unavailable` only for a client that will never connect.

There are no AI parameters: a client carries no connector and no model. Each AI run takes a ``KeepTalkingAgentConfiguration`` — pass one with a send, and install ``KeepTalkingClient/setAgentConfigurationProvider(_:)`` for the work the node serves on its own (a peer's call into a skill, a plugin ACT turn). Without a provider, `aiEnabled` reports `false` and such work fails with `aiNotConfigured`; messaging and transport still work. See <doc:AIAgents>.

### Connecting

``KeepTalkingClient/connect()`` ensures the configured context row and its group secret exist, opens the context-sync request registries, attaches the context's room on the transport — starting the host if this is its first room — and persists this node. Only once all of that has succeeded does it commit the connection and start the maintenance heartbeat, the 13-second presence heartbeat, and the once-a-second statistics sampler. It throws at once when the client's transport is `.unavailable`.

Attaching does not wait for peers. `connect()` returns as soon as the room exists on the transport; whether anyone is reachable yet is the room's status, read with ``KeepTalkingClient/transportStatus()`` or from the `lifecycle` signal (see <doc:Events>). A message sent before any route exists stays on the outbox and goes out when the room reports it can take sends.

Two pieces of work deliberately run *after* `connect()` returns, on a post-connect task: the initial `.connected` maintenance pass (which broadcasts local node state and reconciles stale agent-turn continuations) and, if a ``KeepTalkingKVService`` was supplied, registering this node's ID with it. Neither can fail the connection — a KV registration error is logged, not thrown — so a reachable transport is never held hostage by a slow or broken discovery backend.

`connect()` is guarded against overlap. A second call while one is already in flight, or while the client is connected, throws `KeepTalkingClientError.alreadyConnected` rather than racing.

Registering local action executors is deliberately *not* part of connecting: a failing executor — an HTTP MCP server that needs re-authorization, say — must never block bringing the transport up or trigger an auth prompt as a side effect. Hosts that want executors live call ``KeepTalkingClient/registerLocalActionsInExecutors()`` explicitly, off the connection path.

### Creating or joining a context

``KeepTalkingClient/createContext(named:)`` creates the context identified by the client's own `config.contextID`, optionally gives it an alias, and generates the context's group chat secret. Use it when this node originates the conversation.

Joining an existing context is the mirror image: you already know the context UUID and you need its secret, which travels out of band or through the trust-invitation handshake. Build a configuration for that context, construct a client, install the shared secret with ``KeepTalkingClient/setGroupChatSecret(_:for:)``, and connect. ``KeepTalkingClient/ensureGroupChatSecret(for:)`` returns the stored secret or mints one when none exists, so it is the safe read path once a context is established. Both calls also persist the context row, so a freshly joined context is immediately usable. The secret also addresses the context's room on the transport, so installing a different secret on a client that is already connected moves it: the client detaches and attaches again under the new secret, keeping its identity, so nothing that holds the client has to rebuild it.

### Sending a message

`send(_:in:)` persists the message locally, then schedules and attempts delivery to peers. Only the text and the target are required — the target may be a ``KeepTalkingContext`` or a bare context `UUID`, and the remaining parameters (`sender`, `type`, `agentTurnID`, `emitLocalEnvelope`) are defaulted. Leaving `sender` as `nil` attributes the message to this node; `type` defaults to `.message`, the ordinary conversational kind of ``KeepTalkingContextMessage``. Further overloads accept local file attachments or references to blobs already present in the blob store.

Delivery is local-first, and the split matters when you read the errors. Local persistence is what decides whether the message exists; the outbox is a retry ledger for that persisted row, not a second message store. Once the row is saved, a transport failure does *not* throw out of `send` — the entry stays on the outbox and drains when the room can take sends again, and context sync will replicate it regardless. What you can still get back is a persistence, metadata, or key error.

One check runs *before* the row exists: content larger than `KeepTalkingMessageLimits.maximumContentBytes` (512 KiB) is refused with `KeepTalkingClientError.messageTooLarge(bytes:limit:)`. The transport does not fragment envelopes, so a message past the envelope ceiling could neither be sent nor replicated; persisting it would leave an outbox row retrying forever and a sync page that cannot be served.

### Tearing down

``KeepTalkingClient/disconnect()`` is synchronous and cheap, because it only detaches this context's room: the shared transport, and every other context on it, stays up. It fails pending action calls, catalog requests, and context-sync requests with `KeepTalkingClientError.clientDisconnected`, cancels the connection's tasks, and detaches. By the time it returns the `lifecycle` signal reads `idle`, so a following ``KeepTalkingClient/connect()`` can start at once. Calling it on an idle client does nothing.

The transport is torn down separately, by whoever owns it. Call ``KeepTalkingIrohTransportHost/shutdown()`` once the process no longer needs the network, after disconnecting the clients on it: shutting the host down under an attached client leaves that client unable to send.

The store has its own teardown too, and it is worth doing explicitly. Call ``KeepTalkingLocalStore/shutdown()`` before you drop the last reference to a store you are retiring — when switching to another identity's database, for instance. Merely releasing it runs the teardown from `deinit` on a background queue, which can pull the event loop out from under a query still in flight; NIO then trips its `EventLoopFuture.deinit` assertion and the process traps. `shutdown()` drains first, and is idempotent.

## A minimal working example

```swift
import Foundation
import KeepTalkingSDK

// 1. Storage. `make` constructs *and* migrates in one step — a store that has
//    not been migrated must not be queried. The keychain store is what keeps
//    group secrets alive across launches; the SecItem one is Apple-only.
let store = try await KeepTalkingModelStore.make()
let keychain = KeepTalkingSecItemKeychainStore.shared

// 2. The transport: one per process, shared by every client. It binds
//    nothing until the first context attaches.
let host = KeepTalkingIrohTransportHost(
    configuration: .init(relayURL: "https://relay.example/")
)

// 3. Configuration. Persist and reuse `node` across launches.
let config = KeepTalkingConfig(
    contextID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    node: UUID(uuidString: "2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9")!
)

// 4. The client. The initializer does not throw, and `localStore` is required.
let client = KeepTalkingClient(
    config: config,
    transport: .iroh(host),
    localStore: store,
    keychain: keychain
)
client.log.observe { line in print(line) }

// 5. Create the context. This also mints its group chat secret.
let context = try await client.createContext(named: "First context")

// 6. Attach the context's room to the transport.
try await client.connect()

// 7. Send a message.
try await client.send("Hello from my first node.", in: context)

// 8. Shut down: detach, stop the transport, then drain the store.
client.disconnect()
await host.shutdown()
await store.shutdown()
```

To join a context this node did not create, replace steps 5 to 7 with the shared secret you received out of band. Install it before connecting, so the client attaches to the context's room the first time:

```swift
try await client.setGroupChatSecret(sharedSecret, for: config.contextID)
try await client.connect()
try await client.send("Joining in.", in: config.contextID)
```

## Where to go next

Once messaging works, the natural next steps are enabling AI by supplying a connector or an API key, registering local actions so peers can call them, and observing the room's status with ``KeepTalkingClient/transportStatus()`` or the `lifecycle` and `transportStats` signals (see <doc:Events>). Most failures the client itself raises surface as ``KeepTalkingClientError``, whose cases name the specific problem — a missing context, an unauthorized operation, a client torn down mid-flight — rather than a generic transport error. It is not the only error type you will see: the transport, the keychain, the blob store, and the Fluent stack each throw their own, so treat `KeepTalkingClientError` as the SDK's vocabulary for client-level faults, not as an exhaustive error domain.

## Topics

### Configuring a node

- ``KeepTalkingConfig``
- ``KeepTalkingConfig/withContextID(_:)``

### The transport

- ``KeepTalkingTransport``
- ``KeepTalkingIrohTransportHost``
- ``KeepTalkingIrohTransportHost/Configuration``
- ``KeepTalkingIrohTransportHost/shutdown()``

### Local storage and secrets

- ``KeepTalkingLocalStore``
- ``KeepTalkingLocalStore/migrate()``
- ``KeepTalkingLocalStore/shutdown()``
- ``KeepTalkingModelStore``
- ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:journal:gate:logger:)``
- ``KeepTalkingInMemoryStore``
- ``KeepTalkingInMemoryStore/make(gate:)``
- ``KeepTalkingKeychainStore``
- ``KeepTalkingInMemoryKeychainStore``
- ``KeepTalkingKeychainKey``

### Creating and running a client

- ``KeepTalkingClient``
- ``KeepTalkingClient/makeDefaultLocalStore()``
- ``KeepTalkingClient/connect()``
- ``KeepTalkingClient/registerLocalActionsInExecutors()``
- ``KeepTalkingClient/disconnect()``

### Contexts and messages

- ``KeepTalkingContext``
- ``KeepTalkingContextMessage``
- ``KeepTalkingMessageLimits``
- ``KeepTalkingClient/createContext(named:)``
- ``KeepTalkingClient/ensureGroupChatSecret(for:)``
- ``KeepTalkingClient/setGroupChatSecret(_:for:)``

### Transport status and local reset

- ``KeepTalkingClient/transportStatus()``
- ``KeepTalkingTransportStatus``
- ``KeepTalkingClient/runtimeStats()``
- ``KeepTalkingRuntimeStats``
- ``KeepTalkingClient/eraseLocalState()``

### Optional integrations

- ``KeepTalkingKVService``
- ``OpenAIConnectorBackend``
- ``KeepTalkingClientError``
