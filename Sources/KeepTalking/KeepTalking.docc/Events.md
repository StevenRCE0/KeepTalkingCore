# Events and Observation

The push surface a host application observes: the callback properties on ``KeepTalkingClient``, what fires them, what they carry, and the concurrency contract they arrive under.

## Overview

A host does not poll ``KeepTalkingClient``. The client owns the transport, the local
database, the agent coordinator, and the executors, and it reports everything that
happens through a set of plain callback properties. Assign them once, before
``KeepTalkingClient/connect()``, and treat them as the only supported way to learn
that something changed.

The callbacks fall into three shapes, and the distinction is deliberate.

**Payload-carrying callbacks** hand you the thing that happened — an envelope, a
snapshot list, a transcript line, a sync event. Every payload is `Sendable`, which is
precisely why some of them are wire types rather than database models:
``KeepTalkingClient/onVoiceTranscriptLine``
delivers ``KeepTalkingVoiceCallTranscriptLinePayload`` (the envelope) instead of a
``KeepTalkingVoiceTranscriptLine`` (the Fluent row) so nothing non-`Sendable` crosses
the actor boundary.

**Invalidation pings** carry nothing at all. ``KeepTalkingClient/onThreadsChanged``
and ``KeepTalkingClient/onMappingsChanged`` simply say "that table moved" and expect
the host to re-read. The SDK does not try
to diff Fluent models across a concurrency domain; it invalidates and lets the host
query what it actually needs.

**Scoped invalidations** narrow that to one context.
``KeepTalkingClient/onSideNotesChanged`` and
``KeepTalkingClient/onSemanticIndexNeedsReconciliation`` carry a context `UUID` and
nothing else — enough to know *which* re-read to do, not what changed.

### The concurrency contract

Every handler is `@Sendable` and is invoked **inline, on whatever executor the
producing code happens to be running on**. Nothing hops to the main actor for you.

Most are synchronous, but four are `async` and are *awaited* by the code that
produced the event: ``KeepTalkingClient/onContextSync``,
``KeepTalkingClient/onSideNotesChanged``,
``KeepTalkingClient/onSemanticIndexNeedsReconciliation``, and
``KeepTalkingClient/onActionCallActivity``. Being awaited is not a courtesy — a slow
handler on any of them stalls the sync pass, the side-note write, the mark consumer,
or the action call that called it. Enqueue and return.

- Inbound-envelope callbacks run on the cooperative thread pool, inside the
  unstructured task the client spawned for that one envelope.
- Agent-run callbacks run on the agent coordinator's executor.
- Locally-originated callbacks — a message you sent, a thread you split, a mark you
  applied — run on your own calling task, before the call that triggered them
  returns.

Three consequences follow. First, a host that drives UI must hop itself, typically
with `Task { @MainActor in … }`. Second, a handler must not block: the envelope
handler sits directly in the receive path, and the log handler is called from every
executor in the SDK. Third, because each inbound envelope is handled in its own
task, **delivery order between two envelopes is not guaranteed** — the SDK itself
buffers attachment payloads that outrun their parent message and re-drives them when
the parent lands.

Two properties have side effects on assignment. Setting ``KeepTalkingClient/onAgentRunsChanged``
installs the closure directly into the internal agent coordinator, so assigning a
new closure replaces the old one and assigning `nil` detaches it. Setting
``KeepTalkingClient/onLog`` immediately forwards the handler to the transport client
and, on a background task, to the skill manager and the MCP manager — set it first,
before ``KeepTalkingClient/connect()``, or early transport traces are lost.

### Wiring it up

```swift
let client = KeepTalkingClient(config: config, localStore: store, keychain: keychain)

client.onLog = { line in logger.debug("\(line)") }

client.onEnvelope = { envelope in
    guard let message = envelope as? KeepTalkingContextMessage,
        let id = message.id
    else { return }
    Task { @MainActor in inbox.messageDidChange(id) }
}

client.onAgentRunsChanged = { runs in
    Task { @MainActor in inbox.runs = runs }
}

client.onPeerConnect = { nodeID in
    Task { @MainActor in inbox.markOnline(nodeID) }
}

// `async`, and awaited by the sync pass — hand off, never work inline.
client.onContextSync = { event in
    guard case .completed = event.phase else { return }
    Task { @MainActor in inbox.reload(event.contextID) }
}

try await client.connect()
```

## Message flow

### onEnvelope

``KeepTalkingClient/onEnvelope`` (``KeepTalkingClient/EnvelopeHandler``) is the
widest of the callbacks: one existential `any KeepTalkingEnvelope` per event.

It fires from three places.

The main one is the tail of inbound envelope handling. Every decrypted envelope is
dispatched to the SDK's own async handlers — messaging, node, context sync, action
call, action catalog, voice call — then offered to the active voice session, and only
then handed to the host. By the time your handler runs, the message row, attachment,
node status, or sync result has already been persisted. That ordering is the whole
point: the envelope is a *cue*, and the database is the source of truth.

Note that last step is now conditional. There is no dedup layer in the transport:
fan-out can reach a dual-connected peer over both the direct channel and the SFU, so
redelivery is routine, and duplicates are absorbed at persistence by row id. That
alone would still publish twice, and a host turns a second publish into a second
notification — so the three fan-out-eligible kinds (``KeepTalkingContextMessage``,
``KeepTalkingContextAttachmentDTO``, and ``KeepTalkingVoiceCallTranscriptLinePayload``)
report whether they actually applied anything, and a copy that changed nothing
locally is *not* handed to the host. Kinds with no registered handler always publish.

Not everything the transport sees reaches here. Trust-handshake envelopes are
consumed by the internal trust path, and raw `.p2pSignal` frames never leave the
transport. Peer presence, by contrast, *is* forwarded, as are the voice call
started / ended / signal envelopes.

The second trigger is local echo. The messaging path takes an `emitLocalEnvelope`
flag, default `false`, because a host that just called `send` already knows what it
sent. Internal producers set it to `true`: AI-authored assistant replies, the
`.haywire` markers published when an agent run fails or is cancelled, and the sealed
voice-call entry. When it is set, the ``KeepTalkingContextMessage`` is emitted first,
followed by one ``KeepTalkingContextAttachmentDTO`` per saved attachment.

The third trigger is agent-turn continuation state. When a continuation response
lands, the mutated message is re-emitted locally and *not* broadcast — each node
updates its own copy, because the message-sync dedup filter would drop the update on
the far side — so the local sink is the only refresh cue for a continuation bubble
flipping out of `.pending`. Bulk invalidation is the opposite case: when a run ends
and its stale continuations are marked `.cancelled`, the SDK re-sends those messages
over the transport but does **not** fire the local sink, so a host tracking a bubble
it cancelled itself must re-read rather than wait for an envelope.

Concrete types a host will see include ``KeepTalkingContextMessage``,
``KeepTalkingContextAttachmentDTO``, ``KeepTalkingContext``, ``KeepTalkingNode``,
``KeepTalkingNodeStatus``, ``KeepTalkingContextSyncEnvelope``,
``KeepTalkingP2PPresencePayload``, ``KeepTalkingVoiceCallStartedPayload``,
``KeepTalkingVoiceCallEndedPayload``, ``KeepTalkingVoiceCallTranscriptLinePayload``,
and the action-call and action-catalog request/result shapes. Discriminate with a
conditional cast, or coarsely with ``KeepTalkingEnvelopeKind`` if you only care
about chat versus service traffic.

The expected host behaviour is to filter for what it renders, then re-read from
``KeepTalkingClient/localStore`` — ``KeepTalkingClient/loadMessagePage(in:cursor:direction:limit:lowerBound:upperBound:)``
for the visible window — rather than treating the envelope itself as the render
model. A synced message may have been mutated after the envelope that announced it.

### onRawMessage

``KeepTalkingClient/onRawMessage`` (``KeepTalkingClient/RawMessageHandler``) carries a
single `String`. The client installs the transport client's raw seam at construction
time and forwards through it, gated on the connection lifecycle — a frame arriving
after ``KeepTalkingClient/connect()`` has been superseded by a disconnect is dropped
rather than delivered. The bundled SFU and P2P transports decode everything into
envelopes and never emit a raw frame, so in the shipped configuration this handler
does not fire; it exists as a diagnostic hook for a transport implementation that
surfaces undecoded text, and the development CLI prints it verbatim. Do not build
product behaviour on it.

## Agent runs

Four callbacks describe agent execution, and they are not redundant: the first two
track *runs* (the coordinator's scheduling unit), the second two track *turns*
parking on and returning from out-of-band work.

### onAgentRunsChanged

``KeepTalkingClient/onAgentRunsChanged`` delivers `[KeepTalkingAgentRunSnapshot]` —
the complete, freshly sorted list across every context, on every coordinator state
transition. It is a full replace, never a delta. Transitions that emit it: enqueue,
start, suspend, resume, cancel, retry, dismiss, and finish (clean or failed).

Each ``KeepTalkingAgentRunSnapshot`` carries `id` (the stable run identifier, and the
handle for cancel / retry / dismiss), `contextID`, `promptPreview` (the prompt clipped
to 120 characters), `createdAt`, `state`, and `agentTurnID` — which is `nil` for
delegated runs this node executes on behalf of a caller. `State` is `.queued`,
`.running`, `.suspended`, or `.failed(message:)`.

The list arrives pre-sorted: running first, then suspended, then queued, then failed,
with ties broken by `createdAt`. Render it in the order given.

The scheduling model is visible in the snapshots. A context serializes its own local
turns — at most one running, the rest queued and started automatically — but a
suspended turn frees its slot so the next can start, so one context can legitimately
show a suspended run alongside a running one. Delegated runs add work this node does
for others.

Host actions hang off the snapshot's `id`: ``KeepTalkingClient/cancelAgentRun(_:)``,
``KeepTalkingClient/retryAgentRun(_:)``, ``KeepTalkingClient/dismissAgentRun(_:)``.
Only failures of resumable local turns are parked as `.failed` and are therefore
retryable; a delegated run that fails has already unwound its awaiter and is discarded
rather than parked.

This handler runs on the coordinator's executor. Hop off it before calling back into
client APIs that re-enter the coordinator.

### onAgentRunCompleted

``KeepTalkingClient/onAgentRunCompleted`` fires once per run enqueued through
``KeepTalkingClient/enqueueAIPrompt(_:attachments:in:model:actModel:roleName:reasoningEffort:)``,
with `(contextID, error)`. It does not carry the run ID — this is the per-context
"the agent stopped working" cue, not a per-run one.

The error argument is subtler than it looks. A run that completed cleanly reports
`nil`. A run that *started* and was then cancelled also reports `nil`: cancellation
is an intentional stop and is treated as clean. But a run cancelled while still
queued — it never started, so its task can never deliver completion — has its
callback invoked directly with a `CancellationError`, so anything awaiting it unwinds
instead of hanging. Genuine failures report the thrown error.

Ordering: this fires *before* the coordinator's final state emission, so
``KeepTalkingClient/onAgentRunCompleted`` arrives ahead of the
``KeepTalkingClient/onAgentRunsChanged`` list that drops (or parks) the run.
Independently, and on their own tasks, the client publishes a `.haywire` marker into
the conversation on failure and invalidates any continuation bubbles the turn was
waiting on.

### onAgentTurnSuspended

``KeepTalkingClient/onAgentTurnSuspended`` fires the moment an agent turn parks on an
out-of-band continuation — after the `.agentTurnContinuation` bubble has been
persisted and broadcast, and immediately before the turn begins awaiting a response.
The triggers are a tool call that another node's user must answer, a local
authorization prompt, or an ask-for-file pick.

``KeepTalkingAgentTurnSuspension`` carries `agentTurnID`, `agentStepID` (the
persisted continuation message's id, identifying this exact inner continuation —
one run can suspend more than once), `contextID`, `kind` (the action kind that
caused the suspension — a primitive action's raw value, `"mcp"`, `"skill"`, or the
raw action id), and `targetNodeID`, the node that must respond before the turn can
resume.

This exists for drivers that cannot block. The voice bridge is the motivating case:
rather than hold a possibly-doomed voice session open across a remote round trip, it
acknowledges immediately and detaches, letting the turn finish in the background with
its answer landing in the conversation as an ordinary message.

### onAgentTurnResumed

``KeepTalkingClient/onAgentTurnResumed`` is the symmetric counterpart. It fires when
the awaited continuation is answered — **fulfilled or rejected, both count** — or when
an early response was already waiting when the turn suspended. It does *not* fire on
cancellation: cancellation throws out of the await and the task unwinds separately.

``KeepTalkingAgentTurnResumption`` carries `agentTurnID`, the matching `agentStepID`,
and `contextID`. The
outcome is deliberately not in the payload; a host that needs it reads the
continuation bubble's state from the message re-emitted on ``KeepTalkingClient/onEnvelope``.

A driver that detached on suspend uses this to flip its run's UI from "waiting" back
to "running". A host that renders the snapshot list instead already sees the same
transition as `.suspended` → `.running`.

## Threads, mappings, and notes

Four invalidation callbacks. The first two are zero-argument pings; the second two
carry a context `UUID` and are `async`. None of them describe *what* changed —
re-read, re-render, do not attempt to infer the delta from the callback alone.

### onThreadsChanged

``KeepTalkingClient/onThreadsChanged`` fires when a context's thread structure moves:
``KeepTalkingClient/toggleChitterChatter(messageID:in:)``,
``KeepTalkingClient/setChitterChatter(messageID:in:marked:)``, and
``KeepTalkingClient/markTurningPoint(at:in:)`` — which freezes the current
`.contextMain` thread as `.stored` and opens a new one at the turning-point message.
It also fires from the mark consumer, once per agent-authored turning-point or
chitter-chatter mark applied out of the message stream.

Archiving or deleting a thread does not ping — those are host-initiated and the caller
already knows. Re-read with ``KeepTalkingClient/threads(for:)``.

### onMappingsChanged

``KeepTalkingClient/onMappingsChanged`` fires when the SDK writes a name on the host's
behalf: applying a topic name to a thread stores it as a `.thread` alias mapping and
pings. Aliases and tags a host sets directly through the mapping API do not ping, for
the same reason. Re-read with ``KeepTalkingClient/aliasLookup()``.

Note that only the *agent-authored* turning point applies a topic name, so the
host-called ``KeepTalkingClient/markTurningPoint(at:in:)`` pings
``KeepTalkingClient/onThreadsChanged`` alone — the mark-consumer path pings both.

### onSideNotesChanged

``KeepTalkingClient/onSideNotesChanged`` delivers the affected context `UUID` whenever
a context's side notes move, from three directions: a local
``KeepTalkingClient/upsertSideNote(key:value:in:)`` or
``KeepTalkingClient/archiveSideNote(key:in:)``, an inbound `sideNotesPush` from a peer
that merged something new, and the full-set merge that rides the summary exchange of a
context sync pass.

That third case is why side notes are *not* a phase on ``KeepTalkingContextSyncEvent``:
the notification has to cover local writes and pushes too, not only changes observed
during a reconcile. Re-read the ``KeepTalkingSideNote`` rows for the context from
``KeepTalkingClient/localStore``; archived notes survive as tombstones so a merge can
tell "deleted" from "never seen", and both readers filter them out.

The handler is `async` and is awaited by the writer, so keep it short.

### onSemanticIndexNeedsReconciliation

``KeepTalkingClient/onSemanticIndexNeedsReconciliation`` delivers a context `UUID` and
is a *request*, not a notification: the semantic index is a derived cache the host
owns, and the SDK asks for it to be rebuilt after it has committed durable state that
the cache was computed from.

Today it fires from one place — the mark consumer, once per batch, after agent-authored
turning-point and chitter-chatter marks have been applied and the context's consumed-mark
list has been saved. The persisted thread rows remain the source of truth; the handler
should enqueue best-effort work and return promptly rather than reconcile inline.

## Action calls

### onActionCallActivity

``KeepTalkingClient/onActionCallActivity`` brackets a cross-node action call with a
``KeepTalkingActionCallActivity`` on each side: `.began` before the work starts and
`.ended` when it settles. `.ended` fires on **every** exit — success, thrown error, and
cancellation alike — so it is safe to use as the release for whatever `.began` acquired
(a wake assertion, a spinner, a keep-alive).

Both directions are bracketed: executing a request that arrived from a peer, and
dispatching one to a peer. A call this node both owns and runs is not — there is no
round trip to hold anything open for. Neither is the reserved cancellation call, nor
the macOS file-staging preflight; both short-circuit before the bracket.

The payload carries `requestID`, `contextID`, `actionID`, `callerNodeID`,
`targetNodeID`, and `phase`. It deliberately does not carry the result: a host that
needs the outcome reads the action-call result envelope on
``KeepTalkingClient/onEnvelope``, or the run's own completion callback.

Like the other id-carrying notices this handler is `async` and is awaited around the
call, so anything slow belongs on its own task.

## Transport and peers

### onPeerConnect

``KeepTalkingClient/onPeerConnect`` (``KeepTalkingClient/PeerConnectHandler``) delivers
the peer's node `UUID` once per offline→online **edge**. The liveness state computes
the edge from presence waves and direct-channel connects, so a peer beating steadily
produces exactly one call, not one per beat. It never fires for the local node.

It is dispatched at the head of the node-online maintenance task set, so it arrives
*before* the work it triggers. Immediately after your handler returns, and on the same
task, the client re-broadcasts local node state, re-asserts any active voice call,
runs context sync with that peer, syncs ongoing voice transcripts, drains the outbox,
and starts attachment recovery in the background. Treat this as "a peer appeared" and
expect ``KeepTalkingClient/onContextSync`` shortly after.

The outbox drain in that list is internal and has no callback. The delivery ledger is
entirely SDK-owned: ``KeepTalkingOutboxEntry`` rows are created after an outgoing
message is persisted and dropped once the transport accepts the envelope, they record
nothing about the attempt (existence *is* the retry), and there is no client API to
read or cancel them. A host that wants a pending indicator should derive it from its
own send state, not from the outbox — the message row is durable the moment `send`
returns, and context sync replicates it whether or not a row is still queued.

For the current picture rather than the edge, read ``KeepTalkingClient/isNodeOnline(_:)``
and ``KeepTalkingClient/onlineNodeIDs()``.

### onContextSync

``KeepTalkingClient/onContextSync`` (``KeepTalkingClient/ContextSyncHandler``) no
longer delivers a bare context `UUID` on success. It delivers a
``KeepTalkingContextSyncEvent`` tracking one reconciliation pass with **one** peer:
`syncID` (stable for the whole pass), `contextID`, `peerID`, and a `phase`.

The pass emits `.started` before any work, then `.messagesApplied([UUID])` for each
batch of message rows the reconcile persists — carrying exactly the ids that landed —
and finishes with either `.completed` or `.failed(String)`. A failed sync *does*
fire; it is not swallowed.

Because reconciliation is per peer and also runs on the maintenance heartbeat, a
context with several online peers produces one pass per peer per round. Passes are
single-flighted per peer, so a second request for a peer already syncing joins the
in-flight pass rather than starting a second one.

This is the "your history may have changed underneath you" cue. Reload the visible
message page and any derived thread or alias state. Because the handler is awaited by
the sync pass, do the reload on your own task rather than inline.

Side notes are *not* a phase here — the summary exchange does merge them, but the
change reports separately through ``KeepTalkingClient/onSideNotesChanged``, which also
covers local writes and peer pushes.

## Blobs

### onBlobAvailabilityChange

``KeepTalkingClient/onBlobAvailabilityChange`` (``KeepTalkingClient/BlobAvailabilityHandler``)
delivers `(contextID, blobID)`. The context is the client's configured context; the
blob ID is the content digest, which is also the blob's name in the store.

It fires on an inbound transfer reaching ``KeepTalkingBlobAvailability/ready`` —
covering the zero-byte case and the normal path, where the reassembled bytes are
digest-checked and the partial file is promoted into the blob store before the record
is upserted. It also fires on a digest mismatch, which discards the partial and marks
the record `.missing`, so a host is told the transfer died rather than being left on a
stalled placeholder.

Progress is reported too, but throttled: a `.partial` chunk fires only on the first
chunk, on the byte that completes the expected count, or when the received total
crosses a step of one chunk or 1% of the blob, whichever is larger. So a large
transfer yields roughly a hundred pings, not one per chunk. A deferred completion
whose bytes have not all arrived does **not** fire.

Because a fire no longer means "done", read the record before acting on one. The
expected host response is to find the attachments referencing that blob ID and, once
the record reads ``KeepTalkingBlobAvailability/ready``, replace the placeholder with
real content. The ``KeepTalkingBlobRecord`` row in ``KeepTalkingClient/localStore``
carries availability, MIME type, byte count, received bytes, and relative path — the
byte counts are what drive a progress bar.

## Voice

### onVoiceTranscriptLine

``KeepTalkingClient/onVoiceTranscriptLine`` fires on every path that persists a line
of a call's federated transcript, so a host can drive one live caption view without
caring where the line came from:

- **Local append or revision.** ``KeepTalkingClient/appendVoiceTranscriptLine(sessionID:contextID:text:source:lineID:)``
  persists this node's own speech, broadcasts it, and fires — including for in-place
  revisions as the live transcription evolves. A revision whose text is unchanged is a
  no-op and does not fire.
- **Peer line received.** An inbound line is persisted (or revised in place) and then
  fires. An unchanged duplicate is dropped silently. This node's own broadcast echoed
  back is ignored.
- **Sync backfill.** Lines recovered from a peer during transcript sync are merged and
  each fires, so a caption view folds in what it missed.

``KeepTalkingVoiceCallTranscriptLinePayload`` is the wire envelope itself, chosen so no
Fluent model crosses the actor boundary. It carries `from` (the authoring node — a node
only ever publishes its own mic), `contextID`, `sessionID` (the shared call identifier
every participant converges on), `lineID` (stable across revisions, so upsert by it),
`sequence` (a per-session, per-author monotonic cursor used for dedup and incremental
sync), `text`, `sender`, and `timestampMs`.

The `sender` is a ``KeepTalkingContextMessage/Sender``: `.node(node:)` for a human's
mic, `.autonomous(name:node:model:)` for the agent, whose `name` carries the wake
keyword so peers can label the line directly rather than guessing at a remote node's
configuration.

Lines from different authors interleave. Sort by timestamp then sequence — the same
total order ``KeepTalkingClient/voiceTranscriptLines(forSession:)`` returns.

``KeepTalkingClient/localVoiceAgentName`` is not a callback but belongs to this
surface: it is the display name for *this* node's voice agent, applied when authoring
`.realtime` lines. Leaving it `nil` — like receiving a peer-authored line whose wake
keyword this node does not know — falls back to `"ai"`.

Two related observation seams sit outside the client's own callbacks.
``KeepTalkingClient/voiceCallPresence`` is a ``KeepTalkingVoiceCallPresenceRegistry``
fed by inbound call started / ended envelopes; it has its own `onChange` closure taking
a context ID, and answers whether another participant has a joinable call this node has
not joined. A live ``KeepTalkingVoiceSession`` carries its own `onPeersChanged`,
`onInboundFrame`, `onStopped`, and `onLog` handlers, scoped to that one call.

## Diagnostics

### onLog

``KeepTalkingClient/onLog`` (``KeepTalkingClient/LogHandler``) receives every subsystem's
trace as a pre-formatted string, tagged by subsystem — `[continuation]`,
`[voice-transcript]`, `[outbox]`, `[marks]`, `[ai]`, `[client/blob]`, and so on.

Assigning it propagates the handler to the transport client synchronously and to the
skill manager and MCP manager on a background task, so set it before
``KeepTalkingClient/connect()``. It is high volume and is called from every executor
in the SDK: route it to a logging system, never to the UI, and never do work of
consequence inside it.

## Topics

### Message Flow

- ``KeepTalkingClient/onEnvelope``
- ``KeepTalkingClient/onRawMessage``
- ``KeepTalkingClient/EnvelopeHandler``
- ``KeepTalkingClient/RawMessageHandler``
- ``KeepTalkingEnvelope``
- ``KeepTalkingEnvelopeKind``
- ``KeepTalkingContextMessage``
- ``KeepTalkingContextAttachmentDTO``
- ``KeepTalkingClient/loadMessagePage(in:cursor:direction:limit:lowerBound:upperBound:)``

### Agent Runs

- ``KeepTalkingClient/onAgentRunsChanged``
- ``KeepTalkingClient/onAgentRunCompleted``
- ``KeepTalkingClient/onAgentTurnSuspended``
- ``KeepTalkingClient/onAgentTurnResumed``
- ``KeepTalkingAgentRunSnapshot``
- ``KeepTalkingAgentTurnSuspension``
- ``KeepTalkingAgentTurnResumption``
- ``KeepTalkingClient/cancelAgentRun(_:)``
- ``KeepTalkingClient/retryAgentRun(_:)``
- ``KeepTalkingClient/dismissAgentRun(_:)``

### Threads, Mappings, and Notes

- ``KeepTalkingClient/onThreadsChanged``
- ``KeepTalkingClient/onMappingsChanged``
- ``KeepTalkingClient/onSideNotesChanged``
- ``KeepTalkingClient/onSemanticIndexNeedsReconciliation``
- ``KeepTalkingThread``
- ``KeepTalkingMapping``
- ``KeepTalkingAliasLookup``
- ``KeepTalkingSideNote``
- ``KeepTalkingSideNoteDTO``
- ``KeepTalkingClient/threads(for:)``
- ``KeepTalkingClient/markTurningPoint(at:in:)``
- ``KeepTalkingClient/toggleChitterChatter(messageID:in:)``
- ``KeepTalkingClient/setChitterChatter(messageID:in:marked:)``
- ``KeepTalkingClient/aliasLookup()``
- ``KeepTalkingClient/upsertSideNote(key:value:in:)``
- ``KeepTalkingClient/archiveSideNote(key:in:)``

### Action Calls

- ``KeepTalkingClient/onActionCallActivity``
- ``KeepTalkingActionCallActivity``

### Transport and Peers

- ``KeepTalkingClient/onPeerConnect``
- ``KeepTalkingClient/onContextSync``
- ``KeepTalkingClient/PeerConnectHandler``
- ``KeepTalkingClient/ContextSyncHandler``
- ``KeepTalkingContextSyncEvent``
- ``KeepTalkingClient/isNodeOnline(_:)``
- ``KeepTalkingClient/onlineNodeIDs()``
- ``KeepTalkingP2PPresencePayload``
- ``KeepTalkingNodeStatus``

### Blobs

- ``KeepTalkingClient/onBlobAvailabilityChange``
- ``KeepTalkingClient/BlobAvailabilityHandler``
- ``KeepTalkingBlobRecord``
- ``KeepTalkingBlobAvailability``

### Voice

- ``KeepTalkingClient/onVoiceTranscriptLine``
- ``KeepTalkingClient/localVoiceAgentName``
- ``KeepTalkingClient/voiceCallPresence``
- ``KeepTalkingVoiceCallTranscriptLinePayload``
- ``KeepTalkingVoiceCallStartedPayload``
- ``KeepTalkingVoiceCallEndedPayload``
- ``KeepTalkingVoiceCallPresenceRegistry``
- ``KeepTalkingVoiceTranscriptLine``
- ``KeepTalkingVoiceTranscriptSource``
- ``KeepTalkingClient/voiceTranscriptLines(forSession:)``
- ``KeepTalkingClient/appendVoiceTranscriptLine(sessionID:contextID:text:source:lineID:)``

### Other Client Callbacks

Also on the push surface, not covered above.

- ``KeepTalkingClient/onSideNotesChanged``
- ``KeepTalkingClient/onSemanticIndexNeedsReconciliation``
- ``KeepTalkingClient/onActionCallActivity``
- ``KeepTalkingActionCallActivity``

### Diagnostics

- ``KeepTalkingClient/onLog``
- ``KeepTalkingClient/LogHandler``

### Related Articles

- <doc:GettingStarted>
