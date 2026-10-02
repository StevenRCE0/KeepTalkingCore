# Architecture

How the SDK is layered — from the client façade down through services, routing, and envelope framing to the wire — and which seams keep those layers independent.

## Overview

The SDK is a stack of six layers. Each one is allowed to know about the layer directly beneath it and nothing else, and each boundary is drawn at a point where the implementation on the far side could be swapped without the near side noticing.

```
KeepTalkingClient          the façade a host talks to
  └── ClientControllers    one extension per concern
        └── Services       capability engines (AI, execution, sync, media)
              └── Transport      process-wide host, one room per context
                    └── Envelope       framing, kind tagging, lanes, typed dispatch
                          └── Models / Migrations   Fluent rows + schema
```

Two cross-cutting directories sit beside the stack rather than inside it: `Cryptos` holds key management, node identity, and the envelope/frame ciphers; `Helpers` holds shared primitives such as time-ordered UUIDv7 generation and MIME inference.

### Client

``KeepTalkingClient`` is the object a host application constructs for each conversation. One instance drives one conversation context, fixed at construction by ``KeepTalkingConfig`` — the room the client attaches to on the transport is derived from the context ID and its group secret, so moving to another context means building a fresh configuration with ``KeepTalkingConfig/withContextID(_:)`` and a second client rather than mutating the first. The one other object a host builds is the process-wide transport, once, which every client is handed (see *Transport*, below).

The client owns the long-lived collaborators: the local store, the keychain, the execution managers, the blob store, and the agent coordinator. It holds the transport without owning it. It also owns the *push surface* — a set of signals (`envelopes`, `lifecycle`, `presence`, `contextSyncEvents`, `blobAvailabilityChanges`, `sideNoteChanges`, `actionCallActivities`, `agentRuns`, `voiceTranscriptLines`, and others; see <doc:Events>) through which everything asynchronous is reported. Hosts observe the client; they do not poll it.

Bringing the transport up and registering local action executors are deliberately separate steps. ``KeepTalkingClient/connect()`` ensures the context row and its group secret exist, attaches the context's room on the process-wide transport, persists this node, and begins the maintenance and presence heartbeats — it does *not* register executors, because a failing executor (an HTTP MCP server needing re-authorization, say) must never block the transport or trigger an auth prompt as a side effect of connecting. Hosts that want executors live call ``KeepTalkingClient/registerLocalActionsInExecutors()`` explicitly.

### Client controllers

Thirty-five files under `ClientControllers/` each declare a single `extension KeepTalkingClient` for one concern: messaging, message pagination, threads, thread workspaces, mappings, nodes, node aliases, action calls, action cancellation, action catalogs, sealed call parameters, agent turn continuations, context sync, transcript sync, context maintenance, trust invitations, blobs, one-time blobs, the outbox, push wake, staged files, side notes, semantic memory, voice, and the AI controller.

They are extensions rather than separate objects on purpose. The bookkeeping an action call needs — pending continuations, received results, in-flight task handles, caller identity — has to be shared with the envelope handlers that complete it, so it lives once on the client and each controller reaches it directly. What the controllers add on top are the public value types the host actually handles: ``KeepTalkingAgentRunSnapshot``, ``KeepTalkingAgentTurnSuspension``, ``KeepTalkingActionSummary``, ``KeepTalkingNodeTrustScope``, and their peers.

### Services

`Services/` holds the capability engines. Their common shape is an actor with a narrow public method surface, constructed once by the client and addressed by controllers:

- **AIConnectors** — the provider abstraction (see *Connectors hide vendor wire formats*, below), plus the agent-facing meta tools and the web-search backends.
- **Orchestrators** — ``AIOrchestrator`` drives the main conversation loop; the ACT sub-agent handles the full resolve-call-distil cycle behind a single `kt_run_action` tool so the primary model stays meta-tool only; ``AudioInterfaceAgent`` covers voice mode.
- **Executors** — ``SkillManager``, ``MCPManager``, ``PrimitiveActionManager``, ``FilesystemActionManager``, ``SemanticRetrievalActionManager``, and, on macOS, the ACP and scope managers. Each registers the action bundles it understands and exposes a `callAction` entry point.
- **IO** — the centralised runtime I/O pipeline (see *IO is centralised*, below).
- **Process** — sandboxed subprocess execution, seatbelt profile compilation on macOS, and per-thread execution workspaces via ``KeepTalkingThreadWorkspaceManager``.
- **ContextSyncing, ContextLiveness, VoiceSession, SemanticStore, BlobStorage** — reconciliation, presence, call media, retrieval, and file transfer.

Some services are protocols with no bundled implementation. ``KeepTalkingSemanticStore`` is the clearest case: the SDK defines index/update/remove/search and lets the app layer inject a vector backend, because embedding storage is a host concern.

### Transport

The transport is process-wide. The host app builds one ``KeepTalkingIrohTransportHost`` and hands it to every client as ``KeepTalkingTransport/iroh(_:)``; a client never starts, stops, or restarts it. `connect()` attaches the client's context to it as a *room*, and `disconnect()` detaches. That is why a client rebuilt for a settings change never drops a connection, and why any number of contexts share one SFU session and one link per peer.

Clients see the transport only through a transport-neutral seam: a multiplexer of rooms, and an attachment per room that sends envelopes and datagrams, opens blob streams, and reports status, with one event stream coming back. Below it, the iroh host reaches members three ways — an SFU that fans each publish out so a sender uploads once, a mesh of peer links that start on the relay and go direct when hole punching works, and Bluetooth when the network fails — and picks the SFU or the mesh per room by size. Members are learned only from presence sealed with the context's secret, and every payload is sealed with a key derived from it, so the SFU sees opaque bytes.

There is deliberately no sequence number and no transport-level dedup. A resync, or a member's traffic moving from one link to another, can deliver the same envelope twice, so every kind declares whether it is idempotent and duplicate suppression is done at persistence, keyed on row ID. See <doc:Transport> for the whole design.

### Envelope

The envelope layer is the wire contract. ``KeepTalkingEnvelope`` is a `Codable & Sendable` protocol whose conformers declare a static ``KeepTalkingEnvelopeKind``; how it travels is *derived* from that kind rather than restated per payload. ``KeepTalkingEnvelopeKind/delivery`` answers with a ``KeepTalkingEnvelopeDelivery``: a lane and an idempotence claim. Presence, trust, voice call state, acks, and blob negotiation ride `control`; messages, attachment records, transcript lines, and action traffic ride `interactive`; context sync and node state ride `bulk`. Each lane is its own QUIC stream on every route, so a sync page never holds up a chat message. Every kind is safe to deliver twice except the trust request, whose second copy would mint a fresh ephemeral key and strand the handshake.

Domain models are retrofitted onto this protocol by extensions in `Envelope/Models/`, so ``KeepTalkingContextMessage`` — the persisted row — *is* the wire payload. There is no parallel DTO hierarchy to keep in sync for those types.

``KeepTalkingEnvelopePacket`` performs kind-tagged coding: it writes the kind alongside the payload and, on decode, dispatches on the kind to reconstruct the concrete type behind an existential. The transport seals the encoded packet whole with the room's key, so nothing about it, the sender included, travels in the clear; no sequence number is carried, because nothing downstream dedups on one. Inbound dispatch is table-driven through ``KeepTalkingEnvelopeAsyncHandlers``, which registers one typed handler per kind and downcasts at the boundary. A handler registered through `registerReportingApplied(_:_:)` returns whether the envelope actually changed anything locally, and a `false` suppresses the outward `envelopes` publish — that is what keeps a redelivered copy from raising a second notification.

### Models and migrations

`Models/` holds the Fluent models — contexts, messages, attachments, threads and thread workspaces, nodes, node relations and node identity keys, actions, mappings, blob records, outbox entries, side notes, trust invitations, voice transcript lines — along with the pure value types (action bundles, action scopes and grant transactions, call requests and results, push-wake shapes) that travel with them. Voice *calls* are not among them: they live in memory keyed by session ID, and only their transcript lines are durable.

`Migrations/` holds the ordered schema migration list — mostly one create per table, plus the additive and drop steps the schema has accumulated since. They are internal by design: the schema is not part of the SDK's API. ``KeepTalkingModelStore`` registers that list and installs the message and attachment touch middleware that forward-only advances a context's `updatedAt` when a child row is written.

Construction and migration are deliberately separate. ``KeepTalkingModelStore/init(databaseURL:databaseFileName:databaseID:journal:gate:logger:)`` is synchronous and does no I/O; ``KeepTalkingModelStore/migrate()`` applies the migrations and must complete before the store is queried. Splitting them means a caller that cannot `await` never has to bridge with a semaphore. Callers already in an async context use ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:journal:gate:logger:)``, which does both. Hosts that need a different backing store conform to ``KeepTalkingLocalStore`` instead; ``KeepTalkingInMemoryStore`` is the non-persistent equivalent used by tests and previews.

## The concurrency model

The package builds with Swift 6.1 under strict concurrency, so every type that crosses a boundary is `Sendable` and every callback is `@Sendable`.

**Services are actors.** ``SkillManager``, ``MCPManager``, ``PrimitiveActionManager``, ``FilesystemActionManager``, ``SemanticRetrievalActionManager``, ``KeepTalkingThreadWorkspaceManager``, and ``KeepTalkingSkillPlanner`` are all actors, as is the internal agent coordinator. Their mutable registries — which action IDs map to which live executor, which runs are queued — are actor state, never lock-guarded fields.

**Connectors are actors by contract.** ``AIConnector`` is declared `protocol AIConnector: Actor, Sendable`, which forces every provider implementation into actor isolation. Its one synchronously-readable member, ``AIConnectorCapabilities``, is `nonisolated` precisely so the agent loop can consult it while building a turn without awaiting the connector.

**The client is not an actor.** ``KeepTalkingClient`` is a `final class` marked `@unchecked Sendable`. It has to be: it is the fan-in point for events arriving on the transport's tasks, and making it an actor would force every inbound envelope through a single executor and serialise unrelated work. Instead it guards each independent piece of bookkeeping with its own dedicated dispatch queue — one for action calls, one for action catalogs, one for the trust handshake — plus locks for the connection lifecycle and for buffered orphan attachments. Request/response correlation is expressed as maps of `CheckedContinuation` under those queues, and per-result-type registries own the pending continuations and timeouts for each sync stream.

**The transport is event-driven, and sends do not suspend.** `sendEnvelope` is a synchronous throwing call: the room either queues the frame on its route or throws, which is what lets a send participate in a tight failure path without suspension. Inbound traffic arrives as events on the transport's tasks and is handed up through one `@Sendable` closure per attachment; the client re-enters structured concurrency by spawning a fresh `Task` per envelope. That is also why an attachment can be persisted before the message it belongs to — each envelope gets its own task, and lanes are not ordered against each other — and why the messaging controller buffers orphan attachments keyed by parent message ID and re-drives them when the parent lands.

**The connection is a lock, not an actor.** The client's connection state machine is generation-tracked behind a lock, so `disconnect()` stays synchronous and the realtime voice-datagram path never takes an executor hop. Detaching a room is cheap — the shared transport stays up for every other context — so `disconnect()` does all of its work inline: it ends the generation, cancels the connection's tasks, detaches, and fails pending continuations. The lifecycle reads `idle` by the time it returns, and events from a superseded attachment are dropped by generation.

**Agent runs are coordinated, not merely queued.** A context's local turns are serialised — at most one active, the rest queued and started automatically — but a turn that suspends to await an out-of-band continuation frees its slot so the next can begin, and delegated runs (a skill this node executes on behalf of a remote caller) share the same coordinator.

**The transport's decisions are pure values.** Inside the iroh host, the bookkeeping that decides things — whose turn it is to dial and which connection is current, who is a member of which room, whether a room rides the mesh or the SFU, and what its status is — lives in `Sendable` structs with no iroh objects in them. The host applies a change under one lock and reports what it changed; nothing polls a socket to ask whether it is alive. That keeps the reconnect, membership, and routing logic testable without a network.

## A message, end to end

```swift
import KeepTalkingSDK

// Once per process, shared by every client.
let host = KeepTalkingIrohTransportHost(
    configuration: .init(relayURL: "https://relay.example/")
)

let config = KeepTalkingConfig(contextID: contextID, node: nodeID)
let store = try await KeepTalkingModelStore.make()
let client = KeepTalkingClient(config: config, transport: .iroh(host), localStore: store)

client.envelopes.observe { envelope in
    print(envelope.kind, envelope.kind.delivery.lane)
}

try await client.connect()
try await client.send("hello", in: config.contextID)
```

What that last line sets in motion:

1. **Persist first.** The messaging controller refuses oversize content *before* any row exists — a message that can neither be sent nor replicated would otherwise leave a retry row that never drains. The content ceiling is set at half the envelope ceiling, because the check runs on plaintext while the envelope limit applies after sealing and base64/JSON framing have inflated it. It then resolves the local node, upserts the context, and builds a ``KeepTalkingContextMessage`` with a time-ordered UUIDv7 primary key. The row is saved through Fluent; the touch middleware advances the context's `updatedAt` as a side effect of that save. Attachments are persisted next.

2. **Ensure the secret.** The context's group chat secret is created if absent, because the transport will need it to encrypt the payload.

3. **Enqueue before sending.** A ``KeepTalkingOutboxEntry`` is written *before* the transport push. From this point transport failures no longer throw: the message already exists locally, so the push is simply left to drain later. The outbox is "existence is retry" — the row carries no attempt count, and it is cleared only when a send is accepted. The one exception is an oversize envelope, which fails identically on every retry and so is dropped from the ledger rather than retried forever; the message row itself always stays, and context sync can still replicate it.

4. **Hand to the room.** The model conforms to ``KeepTalkingEnvelope``, so it is passed directly to `sendEnvelope`, and on to the client's attachment, with no conversion step.

5. **Frame and seal.** The attachment encodes the envelope through ``KeepTalkingEnvelopePacket`` and seals the packet with the room's payload key, derived from the context secret. Transport does *not* fragment: a frame past the 1 MiB ceiling throws `envelopeTooLarge`, on the principle that producing an envelope that fits is the publisher's job (that is what the sync layer's paging is for).

6. **Route and queue.** A message's kind puts it on the `interactive` lane, and it names no target peer, so it goes to the whole room. A room on the SFU gets one publish on the SFU's interactive stream, which the SFU fans out; a small room on the mesh gets the frame queued for every known member, drained by whichever link carries each one. Neither waits for a connection: a member with no link yet keeps the frame in its queue until one comes up. Only when there is no route at all does the send throw.

7. **Peer receive.** The remote host hands the frame to the attachment for its topic, which opens it with the room's key — anything else does not open — decodes the packet, and drops it if it names another context. There is no dedup here: a resync may well deliver a copy again, which is safe because every kind but the trust request is idempotent. Trust envelopes go to the handshake, and everything else to the client's handlers.

8. **Dispatch and persist.** The client's envelope controller assembles a ``KeepTalkingEnvelopeAsyncHandlers`` table — messaging, node, context-sync, action-call, action-catalog, voice, blob negotiation — and dispatches on kind. The messaging handler filters out rows it already holds, saves what is new, and re-drives any attachments that arrived ahead of their parent. The host's `envelopes` signal fires only if that handler reports it actually applied something, so a redelivered message lands silently.

9. **Repair, if needed.** If step 6 threw, the outbox drains when the room reports it can take sends again, and again when a peer comes online — the latter through the context-maintenance dispatcher, which owns the whole node-online task set (node-state broadcast, context and transcript sync, attachment recovery, outbox drain) rather than scattering it across callbacks. A member whose traffic moved to another link runs the same pass, because whatever went into the old connection may be gone. Anything still missing is reconciled by the three-phase context sync — compare per-sender summaries, request the tail past each cursor, then repair any diverging chunk — which runs the same algorithm over messages and voice transcript lines through a shared stream abstraction, one reconcile per peer at a time. Side notes reconcile on a different shape: a digest over `(key, counter, writer, archived)` for the whole set, tombstones included, resolved by a monotonic counter with the writer's ID breaking ties, so two partitioned nodes reach the same answer without agreeing on a clock.

## Separations that matter

### Clients know nothing about iroh

The client depends only on the transport-neutral seam: attach a room, send an envelope to the room or to its target peer, send a datagram, open a blob stream, read the room's status. There is no reference in the client to SFU frames, topics, endpoint IDs, links, or Bluetooth. iroh lives entirely behind ``KeepTalkingTransport/iroh(_:)``.

The division of labour follows from that. The transport reports what it sees — a link to a member came up, a member's traffic moved to another link, the room can take sends again, its status changed — and owns recovery: reconnecting the SFU, redialling links, abandoning a connection that lost every path. The client owns what only it can judge: liveness and the presence heartbeat, the offline→online edge, and the resync each edge runs. Nothing on either side polls a socket to ask whether it is alive.

How an envelope travels stays a *declared* property rather than a scattered one. ``KeepTalkingEnvelopeKind`` answers ``KeepTalkingEnvelopeKind/delivery`` once — a lane and an idempotence claim — and every send inherits it. Adding a kind means answering those two questions in an exhaustive switch the compiler checks; it never means editing the transport.

The practical payoff is testability. The client can be exercised against a fake multiplexer and attachment with no network at all, and the host's own decisions — dialling, membership, routing, room status — are pure values tested without iroh.

### Connectors hide vendor wire formats

``AIConnector`` is the single seam wrapping every LLM backend:

```swift
let result = try await connector.completeTurn(
    messages: [AIMessage(role: .user, content: .text("summarise this thread"))],
    tools: tools,
    model: "openai/gpt-5-codex",
    toolChoice: nil,
    stage: .planning,
    configuration: nil,
    toolExecutor: nil
)
```

Every type in that call is KT-native. ``AIMessage`` is the intermediate representation — four roles, optional multimodal content, tool calls carrying their own IDs — and each connector translates it to its provider's shape internally. ``AITurnResult`` comes back with assistant text, optional reasoning, tool calls, and optional audio. The SDK never constructs a vendor type at a call site, which is why adding a provider means adding one connector and changing nothing upstream.

Behaviour differences are handled by declaration rather than by branching on provider identity. ``AIConnectorCapabilities`` states whether the backend supports native tool calling and whether it can surface reasoning; when native tool calling is absent, the agent loop falls back to explicit prompting without needing to know which vendor it is talking to.

The same discipline extends outward. Action tools reach the model as ``KeepTalkingActionToolDefinition`` regardless of whether the underlying executor is an MCP server, a skill script, a filesystem operation, or a platform primitive — the executor family is an implementation detail of the catalog, not of the prompt.

### IO is centralised

Action and skill I/O lives in one place, under `Services/IO`, and the rule it enforces is that resources are emitted and collected through the IO runtime rather than discovered by the model.

The IO manager owns the per-run contract end to end: binding an action's declared objects to concrete inputs and outputs, building the run's ``KTResourceManifest``, granting directories, harvesting outputs when the run finishes, delivering produced resources, and cleaning up afterwards. Its staging runtime collects ready context attachments, resolves staged one-time-blob handles into the same run directory, and tracks the scratch directories the run owns, delegating durable staged-handle storage — and the quota and TTL enforcement on it — to a dedicated store actor. AI-facing presentation is an extension on the manager itself rather than a fourth object: tool-result messages, native attachment injection, context-resource readouts, voice transcript readouts, and produced-resource transcript injection. All of it is internal — the surface the rest of the SDK sees is the manifest and the binding.

``KTResourceManifest`` is the per-run *description* handed to the agent. Every file or directory a run may touch becomes an entry with a stable `KT_<KIND>_<HEX>` handle, and the same entry array drives both the injected environment variables and the agent-facing prompt block, so the two cannot diverge. It describes what the run can read and write; it is explicitly not the place to stage files or fetch attachments. ``KTCallBinding`` is its counterpart on the way in — the path-free, device-side projection of one declared object.

The consequence for the model is one vocabulary and one path. Handles name files; resources arrive through the turn's presentation path; there is no second retrieval tool for the agent to reach for. When this pipeline misbehaves, the fix belongs inside it — not in another client-side staging or attachment shim.

## Topics

### Client Layer

- ``KeepTalkingClient``
- ``KeepTalkingConfig``
- ``KeepTalkingClientError``

### Controller Surface

- ``KeepTalkingAgentRunSnapshot``
- ``KeepTalkingAgentTurnSuspension``
- ``KeepTalkingAgentTurnResumption``
- ``KeepTalkingActionSummary``
- ``KeepTalkingActionCallActivity``
- ``KeepTalkingNodeTrustScope``
- ``KeepTalkingMessagePageDirection``

### Domain Models

- ``KeepTalkingContext``
- ``KeepTalkingContextMessage``
- ``KeepTalkingThread``
- ``KeepTalkingNode``
- ``KeepTalkingAction``
- ``KeepTalkingMapping``
- ``KeepTalkingNodeRelation``
- ``KeepTalkingOutboxEntry``
- ``KeepTalkingSideNote``
- ``KeepTalkingActionScope``
- ``KeepTalkingGrantTransaction``

### Persistence

- ``KeepTalkingLocalStore``
- ``KeepTalkingModelStore``
- ``KeepTalkingInMemoryStore``
- ``KeepTalkingKeychainStore``

### Envelope Layer

- ``KeepTalkingEnvelope``
- ``KeepTalkingEnvelopeKind``
- ``KeepTalkingEnvelopeDelivery``
- ``KeepTalkingEnvelopePacket``
- ``KeepTalkingEnvelopeHandlers``
- ``KeepTalkingEnvelopeAsyncHandlers``

### Transport Layer

- ``KeepTalkingTransport``
- ``KeepTalkingIrohTransportHost``
- ``KeepTalkingIrohDeliveryPolicy``
- ``KeepTalkingTransportStatus``
- ``KeepTalkingRuntimeStats``

### AI Connector Layer

- ``AIConnector``
- ``AIConnectorCapabilities``
- ``AIMessage``
- ``AIToolCall``
- ``AIToolChoice``
- ``AITurnResult``
- ``AITurnConfiguration``
- ``OpenAIConnector``
- ``AnthropicConnector``
- ``AIOrchestrator``

### Execution and Runtime I/O

- ``KTResourceManifest``
- ``KTCallBinding``
- ``KeepTalkingActionToolDefinition``
- ``SkillManager``
- ``MCPManager``
- ``PrimitiveActionManager``
- ``FilesystemActionManager``
- ``SemanticRetrievalActionManager``
- ``KeepTalkingSkillPlanner``
- ``KeepTalkingThreadWorkspaceManager``
- ``KTSandboxPolicy``

### Sync, Presence, and Media

- ``KeepTalkingContextSyncMetadata``
- ``KeepTalkingContextSyncEnvelope``
- ``KeepTalkingContextSyncEvent``
- ``KeepTalkingSideNoteVersion``
- ``KeepTalkingSemanticStore``
- ``KeepTalkingVoiceSession``
- ``KeepTalkingBlobStore``
- ``KeepTalkingBlobReferenceIndex``
- ``KeepTalkingOneTimeBlobRef``

## Database admission

Every `Database` a store hands out is gated. An operation first takes a permit
on a ``KeepTalkingDatabaseLane`` — `interactive`, `utility` or `background` —
and only then runs; the lane comes from ``withDatabaseLane(_:_:)``
or, absent that, from the task's priority. Each lane has a width, utility and
background together can never take every connection, one writer runs at a
time, and waiters are granted most-urgent-first. Sync, reconciliation and
whole-context scans run on `background`; a page the user is looking at runs on
`interactive` and never queues behind them.

A transaction holds one permit for its whole block and hands its closure the
raw connection. ``KeepTalkingDatabaseActivity`` reports granted operations
only, so a host's suspension guard sees held locks, not queued work.
``KeepTalkingKeyedCoalescer`` gives hosts single-flight, trailing refreshes on
a lane without holding a permit while they wait.
