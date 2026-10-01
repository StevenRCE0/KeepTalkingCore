# Events and Observation

The push surface a host application observes: the signals on ``KeepTalkingClient``, what emits them, what they carry, and the delivery contract they arrive under.

## Overview

A host does not poll ``KeepTalkingClient``. The client owns the transport, the local
database, the agent coordinator, and the executors, and it reports everything that
happens through **signals** — multicast values a host subscribes to with
``KeepTalkingObservable/observe(_:)`` or iterates with ``KeepTalkingObservable/values``.
Subscribe early (before ``KeepTalkingClient/connect()`` for anything transport-related)
and treat the signals as the only supported way to learn that something changed.

Every signal is a stored member of one box, ``KeepTalkingClientSignals``, reachable
as ``KeepTalkingClient/signals``. The client is `@dynamicMemberLookup` over that box, so
`client.envelopes` and `client.signals.envelopes` are the same handle; use whichever
reads better. Components that *produce* a signal — the connection, the agent
coordinator, the voice-call presence registry — are handed the box's handle at init
and only write it. Ownership is the client's; a signal is always the client
instance's view, never a hook on the component that happens to emit it.

Two primitives carry everything:

- ``KeepTalkingSignal`` is an **event signal**: it delivers each value sent after you
  subscribed and replays nothing.
- ``KeepTalkingStateSignal`` is an event signal with a synchronously readable
  ``KeepTalkingStateSignal/current`` value. Subscribing replays `current` first, so a
  late subscriber never starts from an unknown state. It is also `Observable`: a
  SwiftUI body that reads `current` re-renders when it changes, with no subscription
  and no mirror property in a view model.

Handlers that *return a decision* — ``KeepTalkingClient/setActionApprovalHandler(_:)``,
``KeepTalkingClient/setIncomingTrustHandler(_:)``, ``KeepTalkingClient/setActionCreationHandler(_:)``,
the MCP and ACP auth handlers, ``KeepTalkingClient/setSemanticSearchCallback(_:)`` — are
request/response seams, not events, and remain closures.

### The delivery contract

Every signal delivers **asynchronously, in emission order, one handler at a time, on
the signal's own task** — never inline on the code that produced the value. Nothing
hops to the main actor for you.

Under the hood each signal is one unbounded `AsyncStream` hub drained by one pump
task; `send` is a synchronous, non-blocking yield. Three consequences follow:

- A producer may emit while holding its own locks, and no handler can ever re-enter it.
  That is what lets the connection state machine publish from inside its transitions.
- Order is total. Two values sent from the same producer arrive in that order at every
  subscriber, and a state signal's replay is ordered against concurrent sends, so
  `current` can never disagree with the last value a subscriber saw.
- A slow handler delays the values behind it for *every* subscriber of that signal.
  Handlers are synchronous; a host that drives UI hops off the pump instead —
  ``KeepTalkingObservable/observeOnMain(_:)`` does the `Task { @MainActor in … }` for
  you and lets the handler await, at the cost that a suspended handler can be
  overtaken by the next value's hop.

A subscription lives as long as the signal unless you call
``KeepTalkingSignalSubscription/cancel()``. A ``KeepTalkingObservable/values`` stream ends
when its consuming task is cancelled or when the signal's owner is released, so a
`for await` over a client that went away finishes instead of hanging.

Order is total *within* one signal and undefined *across* signals: each has its own
pump, so ``KeepTalkingClientSignals/threadChanges`` and
``KeepTalkingClientSignals/semanticIndexReconciliations`` sent back-to-back by one
producer may land in either order. Write handlers as idempotent refreshes, not as
steps that depend on another signal having fired first.

Because each inbound envelope is still handled in its own task inside the SDK,
**delivery order between two different envelopes is not guaranteed** — the SDK buffers
attachment payloads that outrun their parent message and re-drives them when the
parent lands.

## Using the signal box

### Consuming

Three patterns cover every host. Pick by where the handler has to run, not by the
signal.

**UI state — `observeOnMain`.** Each value is hopped onto the main actor in its own
task; a state signal replays `current` first, so a model is correct on its first frame.
A host that swaps clients (one per conversation, say) must guard against a late
delivery from a client it has already discarded:

```swift
client.lifecycle.observeOnMain { [weak client] state in
    guard let client, model.isCurrent(client) else { return }
    model.connection = state
}
client.threadChanges.observeOnMain { _ in try? await model.threads.refresh() }
```

**Off-main work — `observe`.** Hot or heavy signals stay off the main actor. The handler
runs on the signal's pump; keep it short and spawn a task for anything that awaits:

```swift
client.log.observe { line in logger.debug("\(line)") }      // thousands/sec on reconnect
client.semanticIndexReconciliations.observe { contextID in
    Task { await index.reconcile(for: contextID) }
}
```

**Sequential logic — `values`.** When code needs to *wait for* a condition rather than
react to one, iterate the stream. A state signal replays `current` as the first
element, and the loop ends on task cancellation or when the client is released:

```swift
for await state in client.lifecycle.values {
    if state.isConnected { break }
    if case .connectFailed(let reason) = state.cause { throw ConnectError(reason) }
}
```

**Reading without subscribing.** State signals only:

```swift
if client.lifecycle.current.isConnected { … }
let online = client.presence.current.onlineNodeIDs
```

**Rendering state — Observation.** ``KeepTalkingStateSignal/current`` is
observation-tracked, so SwiftUI (or `withObservationTracking`) depends on it directly.
Only views that read a given signal re-render when it changes, and there is nothing to
subscribe, mirror, or guard against a discarded client — a view always reads the client
it was given:

```swift
struct ConnectionBadge: View {
    let client: KeepTalkingClient
    var body: some View {
        Label(client.lifecycle.current.phase.description,
              systemImage: client.presence.current.onlineNodeIDs.isEmpty ? "person" : "person.2")
    }
}
```

Observation delivers *invalidations*, not values: it coalesces and never replays
history, which is exactly right for state and exactly wrong for events. Event signals
are not `Observable`; use `observe` or `values` for those.

Subscribe before ``KeepTalkingClient/connect()`` for anything transport-related: an
event signal replays nothing, and ``KeepTalkingClientSignals/log`` in particular loses
the early transport traces otherwise.

### Subscription lifetime

``KeepTalkingObservable/observe(_:)`` returns a ``KeepTalkingSignalSubscription``. It is
`@discardableResult` because the default is right for most hosts: a subscription lives
as long as the signal, and the signal lives as long as the client. Keep the handle only
when the subscriber outlives the client — an app-wide adapter installed on every client
the host builds, for instance — and ``KeepTalkingSignalSubscription/cancel()`` it when
you let that client go. `cancel()` is idempotent and a no-op once the signal is gone.

### Producing — inside the SDK

Emitting is internal to the package; a host never sends. Inside a ``KeepTalkingClient``
extension, go through the box explicitly — dynamic member lookup applies to member
access (`client.x`), not to bare identifiers, so `sideNoteChanges.send(…)` does not
resolve:

```swift
extension KeepTalkingClient {
    func updateSideNote(in contextID: UUID, …) async throws {
        try await localStore.write(…)            // do the work first
        signals.sideNoteChanges.send(contextID)  // then tell the world
    }
}
```

`send` is a synchronous, non-blocking yield: a producer may call it while holding its
own locks, and no handler will ever re-enter it. State signals add a dedupe variant,
`send(ifChanged:)`, for `Equatable` values such as
``KeepTalkingClientSignals/transportStats``.

### Adding a signal

One stored member on ``KeepTalkingClientSignals`` with a doc comment; nothing else to
wire, because the client's subscript forwards any key path on the box:

```swift
/// A context's pinned summary was regenerated. Carries the context.
public let summaryRefreshes = KeepTalkingSignal<UUID>()
```

Two rules keep the flat namespace honest. A real member of ``KeepTalkingClient``
always shadows a dynamic one, so never add a client *method* whose base name matches a
signal. And link the symbol as ``KeepTalkingClientSignals/threadChanges``-style paths
in documentation — the forwarded names are not symbols.

When a component drives the signal, the box still owns it. Give the component the
handle at init, with a default so it can be built alone in tests:

```swift
final class SummaryEngine {
    let refreshes: KeepTalkingSignal<UUID>
    init(refreshes: KeepTalkingSignal<UUID> = .init()) { self.refreshes = refreshes }
    func regenerate(_ contextID: UUID) async { …; refreshes.send(contextID) }
}

// KeepTalkingClient.init, after the box exists:
self.summaryEngine = SummaryEngine(refreshes: signals.summaryRefreshes)
```

That is exactly how the connection, the agent coordinator (`AgentCoordinator(runs:)`)
and the presence registry (`KeepTalkingVoiceCallPresenceRegistry(changes:)`) are wired.

### Testing

Signals deliver asynchronously, so a test records and waits for a count rather than
asserting straight after the call. The package's `SignalRecorder` is the pattern:

```swift
@Test("a side-note edit pings its context once")
func sideNotePing() async throws {
    let client = try makeTestClient()             // real box, fake transport
    let pings = SignalRecorder<UUID>()
    client.sideNoteChanges.observe { pings.record($0) }

    try await client.updateSideNote(in: contextID, …)

    await pings.waitForCount(1)
    #expect(pings.snapshot == [contextID])
    await pings.settle()                          // "nothing more" needs the pump to drain
    #expect(pings.snapshot.count == 1)
}
```

A driven component is tested without a client at all: its default init gives it a
private signal, so `let engine = SummaryEngine()` followed by `engine.refreshes.observe`
exercises the same path.

### What stays a closure

Anything that *answers* rather than notifies. A signal is multicast and asynchronous;
a decision needs exactly one responder and a return value. If a design wants `observe`
to return something, it is a handler — see the request/response seams listed above.

## Lifecycle

### lifecycle

``KeepTalkingClientSignals/lifecycle`` is a state signal of ``KeepTalkingClientLifecycle``:
the connection ``KeepTalkingClientLifecycle/phase`` (`idle`, `connecting`, `connected`,
`disconnecting`), the lifecycle ``KeepTalkingClientLifecycle/generation``, the last
reported ``KeepTalkingClientLifecycle/transport`` health and
``KeepTalkingClientLifecycle/route``, and the ``KeepTalkingClientLifecycle/cause`` that
produced the value.

The sequences a host can rely on:

- ``KeepTalkingClient/connect()`` → `connecting` (`connectRequested`) → `connected`
  (`connected`). A connect that fails before the transport started goes straight to
  `idle` with `connectFailed(message)`; one that fails after it goes through
  `disconnecting` first, both values carrying `connectFailed`.
- ``KeepTalkingClient/disconnect()`` → `disconnecting` (`disconnectRequested`) →
  `idle` (`tornDown`) once the transport has actually stopped. The moment
  ``KeepTalkingClient/disconnectAndWait()`` returns, `current.phase` is `idle`.
  Calling `disconnect()` on an idle client publishes nothing.
- ``KeepTalkingClient/reestablishTransport()`` → `disconnecting` → `connecting` →
  `connected`, with no `idle` in between: the new generation supersedes the old
  teardown before it completes.
- While `connected`, a transport health or route change republishes `connected`
  with `transportChanged`. `transport` reads `.recovering` throughout `connecting`
  (the backbone is being brought up) and `.down` in every other phase; `route` is
  `.sfu` outside `connected`.

``KeepTalkingClient/transportHealth()`` remains the live read of the backbone;
`lifecycle.current.transport` is the last state the transport *reported*.

### presence

``KeepTalkingClientSignals/presence`` is a state signal of ``KeepTalkingClientPresence``: the
set of reachable remote peers and the ``KeepTalkingClientPresence/change`` that
produced it. `online` follows the transport's connect edge immediately; `offline`
comes from a sweep that runs every ten seconds while connected and diffs the liveness
window, so a peer that stopped announcing is reported within the 40-second window plus
one sweep. Teardown publishes `reset` with an empty set.

### transportStats

``KeepTalkingClientSignals/transportStats`` is a state signal of ``KeepTalkingRuntimeStats``,
sampled once a second while connected and published only when the counters changed.
It replaces polling ``KeepTalkingClient/runtimeStats()`` from a UI timer.

### executorRegistration

``KeepTalkingClientSignals/executorRegistration`` is a state signal of
``KeepTalkingExecutorRegistration`` reporting
``KeepTalkingClient/registerLocalActionsInExecutors()``: `registering(source:name:completed:total:)`
before each granted local action, `finalizing` while the tool catalog is rebuilt,
then `idle`.

## Message flow

### envelopes

``KeepTalkingClientSignals/envelopes`` is the widest signal: one `any KeepTalkingEnvelope`
per event. It fires from three places — the tail of inbound envelope handling, after
the SDK's own handlers ran and only when the envelope changed something locally; the
local echo of an outgoing message and each of its attachments; and the re-publish of a
continuation message whose state moved. Every payload is `Sendable`.

### rawMessages

``KeepTalkingClientSignals/rawMessages`` carries the transport's raw inbound text, for
diagnostics.

## Agent runs

- ``KeepTalkingClientSignals/agentRuns`` — a state signal with the flat list of
  ``KeepTalkingAgentRunSnapshot`` values, republished on every coordinator transition.
- ``KeepTalkingClientSignals/agentRunCompletions`` — one ``KeepTalkingAgentRunCompletion``
  per finished run, carrying the error's description on failure.
- ``KeepTalkingClientSignals/agentTurnSuspensions`` and ``KeepTalkingClientSignals/agentTurnResumptions``
  — a turn parked on an out-of-band continuation, and the same turn running again. A
  non-blocking driver (the voice bridge) acknowledges and detaches on the first and
  flips its UI back on the second.

## Threads, mappings, and notes

**Invalidation pings** carry little. ``KeepTalkingClientSignals/mappingChanges`` says "that
table moved" and expects the host to re-read; ``KeepTalkingClientSignals/threadChanges``
names the context whose threads changed, so a host re-reads that context's thread rows
and boundaries and nothing else. The SDK does not diff Fluent models across a
concurrency domain.

**Scoped invalidations** narrow that to one context: ``KeepTalkingClientSignals/sideNoteChanges``
and ``KeepTalkingClientSignals/semanticIndexReconciliations`` carry a context `UUID` — enough
to know *which* re-read to do. The second asks the host to enqueue best-effort
reconciliation of its derived semantic index; the persisted thread rows remain the
source of truth.

## Action calls and grants

- ``KeepTalkingClientSignals/actionCallActivities`` — ``KeepTalkingActionCallActivity``
  `began` / `ended(outcome)` pairs around every action call this node makes or serves.
- ``KeepTalkingClientSignals/grantCommits`` — one `[KeepTalkingGrantCommit]` batch per
  committed grant mutation, after the database work returned, one commit per peer
  whose access changed. Never emits when the mutation throws.
- ``KeepTalkingClientSignals/trustEstablishments`` — fires on both sides of a completed
  trust handshake with the peer and the context. At that instant the local relation
  is `.trusted`, so a grant issued from the handler rides the next node-status
  broadcast.

## Transport and peers

- ``KeepTalkingClientSignals/contextSyncEvents`` — ``KeepTalkingContextSyncEvent`` values
  (`started`, `messagesApplied`, `completed`, `failed`) correlated by `syncID`.
- ``KeepTalkingClientSignals/blobAvailabilityChanges`` — a blob became ready, went missing,
  or crossed a visible receive-progress step.

## Voice

- ``KeepTalkingClientSignals/voiceTranscriptLines`` — every persisted transcript line, own
  mic or a peer's, as the `Sendable` envelope payload.
- ``KeepTalkingClientSignals/voiceCallPresenceChanges`` — the affected context after
  every presence mutation; re-read the participants from
  ``KeepTalkingClient/voiceCallPresence``.

## Diagnostics

### log

``KeepTalkingClientSignals/log`` carries the diagnostic lines every layer of the SDK writes,
from the transport threads to the agent loops — thousands per second during a
reconnect storm. It is an event signal, so subscribe before ``KeepTalkingClient/connect()``
or early transport traces are lost. The transport and the skill and MCP managers are
handed the same sink at init, so nothing has to be forwarded by hand.

## Topics

### Primitives

- ``KeepTalkingClientSignals``
- ``KeepTalkingSignal``
- ``KeepTalkingStateSignal``
- ``KeepTalkingObservable``
- ``KeepTalkingSignalSubscription``

### Lifecycle

- ``KeepTalkingClientSignals/lifecycle``
- ``KeepTalkingClientLifecycle``
- ``KeepTalkingClient/TransportHealth``
- ``KeepTalkingClientSignals/presence``
- ``KeepTalkingClientPresence``
- ``KeepTalkingClientSignals/transportStats``
- ``KeepTalkingClientSignals/executorRegistration``
- ``KeepTalkingExecutorRegistration``

### Message flow

- ``KeepTalkingClientSignals/envelopes``
- ``KeepTalkingClientSignals/rawMessages``

### Agent runs

- ``KeepTalkingClientSignals/agentRuns``
- ``KeepTalkingClientSignals/agentRunCompletions``
- ``KeepTalkingAgentRunCompletion``
- ``KeepTalkingClientSignals/agentTurnSuspensions``
- ``KeepTalkingClientSignals/agentTurnResumptions``

### Threads, mappings, and notes

- ``KeepTalkingClientSignals/threadChanges``
- ``KeepTalkingClientSignals/mappingChanges``
- ``KeepTalkingClientSignals/sideNoteChanges``
- ``KeepTalkingClientSignals/semanticIndexReconciliations``

### Action calls and grants

- ``KeepTalkingClientSignals/actionCallActivities``
- ``KeepTalkingClientSignals/grantCommits``
- ``KeepTalkingClientSignals/trustEstablishments``
- ``KeepTalkingTrustEstablishment``

### Transport and peers

- ``KeepTalkingClientSignals/contextSyncEvents``
- ``KeepTalkingClientSignals/blobAvailabilityChanges``
- ``KeepTalkingBlobAvailabilityChange``

### Voice

- ``KeepTalkingClientSignals/voiceTranscriptLines``
- ``KeepTalkingClientSignals/voiceCallPresenceChanges``

### Diagnostics

- ``KeepTalkingClientSignals/log``
