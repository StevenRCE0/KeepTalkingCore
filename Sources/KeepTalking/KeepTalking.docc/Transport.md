# Transport

How KeepTalking moves envelopes, presence, sync traffic, and blob bytes between nodes over an SFU broadcast backbone and optional direct peer-to-peer channels.

## Overview

The transport layer is deliberately split in two. The orchestrator decides *whether* a
message goes direct or through the server and *what to do when that fails*; the channels
decide *how bytes actually reach the wire*. ``KeepTalkingContextTransport`` implements the
first half and knows nothing about the second: it depends only on the internal channel
protocols (`KeepTalkingTransportChannelProtocol`, and its broadcast and peer refinements)
plus two declarative properties of the envelope's kind. There is no ICE, WebRTC, SDP, or
data-channel vocabulary anywhere in it. That is why the direct path could be re-implemented
— WebRTC data channels replaced by libjuice ICE, then QUIC replaced by HTTP/2 over TLS —
without the routing code changing at all, and why tests can inject a fake channel factory
and exercise routing with no network.

Below the orchestrator sit exactly two concrete channels:

- **SFU broadcast** — the always-on backbone, backed by the `KeepTalkingSFU` package. Every
  node in a context is connected to it, and every routing decision can fall back to it.
- **P2P direct** — an optional per-peer upgrade using `SwiftJUICE` (libjuice ICE) to prove
  a path and SwiftNIO to carry the payload. It is negotiated *over* the broadcast backbone,
  so it is never a bootstrap dependency.

> Important: The transport requires a reachable **KeepTalkingSFU signalling server**. Set
> ``KeepTalkingConfig/sfuEndpoint`` before connecting; with no endpoint configured the
> broadcast channel fails to start, and because P2P negotiation is signalled over that same
> backbone, no direct channel can form either.

```swift
let config = KeepTalkingConfig(
    contextID: contextID,
    node: nodeID,
    sfuEndpoint: KeepTalkingConfig.SFUEndpoint(host: "127.0.0.1")
)

let store = try await KeepTalkingModelStore.make()
let client = KeepTalkingClient(config: config, localStore: store)
try await client.connect()
```

### Channels behind a protocol

A channel is a small contract: report ``KeepTalkingTransportRoute``, report readiness, send
a ``KeepTalkingEnvelope``, send raw blob bytes, and push inbound frames and state
changes back through callbacks. The broadcast refinement adds start/stop, raw envelope
sends for presence and signalling, a realtime byte path, a liveness probe, and
``KeepTalkingRuntimeStats``. The peer refinement adds the peer's node ID, the upgrade
handshake (`attemptUpgrade`, `requestRetrial`, `teardown`), and the hook the orchestrator
uses to ship signalling out over the backbone.

Readiness is *pushed, never polled*. The protocol carries an explicit liveness contract:
a channel must surface connection loss through its state-change callback within roughly
five seconds of silence on the wire, not "eventually, when an OS keepalive trips". Both
concrete carriers honour that with an HTTP/2 keepalive handler that pings on idle and
closes the channel after a read deadline, plus `SO_KEEPALIVE` on the socket as a coarse
backstop. The channel's `closeFuture` flips state, and the state machines take it from
there.

Those state machines are pure values — event in, new state and an effect out, no I/O, no
async, fully testable. ``BroadcastChannelStateMachine`` walks `connecting → ready`, drops
to `reconnecting(attempt:)` on degradation and **never gives up**, incrementing the attempt
and re-arming with exponential backoff capped at eight seconds. `failed` is reached only by
an explicit stop or by a degradation that arrives before the channel ever became ready — a
live channel never lands there, which is what lets ``KeepTalkingClient/transportHealth()``
read `down` as "worth re-establishing". ``DirectChannelStateMachine`` walks
`idle → negotiating → ready`, treats a connection-level failure while live as a retry
rather than parking in `interrupted`, and backs off `2·2^(n-1)` seconds up to sixteen.
After three failures the peer is `abandoned`
and the channel stops trying until something explicitly requests a retrial — the circuit
breaker that keeps an unreachable peer (symmetric NAT, no TURN) from gathering candidates
forever.

### The SFU broadcast backbone

The broadcast channel wraps an SFU client speaking the `KeepTalkingSFU` protocol over
HTTP/2. Each connection authenticates with a fresh Ed25519 key from
``KeepTalkingSFUSigningKey`` — SFU peer identity is intentionally process-local and
disposable, because the server routes by signing public key rather than by KeepTalking node
UUID, and one node may run several per-context clients at once.

The server never sees plaintext. Envelopes that declare a transport context are sealed with
that context's group secret before they are handed to the SFU; what crosses the wire is an
opaque encrypted packet plus a channel tag. Signalling and presence envelopes that carry no
transport context ride as plain packet JSON, which is what makes the trust handshake
bootstrappable.

Phase-1 semantics are broadcast-first: outbound envelopes fan out to the whole context and
`targetPeerNodeID` filters at the destination. Raw unicast is available underneath —
``KeepTalkingSFUJuiceSession`` exposes `routeRawBytes(_:to:channel:)` against a peer's
32-byte public key, along with a presence roster request and channel-aware inbound
dispatch, so a CLI or smoke test can drive an SFU round-trip without the full orchestrator.
The server also offers a mediated relay: ``KeepTalkingSFURelayCarrier`` wraps one
`RELAY_OPEN`/`RELAY_DATA`/`RELAY_CLOSE` conversation keyed by relay ID. The broadcast
channel opens and tracks carriers by relay ID and surfaces inbound opens, but the direct
channel does not yet reach for one when ICE fails — a peer that cannot form a direct path
falls back to ordinary broadcast, not to a relay.

Reconnection is the channel's own business. When the SFU client reports degradation, the
broadcast channel schedules a stop-then-restart with backoff and re-binds its callbacks —
the orchestrator only observes `isReady` flipping.

### The P2P direct channel

A direct channel exists per peer and is created lazily, on a real reachability edge — and
only while the context stays within ``KeepTalkingConfig/maxDirectMeshSize`` peers, above
which the mesh is torn down and the SFU carries everything, since a mesh costs one ICE agent
plus one HTTP/2 channel per peer per node. Its handshake has two stages carried by
``KeepTalkingP2PSignalPayload`` over the broadcast backbone, with the
``KeepTalkingP2PSignalData`` `kind` field selecting which:

1. `"juice-sdp"` — libjuice gathers candidates and emits a local SDP, which is signalled to
   the peer; the peer's SDP comes back the same way and connectivity checks run. This is
   the only thing ICE is used for: proving the path and revealing the selected address pair.
2. `"h2-port"` — the lexicographically lower node ID listens, the higher dials. The
   listener binds an ephemeral TCP port, publishes it (with its selected local host) as a
   signal, and the initiator opens a single long-lived bidirectional HTTP/2 stream to it.

Once the HTTP/2 carrier is connected the ICE session is closed — it has done its job.
Envelopes then travel as encrypted packet payloads inside DATA frames using a 4-byte
big-endian length prefix, so a blob frame and an envelope frame share one uniform record
format. HTTP/2 rather than raw TCP is a uniformity choice: the SDK already uses NIOHTTP2
for the SFU client, so the same TLS setup, keepalive handler, and certificate posture are
reused verbatim.

TLS here provides channel confidentiality only. Every listener mints a fresh P-256 key and
a short-lived self-signed certificate in process — no private key material ships in the
binary or touches disk — and the initiator does not verify it. Peer *authenticity* stays
where it belongs, in the public-key-bound envelope crypto layer.

Racing handshakes are handled explicitly. Each attempt carries an `attemptID` and an
`issuedAtMs` stamp, so an older SDP generation is ignored and a duplicate is dropped. When
a peer mints a new attempt while this side is mid-handshake or backing off, the new SDP is
stashed and applied on the *next* scheduled attempt rather than restarting immediately —
otherwise two peers that cannot complete ICE would ping-pong restarts at RTT speed, resetting
the failure counter each time and never tripping the circuit breaker. The handshake is
bounded by ``KeepTalkingConfig/p2pAttemptTimeoutSeconds``.

### Routing and fallback

Routing is an envelope-level decision, and the envelope's *kind* — not the call site —
declares the policy. ``KeepTalkingEnvelopeKind/allowsDirect`` is a permission rather than a
route. Signalling, presence, trust, and voice-call kinds return `false` because they must
reach every peer, including ones no direct channel exists for yet. Context sync returns
`false` because a reconcile has no direct-path delivery ack, so a stale P2P channel could
accept one and silently lose it. Service traffic — node state, action catalogs, agent turn
continuations — returns `false` too, because reliability beats latency there. User-visible
payload returns `true`: messages, attachments, transcript lines, and action calls with their
acks and results.

Given that permission, the orchestrator picks one of three send shapes:

| Shape | When | Behaviour |
|---|---|---|
| Broadcast only | `allowsDirect` is `false` | Broadcast, or throw when the backbone is down. |
| Directed | the envelope names a target peer | That peer's direct channel when ready, otherwise broadcast. |
| Fanned out | untargeted and direct-capable | Every ready direct channel, with broadcast covering the peers that have none. |

Fan-out reaches a dual-connected peer over both routes, so it is gated on
``KeepTalkingEnvelopeKind/isFanOutEligible`` — true only for messages, attachments, and
transcript lines, all three of which are idempotent at persistence. An untargeted kind that
is direct-capable but not fan-out eligible degrades to broadcast rather than trapping.

Fallback is per-leg. A directed send that throws despite a ready direct channel is logged and
retried on the broadcast channel, rethrowing only when the backbone is not ready either. One
failed fan-out leg never stops the others, and if the backbone is also down the send succeeds
only when at least one direct leg landed. The single exception is an oversized envelope: it is
rethrown as itself rather than retried, because every route fails the same size check and the
outbox needs the real cause so it drops the entry instead of queueing it behind an outage that
is not happening.

### Envelope framing and serialisation

``KeepTalkingEnvelope`` is the protocol every wire payload conforms to. A conformer declares
its static ``KeepTalkingEnvelopeKind`` and, optionally, a target peer and a transport context
ID; everything the transport needs is derived from the kind — the direct-path permission, the
fan-out eligibility, and the ``KeepTalkingEnvelopeChannel`` (chat, blob, actionCall, or
signaling) the payload belongs on.

Serialisation is centralised in ``KeepTalkingEnvelopePacket``, a two-key container of `kind`
and `payload` whose coding is a single exhaustive switch in both directions. Because the
switch is exhaustive over the kind enum, adding a new envelope type is a compile error until
it is wired into the wire format — the format cannot silently drift from the model.

There is no transport-level sequence number and no dedup table. Duplicate delivery is
absorbed at persistence instead, keyed on row id — which is exactly why fan-out is restricted
to kinds that are idempotent there. The transport carries the envelope and nothing else. The
outward publish is suppressed alongside the row: an async handler registered through
``KeepTalkingEnvelopeAsyncHandlers`` can report whether the envelope actually changed
anything locally, so a second copy does not become a second user-facing notification.

Receive is a short pipeline: dispatch on the envelope's ``KeepTalkingEnvelopeChannel``.
Anything on the `signaling` channel is consumed inside the transport — trust handshake
envelopes go to the trust handler, voice-call envelopes are forwarded straight on, and signal
and presence payloads are routed into the direct channels and the liveness state, with
presence then also handed to the application. Everything else is delivered to the application,
where typed dispatch tables (``KeepTalkingEnvelopeHandlers`` and
``KeepTalkingEnvelopeAsyncHandlers``) fan them out by kind.

Large payloads are not fragmented — the transport refuses them. A single encoded envelope is
capped at 1 MB, checked on the sealed bytes that actually go on the wire rather than on the
plaintext, and anything over that ceiling fails with `envelopeTooLarge` instead of being
split. Producing an envelope that fits is the publisher's job, which is what the sync layer's
paging is for. The blob channel is exempt — blobs have their own chunking model.

### Peer liveness and presence

Every ~13 seconds the transport broadcasts a ``KeepTalkingP2PPresencePayload`` as a raw
envelope. Liveness is deliberately **edge-triggered** rather than wave-based: a peer counts
as online while its presence was seen inside a timeout window comfortably wider than three
heartbeats (40 seconds), and the interesting event is the offline→online transition. The
earlier wave model cleared its confirmed set every interval and so *re-discovered* every
still-present peer each beat, re-firing connect notifications, presence echoes, and full
node-status rebroadcasts on a stable peer every thirteen seconds.

Reactions therefore key off the edge. On a connect edge — and only then — the transport
echoes presence back (rate-limited), reports the peer as reachable, and drives a direct
upgrade attempt. A per-beat upgrade prod would re-gather ICE candidates every cycle and,
because the upgrade path also requests a retrial, would reset the direct channel's backoff
and failure budget each beat, defeating both.

Reachability has two independent sources: SFU presence over the backbone, and ICE
connection state reported by the direct channel. Whichever observes first while the peer is
offline wins the edge, so a connect fires once across sources. A peer is only torn down
when **both** sources report nothing for two consecutive waves — at which point its direct
channel is released. Nothing else is emitted: there is no participant-left callback, because
the SFU still reaches the peer and the liveness set is the authoritative read of who is
there.

The heartbeat also re-arms decisions that were only ever valid for one network. Both the
mesh cap tripping and a channel exhausting its failure budget into `abandoned` encode
"direct does not work from here", and neither notices a move — the cap clears only on a
transport start, and an abandoned channel revives only on a per-peer reachability edge a
still-online peer never produces. ``KeepTalkingNetworkEnvironment`` digests the up,
non-loopback interface addresses each beat, counting only the /64 prefix of an IPv6 address
so RFC 4941 privacy addressing does not churn the digest on a stationary node; when the
digest changes, the cap clears and every abandoned or backing-off channel is asked to retry.

The client surfaces this: ``KeepTalkingClient/onPeerConnect`` fires on the edge,
``KeepTalkingClient/isNodeOnline(_:)`` and ``KeepTalkingClient/onlineNodeIDs()`` read the
current set, and ``KeepTalkingClient/runtimeStats()`` reports counters, channel labels, and
the physical route currently in use. Health is a pure read of the backbone's self-reported
state via ``KeepTalkingClient/transportHealth()`` — never a probe — because the carriers
already push loss. A `recovering` backbone is retrying with backoff and should be left
alone; `down` warrants a re-establish. The one case a pure read cannot catch is a
stale-open channel (the keepalive task starved across a long suspend), which is what
``KeepTalkingClient/probeTransport(timeout:)`` is for: it emits one presence wave and
watches the inbound counter for any progress.

```swift
if client.transportHealth() == .healthy, await client.probeTransport() == false {
    // Backbone is wedged open — bounce it in place, preserving live sessions.
    try await client.reestablishTransport()
}
```

### Context sync

A connect edge is also the cue to reconcile history. On every peer-online edge, and again on
each ~30-second maintenance heartbeat for every online peer, the client runs a context sync
against that peer; on the connect edge it then drains its outbox, a fresh channel being the
headline cue that queued work can move. The maintenance pass is the one dispatcher for that
upkeep — sync, transcript backfill while a call is live, attachment recovery, and the stale
voice-call sweep — rather than logic scattered across `connect()` and the peer-connect path.

Message sync is a three-phase reconcile — **summary → tail → chunk** — carried by
``KeepTalkingContextSyncEnvelope``. The peer's ``KeepTalkingContextSyncMetadata`` is fetched
once: per-sender message counts plus per-chunk digests, each chunk recording its first and
last message ID over a fixed chunk size. Comparing it against the local summary yields the
work for two phases. The *tail* request asks each sender for messages past a cursor — the
cheap append-only delta — and the *chunk* request repairs a specific diverging chunk
mid-stream. Both requests build through failable initializers that return `nil` when there is
nothing to pull, so a phase with no work is skipped entirely, and the local summary is
re-read between phases so the chunk pass sees what the tail pass just persisted. Both phases
are answered by the same messages result.

Neither phase is a single round trip. A result carries the cursor for the next page, and each
page is persisted before the next is requested, so a responder that appends mid-reconcile
simply leaves work for the next pass instead of invalidating this one. Chunk repair then
loops until the local summary stops changing, bounded at eight rounds; a divergence that
refetching cannot repair is logged and left in place rather than failing the whole sync,
because failing it would stop the tail flowing too.

The same algorithm runs over a different table for voice transcript lines, per session,
while a call is live; ``KeepTalkingContextSyncSnapshot`` and
``KeepTalkingVoiceTranscriptSyncSnapshot`` are the two streams it operates on. Side notes
have no request of their own: the summary result carries the peer's whole set when the
digests disagree, and a local edit is pushed to the context as a fire-and-forget
``KeepTalkingContextSyncSideNotesPush``. Both merge by key and version. Attachments split into
two requests — records by message ID, for rows that never landed, and blob *bytes* by content
hash — and run as their own maintenance pass rather than nested inside the reconcile. Context
sync envelopes are deliberately *not* direct-capable: a reconcile has no direct-path delivery
ack, so a stale P2P channel could accept one and silently lose it, and it therefore always
rides the backbone.

A reconcile is single-flighted per peer, so the connect edge and the heartbeat cannot run two
against the same peer at once. Progress is reported as a stream of
``KeepTalkingContextSyncEvent`` values through ``KeepTalkingClient/onContextSync``: one
`started`, a `messagesApplied` carrying the ids each persisted page produced, and then
`completed` or `failed`. All four share a `syncID` so a listener can group them. Side notes
report separately, through `onSideNotesChanged`, because they also change on local writes and
inbound pushes rather than only during a reconcile.

### Blob transfer

Blob bytes never travel as envelopes. They move on their own channel as self-describing
frames: a 4-byte big-endian header length, a JSON header, then the payload. The header
declares whether the frame is a chunk or the completion marker, the transfer ID, sender and
optional recipient node, the blob ID (a SHA-256 hex digest), MIME type and extension, total
byte count, and chunk index/count. Chunks are 32 KB so the whole frame stays well inside the
frame budget, and the sender paces itself between chunks so the send buffer drains rather
than spiking.

Storage is content-addressed. ``KeepTalkingBlobStore`` writes `prefix/hash.ext` under a base
directory, streams incoming bytes into a separate `partial/` file, and promotes the partial
into place on completion; it can also prune orphaned files that no record claims — a *ready*
file is kept when its path is still referenced, a *partial* when its blob ID is. Deciding
that is not a single-database question: the directory is shared and deduplicated across
identities, so a file is reachable from any identity holding a record for it.
``KeepTalkingBlobReferenceIndex`` answers "which blobs is this database still referencing?"
against one `Database` handle at a time, so a caller can open each identity, collect, and
release rather than holding every store open at once. Availability changes are reported
through ``KeepTalkingClient/onBlobAvailabilityChange``.

Transfers are demand-driven and resumable. A peer missing attachment bytes sends an
attachment request naming the hashes it wants, optionally with a per-blob bitmask of the
chunks it still needs. The responder enqueues each blob, merging masks for the same blob by
bitwise OR — and treating a `nil` mask as "send everything" — then streams only the marked
chunks. On the receive side, a frame processor serialises writes per transfer and drops
frames belonging to a superseded transfer for the same blob, so a restarted transfer cannot
interleave with the one it replaced.

**One-time blobs** are a different contract, used for action-call inputs and outputs rather
than conversation attachments: point-to-point, never recorded, never broadcast, and discarded
after use. The sender mints a fresh AES-256-GCM key per transfer, seals it to the recipient,
and describes the whole transfer with a ``KeepTalkingOneTimeBlobRef`` carried inside the
action-call envelope — the bytes themselves stream separately as ephemeral frames keyed by
transfer ID. Each 24 KB plaintext chunk is sealed with additional authenticated data binding
the transfer ID and the chunk index, so a chunk replayed into another slot or moved between
transfers fails its tag even under the same key. The receiving assembler writes each
ciphertext chunk to a private temporary directory named by index and touches nothing else —
no blob store, no record, no attachment row. A transfer is complete only when the received
indices are exactly the contiguous range the completion frame declared (count parity alone
would let a missing chunk hide behind an out-of-range one), idle transfers are reaped after
two minutes, and discarded transfer IDs are tombstoned so late frames cannot resurrect them.
Plaintext appears only when the action layer unseals the key and materialises the file, which
is also what verifies the sender. Failures surface as ``KeepTalkingOneTimeBlobError``.

## Topics

### Routing

- ``KeepTalkingContextTransport``
- ``KeepTalkingTransportRoute``
- ``KeepTalkingEnvelopeKind/allowsDirect``
- ``KeepTalkingEnvelopeKind/isFanOutEligible``
- ``KeepTalkingConfig/maxDirectMeshSize``
- ``KeepTalkingNetworkEnvironment``

### Channel Lifecycle

- ``BroadcastChannelState``
- ``BroadcastChannelEvent``
- ``BroadcastChannelEffect``
- ``BroadcastChannelStateMachine``
- ``DirectChannelState``
- ``DirectChannelEvent``
- ``DirectChannelEffect``
- ``DirectChannelStateMachine``

### Concrete Channels

- ``KeepTalkingSFUJuiceSession``
- ``KeepTalkingSFURelayCarrier``
- ``KeepTalkingSFUSigningKey``
- ``KeepTalkingJuiceP2PSession``
- ``KeepTalkingBlobHTTP2Channel``

### Envelope Framing

- ``KeepTalkingEnvelope``
- ``KeepTalkingEnvelopeKind``
- ``KeepTalkingEnvelopeChannel``
- ``KeepTalkingEnvelopePacket``
- ``KeepTalkingEnvelopeHandlers``
- ``KeepTalkingEnvelopeAsyncHandlers``

### Presence, Signalling, and Diagnostics

- ``KeepTalkingP2PPresencePayload``
- ``KeepTalkingP2PSignalPayload``
- ``KeepTalkingP2PSignalData``
- ``KeepTalkingRuntimeStats``

### Context Sync

- ``KeepTalkingContextSyncEnvelope``
- ``KeepTalkingContextSyncMetadata``
- ``KeepTalkingContextSyncSnapshot``
- ``KeepTalkingVoiceTranscriptSyncSnapshot``
- ``KeepTalkingContextSyncTailCursor``
- ``KeepTalkingContextSyncChunkCursor``
- ``KeepTalkingContextSyncSummaryRequest``
- ``KeepTalkingContextSyncSummaryResult``
- ``KeepTalkingContextSyncTailRequest``
- ``KeepTalkingContextSyncChunkRequest``
- ``KeepTalkingContextSyncMessagesResult``
- ``KeepTalkingContextSyncPageKey``
- ``KeepTalkingContextSyncSideNotesPush``
- ``KeepTalkingContextSyncAttachmentRequest``
- ``KeepTalkingContextSyncAttachmentRecordsRequest``
- ``KeepTalkingContextSyncAttachmentRecordsResult``
- ``KeepTalkingContextSyncFailureResult``
- ``KeepTalkingContextSyncEvent``

### Blob Transfer

- ``KeepTalkingBlobStore``
- ``KeepTalkingBlobStoreError``
- ``KeepTalkingBlobReferenceIndex``
- ``KeepTalkingBlobReferenceIndexError``
- ``KeepTalkingOneTimeBlobRef``
- ``KeepTalkingOneTimeBlobError``
