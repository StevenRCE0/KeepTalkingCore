# Architecture

How the SDK is layered — from the client façade down through services, routing, and envelope framing to the wire — and which seams keep those layers independent.

## Overview

The SDK is a stack of six layers. Each one is allowed to know about the layer directly beneath it and nothing else, and each boundary is drawn at a point where the implementation on the far side could be swapped without the near side noticing.

```
KeepTalkingClient          the façade a host talks to
  └── ClientControllers    one extension per concern
        └── Services       capability engines (AI, execution, sync, media)
              └── Transport      fan-out orchestrator + channels
                    └── Envelope       framing, kind tagging, typed dispatch
                          └── Models / Migrations   Fluent rows + schema
```

Two cross-cutting directories sit beside the stack rather than inside it: `Cryptos` holds key management, node identity, and the envelope/frame ciphers; `Helpers` holds shared primitives such as time-ordered UUIDv7 generation and MIME inference.

### Client

``KeepTalkingClient`` is the only object a host application constructs. One instance drives one conversation context, fixed at construction by ``KeepTalkingConfig`` — the channel labels the transport subscribes to are derived from the context ID, so moving to another context means building a fresh configuration with ``KeepTalkingConfig/withContextID(_:)`` and a second client rather than mutating the first.

The client owns the long-lived collaborators: the transport, the local store, the keychain, the AI connector, the execution managers, the blob store, and the agent coordinator. It also owns the *push surface* — a set of `@Sendable` callback properties (`onEnvelope`, `onPeerConnect`, `onContextSync`, `onBlobAvailabilityChange`, `onSideNotesChanged`, `onActionCallActivity`, `onAgentRunsChanged`, `onVoiceTranscriptLine`, and others) through which everything asynchronous is reported. Hosts observe the client; they do not poll it.

Bringing the transport up and registering local action executors are deliberately separate steps. ``KeepTalkingClient/connect()`` ensures the context row exists, starts the transport, persists this node, and begins the maintenance heartbeat — it does *not* register executors, because a failing executor (an HTTP MCP server needing re-authorization, say) must never block the transport or trigger an auth prompt as a side effect of connecting. Hosts that want executors live call ``KeepTalkingClient/registerLocalActionsInExecutors()`` explicitly.

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

``KeepTalkingContextTransport`` is a fan-out orchestrator and nothing more. It receives an envelope, asks the envelope's kind whether a direct path is permitted at all, and picks one of three shapes: broadcast only when direct is not allowed; the named peer's direct channel (falling back to broadcast) when the envelope carries a target; and, when it allows direct but names no target, a fan-out over every ready direct channel with broadcast covering the peers that have none. If nothing is available it throws. On the way back it consumes signaling internally, hands trust envelopes to their own sink, and forwards everything else upward.

There is deliberately no sequence number and no transport-level dedup. Fan-out can legitimately deliver the same envelope twice to a dual-connected peer, so instead of suppressing that in transport, every fan-out-eligible kind is required to be idempotent on receive and duplicate suppression is done at persistence, keyed on row ID.

Below it sit two concrete channel families: an always-on SFU broadcast backbone, and optional per-peer direct channels negotiated over libjuice-proved ICE with an HTTP/2 stream carrying the payload. Both are reached only through channel protocols. The direct mesh is capped: past ``KeepTalkingConfig/maxDirectMeshSize`` peers the transport tears the mesh down and stays on the SFU, and that verdict is re-armed when ``KeepTalkingNetworkEnvironment``'s interface digest changes under it — a decision reached on one network is not valid on the next.

### Envelope

The envelope layer is the wire contract. ``KeepTalkingEnvelope`` is a `Codable & Sendable` protocol whose conformers declare a static ``KeepTalkingEnvelopeKind``; everything else — whether a direct path is permitted, whether the kind may fan out, which logical channel it belongs to — is *derived* from that kind rather than restated per payload. Chat, attachment, transcript-line and action-call payloads set ``KeepTalkingEnvelopeKind/allowsDirect`` because latency wins; signaling, trust, voice setup, context sync, and service envelopes leave it `false` because they must reach peers no direct channel exists for yet. ``KeepTalkingEnvelopeKind/isFanOutEligible`` is the narrower claim on top: only `message`, `attachment` and `voiceCallTranscriptLine` are both broadcast-addressed and safe to deliver twice, so only those can physically fan out.

Domain models are retrofitted onto this protocol by extensions in `Envelope/Models/`, so ``KeepTalkingContextMessage`` — the persisted row — *is* the wire payload. There is no parallel DTO hierarchy to keep in sync for those types.

``KeepTalkingEnvelopePacket`` performs kind-tagged coding: it writes the kind alongside the payload and, on decode, dispatches on the kind to reconstruct the concrete type behind an existential. Sender identity rides one level lower, on the encrypted packet-transport envelope the channel builds; no sequence number is carried, because nothing downstream dedups on one. Inbound dispatch is table-driven through ``KeepTalkingEnvelopeAsyncHandlers``, which registers one typed handler per kind and downcasts at the boundary. A handler registered through `registerReportingApplied(_:_:)` returns whether the envelope actually changed anything locally, and a `false` suppresses the outward `onEnvelope` publish — that is what keeps fan-out's second copy from raising a second notification.

### Models and migrations

`Models/` holds the Fluent models — contexts, messages, attachments, threads and thread workspaces, nodes, node relations and node identity keys, actions, mappings, blob records, outbox entries, side notes, trust invitations, voice transcript lines — along with the pure value types (action bundles, action scopes and grant transactions, call requests and results, push-wake shapes) that travel with them. Voice *calls* are not among them: they live in memory keyed by session ID, and only their transcript lines are durable.

`Migrations/` holds the ordered schema migration list — mostly one create per table, plus the additive and drop steps the schema has accumulated since. They are internal by design: the schema is not part of the SDK's API. ``KeepTalkingModelStore`` registers that list and installs the message and attachment touch middleware that forward-only advances a context's `updatedAt` when a child row is written.

Construction and migration are deliberately separate. ``KeepTalkingModelStore/init(databaseURL:databaseFileName:databaseID:logger:)`` is synchronous and does no I/O; ``KeepTalkingModelStore/migrate()`` applies the migrations and must complete before the store is queried. Splitting them means a caller that cannot `await` never has to bridge with a semaphore. Callers already in an async context use ``KeepTalkingModelStore/make(databaseURL:databaseFileName:databaseID:logger:)``, which does both. Hosts that need a different backing store conform to ``KeepTalkingLocalStore`` instead; ``KeepTalkingInMemoryStore`` is the non-persistent equivalent used by tests and previews.

## The concurrency model

The package builds with Swift 6.1 under strict concurrency, so every type that crosses a boundary is `Sendable` and every callback is `@Sendable`.

**Services are actors.** ``SkillManager``, ``MCPManager``, ``PrimitiveActionManager``, ``FilesystemActionManager``, ``SemanticRetrievalActionManager``, ``KeepTalkingThreadWorkspaceManager``, and ``KeepTalkingSkillPlanner`` are all actors, as is the internal agent coordinator. Their mutable registries — which action IDs map to which live executor, which runs are queued — are actor state, never lock-guarded fields.

**Connectors are actors by contract.** ``AIConnector`` is declared `protocol AIConnector: Actor, Sendable`, which forces every provider implementation into actor isolation. Its one synchronously-readable member, ``AIConnectorCapabilities``, is `nonisolated` precisely so the agent loop can consult it while building a turn without awaiting the connector.

**The client is not an actor.** ``KeepTalkingClient`` is a `final class` marked `@unchecked Sendable`. It has to be: it is the fan-in point for callbacks arriving on carrier threads, and making it an actor would force every inbound envelope through a single executor and serialise unrelated work. Instead it guards each independent piece of bookkeeping with its own dedicated dispatch queue — one for action calls, one for action catalogs, one for the trust handshake — plus locks for teardown state and for buffered orphan attachments. Request/response correlation is expressed as maps of `CheckedContinuation` under those queues, and per-result-type registries own the pending continuations and timeouts for each sync stream.

**The transport is callback-driven, not async.** `sendEnvelope` is a synchronous throwing call, which is what lets a send participate in a tight failure path without suspension. Inbound bytes arrive on carrier threads and are handed up through `@Sendable` closures; the client re-enters structured concurrency by spawning a fresh `Task` per envelope. That is also why an attachment can be persisted before the message it belongs to — each envelope gets its own task — and why the messaging controller buffers orphan attachments keyed by parent message ID and re-drives them when the parent lands.

**Teardown is deliberately detached.** Stopping the transport synchronously joins carrier worker threads and can block for hundreds of milliseconds, so `disconnect()` does the cheap bookkeeping inline (failing pending continuations, cancelling the maintenance loop) and dispatches the real stop to a detached task. ``KeepTalkingClient/connect()`` awaits any in-flight teardown before restarting, so a tight disconnect-then-connect sequence still serialises correctly.

**Agent runs are coordinated, not merely queued.** A context's local turns are serialised — at most one active, the rest queued and started automatically — but a turn that suspends to await an out-of-band continuation frees its slot so the next can begin, and delegated runs (work this node performs on behalf of a caller) share the same coordinator.

**Channel state machines are pure values.** ``BroadcastChannelStateMachine`` and ``DirectChannelStateMachine`` are `Sendable` structs that take an event and return a new state plus an effect to execute. They perform no I/O and never probe a carrier; readiness is a signal *pushed* by the carrier, which makes the reconnect and backoff logic fully testable in isolation.

## A message, end to end

```swift
import KeepTalkingSDK

let config = KeepTalkingConfig(
    contextID: contextID,
    node: nodeID,
    sfuEndpoint: .init(host: "127.0.0.1")
)

let store = try await KeepTalkingModelStore.make()
let client = KeepTalkingClient(config: config, localStore: store)

client.onEnvelope = { envelope in
    print(envelope.kind, envelope.channel)
}

try await client.connect()
try await client.send("hello", in: config.contextID)
```

What that last line sets in motion:

1. **Persist first.** The messaging controller refuses oversize content *before* any row exists — a message that can neither be sent nor replicated would otherwise leave a retry row that never drains. The content ceiling is set at half the envelope ceiling, because the check runs on plaintext while the envelope limit applies after sealing and base64/JSON framing have inflated it. It then resolves the local node, upserts the context, and builds a ``KeepTalkingContextMessage`` with a time-ordered UUIDv7 primary key. The row is saved through Fluent; the touch middleware advances the context's `updatedAt` as a side effect of that save. Attachments are persisted next.

2. **Ensure the secret.** The context's group chat secret is created if absent, because the transport will need it to encrypt the payload.

3. **Enqueue before sending.** A ``KeepTalkingOutboxEntry`` is written *before* the transport push. From this point transport failures no longer throw: the message already exists locally, so the push is simply left to drain later. The outbox is "existence is retry" — the row carries no attempt count, and it is cleared only when a send is accepted. The one exception is an oversize envelope, which fails identically on every retry and so is dropped from the ledger rather than retried forever; the message row itself always stays, and context sync can still replicate it.

4. **Hand to the transport.** The model conforms to ``KeepTalkingEnvelope``, so it is passed directly to `sendEnvelope` with no conversion step.

5. **Fan out.** ``KeepTalkingContextTransport`` asks the envelope's kind whether direct is permitted. A message answers yes and carries no target peer, so it takes the fan-out shape: the envelope goes down every ready direct channel, and the broadcast backbone is sent it too, covering peers no direct channel exists for. A failing direct leg is logged and skipped rather than aborting the others — the SFU leg still covers that peer. No sequence number is attached and no route is "chosen"; there is no strategy object to consult.

6. **Frame and encrypt.** Each channel encodes the envelope through ``KeepTalkingEnvelopePacket``, seals the payload under the context secret into an encrypted packet-transport envelope carrying the sender node, and writes it out — over the SFU's authenticated HTTP/2 connection, or over the direct HTTP/2 stream on the libjuice-proved path. Transport does *not* fragment: an encoded payload past the 1 MB ceiling throws `KeepTalkingTransportError.envelopeTooLarge`, on the principle that producing an envelope that fits is the publisher's job (that is what the sync layer's paging is for).

7. **Peer receive.** The remote carrier decrypts, then hands the envelope to its transport. There is no dedup here — a dual-connected peer may well receive both copies, which is safe precisely because only idempotent kinds are allowed to fan out. The transport consumes P2P signaling internally so it never reaches the application, routes trust envelopes to their own handler, and forwards the rest upward.

8. **Dispatch and persist.** The client's envelope controller assembles a ``KeepTalkingEnvelopeAsyncHandlers`` table — messaging, node, context-sync, action-call, action-catalog, voice — and dispatches on kind. The messaging handler filters out rows it already holds, saves what is new, and re-drives any attachments that arrived ahead of their parent. The host's own `onEnvelope` callback fires only if that handler reports it actually applied something, so the second copy of a fanned-out message lands silently.

9. **Repair, if needed.** If step 5 failed, the outbox drains when the broadcast channel signals ready, and again when a peer comes online — the latter through the context-maintenance dispatcher, which owns the whole node-online task set (presence re-broadcast, context and transcript sync, attachment recovery, outbox drain) rather than scattering it across callbacks. Anything still missing is reconciled by the three-phase context sync — compare per-sender summaries, request the tail past each cursor, then repair any diverging chunk — which runs the same algorithm over messages and voice transcript lines through a shared stream abstraction, one reconcile per peer at a time. Side notes reconcile on a different shape: a digest over `(key, counter, writer, archived)` for the whole set, tombstones included, resolved by a monotonic counter with the writer's ID breaking ties, so two partitioned nodes reach the same answer without agreeing on a clock.

## Separations that matter

### ContextTransport knows nothing about WebRTC or ICE

``KeepTalkingContextTransport`` depends only on the channel protocols. There is no reference in it to SFU frames, ICE candidates, SDP, or data channels. Its entire vocabulary is: is a channel ready, does this envelope's kind permit a direct path, does it name a target peer.

That is what keeps the direct/broadcast decision a *declared* property rather than a scattered one. ``KeepTalkingEnvelopeKind`` answers ``KeepTalkingEnvelopeKind/allowsDirect`` and ``KeepTalkingEnvelopeKind/isFanOutEligible`` once, and every send inherits both. Adding a kind means answering those two questions; it never means editing the transport.

Note what those answers are *not*. `allowsDirect` is a permission, not a route — the transport still picks between the directed and fanned-out shapes based on whether the envelope names a target. And `isFanOutEligible` is a claim about idempotence on receive, which is why exactly three kinds hold it: `.voiceCallSignal` and `.trustRequest` are known *not* to be redelivery-safe (re-applying an SDP can tear down a connected ICE agent; a second trust prompt mints a fresh ephemeral key and strands the handshake), and both are kept off the fan-out path by being `allowsDirect == false`.

Below the protocols, carriers self-report liveness — ICE consent freshness, HTTP/2 keepalive PINGs every 2s on idle with a 5s read deadline — and flip readiness through `onStateChange` within a bounded window. The state machines react to that push. Nothing in the stack polls a socket to ask whether it is alive.

The practical payoff is testability: the broadcast channel and the direct-channel factory are both injected, so the transport can be exercised with fakes — including a scripted network-environment digest, which lets a test drive a network change without touching a real interface — and the state machines can be driven event-by-event, with no network at all.

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
- ``KeepTalkingEnvelopeChannel``
- ``KeepTalkingEnvelopePacket``
- ``KeepTalkingEnvelopeHandlers``
- ``KeepTalkingEnvelopeAsyncHandlers``

### Transport Layer

- ``KeepTalkingContextTransport``
- ``KeepTalkingTransportRoute``
- ``KeepTalkingNetworkEnvironment``
- ``BroadcastChannelState``
- ``BroadcastChannelStateMachine``
- ``DirectChannelState``
- ``DirectChannelStateMachine``
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
