# Transport

How KeepTalking moves envelopes, presence, sync traffic, blob bytes, and voice between nodes over one process-wide iroh transport: an SFU for larger rooms, a peer mesh for small ones, and Bluetooth when the network fails.

## Overview

A process has one transport, and the host app owns it. ``KeepTalkingClient`` never builds,
starts, stops, or restarts a transport: ``KeepTalkingClient/connect()`` *attaches* the
client's context to it as a room, and ``KeepTalkingClient/disconnect()`` *detaches* it.
Everything below the attachment is shared by every attached context and outlives any one
client — the endpoints and the SFU session, peer links and Bluetooth, the per-member
queues, and recovery from network changes and lost connections.

That split is the point of the design:

- A client rebuilt for a model or settings change never drops a connection. Detaching one
  room leaves the transport, and every other room on it, untouched.
- A hundred attached contexts cost one SFU session and one link per peer, not one of each
  per context.
- Recovery is the transport's job. There is nothing for a client to probe, bounce, or
  restart.

``KeepTalkingTransport`` is the handle a client is given. ``KeepTalkingTransport/iroh(_:)``
wraps the process's ``KeepTalkingIrohTransportHost``. ``KeepTalkingTransport/unavailable``
is for clients that never connect — façades that only read the store, previews, tests that
need no network — and for visionOS, which builds without the iroh library. Connecting a
client built on `.unavailable` throws.

```swift
// Once per process.
let host = KeepTalkingIrohTransportHost(
    configuration: .init(relayURL: "https://relay.example/")
)
let transport = KeepTalkingTransport.iroh(host)

// One client per context, all attached to the same host.
let client = KeepTalkingClient(
    config: KeepTalkingConfig(contextID: contextID, node: nodeID),
    transport: transport,
    localStore: store
)
try await client.connect()
```

The host binds nothing until the first context attaches; ``KeepTalkingIrohTransportHost/start()``
runs then, and is idempotent. ``KeepTalkingIrohTransportHost/shutdown()`` ends the host for
good. Call it when the process is done with networking, or when a configuration change
replaces the host — clients built on the old one cannot connect again and must be rebuilt
on the new transport.

### Rooms

A context is a *room* on the transport, and its group secret addresses it. From the secret
and the context ID the transport derives two values with HKDF, under separate salts:

- a 32-byte **topic**, the routing key. The SFU's rooms, peer-link frames, and datagrams
  carry it in place of the context ID.
- a **payload key**, which seals everything published to the room: every envelope and
  every blob-stream chunk.

No context or node ID travels in the clear, so the SFU and any non-member on a link see
only opaque bytes, and knowing a topic reveals nothing about the key. Because the secret
addresses the room, replacing the secret moves the room:
``KeepTalkingClient/setGroupChatSecret(_:for:)`` on a connected client detaches and
attaches again on the same client, so nothing that captured the client is lost.

There is one attachment per context per process. Attaching a context that is already
attached takes the room over, and the earlier attachment goes quiet.

### The seam

Clients see the transport through one transport-neutral seam. The process-wide transport
is a multiplexer of rooms; attaching returns an attachment that carries one room from
attach to detach, and offers exactly this:

- send an envelope to the room, or to the envelope's target peer alone;
- send a lossy datagram to every member reachable now;
- open a blob stream to one member, and ask for a link to a member a blob is about to
  come from;
- report the room's status and traffic counters.

Everything the room observes comes back as one stream of events: an envelope (with the
node whose link carried it, when the route names one), a datagram, an incoming blob
stream, a link to a member coming up, a member's traffic moving to another link, the room
becoming able to take sends, a status change, and log lines.

The attachment holds no client state. Liveness, the presence heartbeat, and resync belong
to the client (see *Liveness and presence*, below), and the client knows nothing about
iroh. That is what lets the package test the client against a fake multiplexer with no
network at all, and test the host's decisions — whose turn it is to dial, who is a member,
what a room's status is — as pure values with no iroh objects.

### The iroh host

``KeepTalkingIrohTransportHost`` is the transport. Its
``KeepTalkingIrohTransportHost/Configuration`` names a relay URL, optionally the SFU's
endpoint ID, and a ``KeepTalkingIrohTransportHost/BluetoothMode``. Without an SFU ID the
host looks one up at `<relay>/kt/sfu`, which also supplies the relay's QUIC
address-discovery port. The host's iroh key is minted per host, discovery is off, and
the configured relay is the only one used: an endpoint ID names a running process, and a
node's identity travels only inside sealed presence.

It reaches members three ways.

**The SFU.** One QUIC connection to the KeepTalking SFU (ALPN `keeptalking/sfu/2`), kept up
best effort. A session stream carries room management: each attached room subscribes to
its topic and announces a sealed presence blob, and the SFU answers with a snapshot of the
room, then joins, departures, and presence. Publishes ride a stream per lane (see *Lanes*).
The SFU fans a broadcast out to the room, so the sender uploads once; an envelope with a
target goes to that one member (`PUBLISH_TO`).

The host paces its publishes below the SFU's frame and byte rate limits, rather than
losing frames it believes it sent. A write that makes no progress for 20 seconds marks the
session dead, and the host reconnects with backoff from one to eight seconds. On every
reconnect it re-subscribes each attached topic and holds publishes until those
subscriptions are in, so the SFU never sees a publish for a room it has not joined.

**The peer mesh.** iroh connections between nodes (ALPN `keeptalking/peer/2`), one per
remote endpoint however many contexts the two share. A link starts on the relay and moves
to a direct path when hole punching works; the lower endpoint ID dials. Every link opens
with a hello: freshly sealed presence for every context the sender has attached, which is
how two devices learn which contexts they share without the SFU. A link whose hello opens
none of our contexts is dropped, and until a link has shown that it shares one, no frame
it sends may exceed 64 KiB.

**Bluetooth.** Optional, set by ``KeepTalkingIrohTransportHost/BluetoothMode``: `off`,
`always`, or `whenNetworkFails`, which holds the radio while the network is failing —
there is no network path, the SFU is unreachable, or a member that announced a Bluetooth ID
has no working network link. That gate opens after three seconds of failure and closes
after thirty seconds of working network, so a flapping network does not flap the radio.

A member's Bluetooth ID comes from its presence, so a context node this host never met over
the network — it started offline, or joined while this host was away — can only be found by
discovery, and discovery needs the radio. So `whenNetworkFails` also takes the radio for a
twenty-second window every two minutes, and at once when a context attaches or the network
changes. A window links only to devices whose hello it hasn't seen and members the network
doesn't reach; finding one of those opens the gate, which keeps the radio.

The Bluetooth endpoint is process-wide and lent to one host at a time, and on it the higher
ID dials, retrying every three seconds while the link is wanted. Nearby devices are found
even without the SFU: an advert carries only a prefix of a device's key, so the host reads
the full key from the device before it dials.

### Membership

Who is in a room is learned only from sealed presence, through the SFU or from a hello.
Three rules keep that honest:

- Peers dial the endpoint IDs found *inside* the seal, never the one the SFU reports. The
  SFU can relay or drop presence, but it cannot substitute its own key.
- The sealed ID must match the connection the presence arrived on, so a member cannot
  replay another's presence as its own. A Bluetooth ID a member announced over the network
  cannot be rebound by a hello over Bluetooth.
- The SFU's roster is discovery, not membership. A member the SFU stops listing stays
  while a link reaches it or Bluetooth may, and is forgotten after thirty minutes without
  either. A hello that no longer lists a context is the peer's own word that it left.

### Mesh or SFU

Each room travels one route at a time, chosen by ``KeepTalkingIrohDeliveryPolicy``. The
standard policy, `.automatic(sfuAtMembers: 4)`, carries a room with fewer than four other
members on the mesh and a larger one on the SFU, and falls back to whichever route exists
when the preferred one does not. A small room gets direct paths and no server hop; a large
one gets one upload per send instead of one per member. Receivers accept both routes, so
senders never have to agree on a mode, and a room moves between them as it grows, shrinks,
or the SFU comes and goes.

A room on the mesh keeps a link to every member. A room on the SFU opens peer links only
on demand, when a blob transfer needs one.

### Lanes

Every envelope kind declares how it travels through ``KeepTalkingEnvelopeKind/delivery``:
a ``KeepTalkingEnvelopeDelivery`` naming its lane and whether it is idempotent.

| Lane | Carries |
|---|---|
| `control` | Presence, the trust handshake, voice call state, acks, blob negotiation. Small and urgent. |
| `interactive` | What a person or an agent waits on: messages, attachment records, transcript lines, action calls and results, action catalogs, turn continuations. |
| `bulk` | Context sync and node state. |

Each lane is its own ordered QUIC stream on every route — to the SFU and on every peer
link. Control and interactive are long-lived streams; every bulk envelope gets a stream of
its own, and blob transfers ride streams of their own below all three. QUIC sends them in
that order of priority. The point is isolation: a context-sync page never holds up a chat
message, and neither holds up an ack or a voice heartbeat.

The cost is ordering across lanes and between bulk envelopes, which receivers absorb. Node
status is the case that needed care: two snapshots from one sender can arrive out of
order, so each carries ``KeepTalkingNodeStatus/issuedAtMs``, strictly increasing per sender
process, and a receiver keeps only the newest per sender and context.

``KeepTalkingEnvelopeDelivery/isIdempotent`` states whether a kind is safe to deliver more
than once — after a resync, or over a second route. Every kind is except the trust
request: a second one mints a fresh ephemeral key and strands the handshake, so it must be
sent exactly once.

### Sending

A send hands the frame to the room's route or throws; it never waits on a connection.

On the mesh, every known member has a byte-bounded queue per lane — 16 MiB per member —
drained by whichever of its links carries it: its network link while that has a path, its
Bluetooth link otherwise. A member with no link yet simply accumulates frames until one
comes up. A full queue drops its oldest frames, because a member that far behind is
unreachable or slow, and the resync when it returns covers the gap. On the SFU, a publish
goes into that lane's SFU queue.

A send throws when the client is not connected, when there is no route (no usable SFU and
no known member, or a full SFU queue), or when the envelope is too large. The outbox
treats the first two as transient and retries the row once the room reports it can take
sends again. Size is different. A frame carries at most 1 MiB and the transport never
fragments, so an oversized envelope fails the same way on every route and every retry;
the outbox drops that retry row, and the message row itself stays. Producing envelopes
that fit is the publisher's job, which is what context-sync paging and
``KeepTalkingMessageLimits`` are for.

There is no transport-level sequence number and no dedup table. Duplicate delivery is
absorbed at persistence, keyed on row ID. The outward publish is suppressed alongside the
row: an async handler registered through ``KeepTalkingEnvelopeAsyncHandlers`` can report
whether the envelope actually changed anything locally, so a redelivered copy does not
become a second user-facing notification.

### Envelope framing

``KeepTalkingEnvelope`` is the protocol every wire payload conforms to. A conformer
declares its static ``KeepTalkingEnvelopeKind`` and, optionally, a target peer and a
transport context ID; its lane and idempotence are derived from the kind rather than
restated per payload.

Serialisation is centralised in ``KeepTalkingEnvelopePacket``, a two-key container of `kind`
and `payload` whose coding is a single exhaustive switch in both directions. Because the
switch is exhaustive over the kind enum, adding a new envelope type is a compile error until
it is wired into the wire format, and so is forgetting to give it a lane — the format
cannot silently drift from the model.

The attachment seals the encoded packet with the room's payload key and publishes it. On
receive it opens the payload — anything the room's key did not seal is dropped — decodes
the packet, drops an envelope whose transport context ID names another context, and hands
the rest to the client. There, trust handshake kinds go to the handshake, which runs before
the sender is trusted, and everything else goes to the typed dispatch tables,
``KeepTalkingEnvelopeHandlers`` and ``KeepTalkingEnvelopeAsyncHandlers``, which fan
envelopes out by kind.

### Status and statistics

``KeepTalkingTransportStatus`` describes how a room is doing: a
``KeepTalkingTransportStatus/State`` and, for display only, the
``KeepTalkingTransportStatus/Path`` its traffic takes.

- A room on the SFU is `ready`, on path `sfu`.
- A room on the mesh is `ready` when a link reaches every member, `degraded` when links
  reach some of them (frames for the rest wait in their queues), and `offline` when they
  reach none. Its path is `direct` when any link has a direct IP path, otherwise
  `bluetooth` when any member is reached over Bluetooth, otherwise `relay`.
- A room with nothing reachable while the SFU is still on its first way up reads
  `connecting`, not `offline`.

``KeepTalkingTransportStatus/canSend`` is true for `ready` and `degraded`.
``KeepTalkingClient/transportStatus()`` is the live reading;
``KeepTalkingClientLifecycle/transport`` on the lifecycle signal is the last one the room
reported. ``KeepTalkingClient/runtimeStats()`` returns a ``KeepTalkingRuntimeStats``
sample — envelopes and datagrams sent and received, the room's known and reachable
members, and the bytes waiting in its queues — and
``KeepTalkingClientSignals/transportStats`` samples it once a second and publishes it when
it changed. See <doc:Events>.

### Recovery

Recovery happens inside the host. Clients see only its effects, through status and
events:

- The host watches the system's network path. iroh notices few changes by itself on Apple
  platforms, so on each change (Wi-Fi to cellular, a new Wi-Fi network, the network coming
  back) the host tells it: iroh rebinds its sockets, reconnects to the relay and finds new
  paths for every connection, which carry on across the switch. The SFU's retry wait and
  the links' redial backoff are cut short, and while the path is down the network counts
  as failing, so Bluetooth in `whenNetworkFails` mode starts without waiting for the SFU to
  time out. No path update announces a return from the background, so the app calls
  ``KeepTalkingIrohTransportHost/networkChanged()`` then.
- The SFU session reconnects with backoff, and is closed and reopened when a write stalls.
- A link that drops is redialled, with backoff from two seconds to a minute, for as long
  as it is still wanted.
- A connection whose every path closed would otherwise linger until QUIC times it out,
  swallowing writes. The host stops routing through it as soon as its paths go, so the
  member's queue drains through its other link.
- A peer that went away (airplane mode, out of range) leaves its link looking alive for up
  to thirty seconds, as long as iroh keeps a relay path. So every network link carries a
  ping each two seconds, and one that heard nothing for six seconds goes silent: it stops
  carrying, and counts as a failing network for the Bluetooth gate. Any frame brings it
  back.
- When a member's traffic moves to another live link — the network died under Bluetooth,
  or came back — whatever went into the old connection may be lost. The attachment reports
  the member as rerouted, and the client resyncs with it.

### Liveness and presence

Liveness is the client's, not the transport's. Every 13 seconds a connected client sends a
``KeepTalkingP2PPresencePayload`` to its room. That heartbeat is how members on the SFU,
which have no link to us, see us at all. Any other traffic counts as well: an envelope a
link carried from a peer, a link to it coming up, or a blob stream from it marks the peer
as seen.

Liveness is **edge-triggered**. A peer counts as online while it was seen within a window
comfortably wider than three heartbeats (40 seconds), and the interesting event is the
offline→online transition. On that edge, and only then, the client echoes its presence
(rate-limited), publishes `online` on ``KeepTalkingClientSignals/presence``, and runs the
node-online maintenance pass. A model that re-discovered every still-present peer each
beat would re-fire all of that on a stable peer every thirteen seconds. A sweep every ten
seconds publishes `offline` for peers that aged out of the window.

The node-online pass is the one dispatcher for that upkeep: broadcast local node state,
re-announce a live voice call, sync the context with the peer, backfill transcripts while
a call is live, drain the outbox, and recover attachments. A reroute runs the same pass
even though liveness never saw the peer leave. And because disconnecting resets liveness,
the next connect sees every peer come online again, which is what drives the resync after
a reconnect.

``KeepTalkingClient/isNodeOnline(_:)`` and ``KeepTalkingClient/onlineNodeIDs()`` read the
current set.

### Context sync

A connect edge is also the cue to reconcile history. On every peer-online edge, and again
on each 30-second maintenance heartbeat for every online peer, the client runs a context
sync against that peer. The maintenance pass is the one dispatcher for that upkeep — sync,
transcript backfill while a call is live, attachment recovery, and the stale voice-call
sweep — rather than logic scattered across `connect()` and the peer-connect path.

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
``KeepTalkingContextSyncSideNotesPush``. Both merge by key and version. Attachment recovery
runs as its own maintenance pass rather than nested inside the reconcile: missing attachment
*records* are requested by message ID through context sync, and missing *bytes* are pulled
through blob negotiation (below). Sync envelopes ride the bulk lane, each on a stream of its
own, so a long reconcile never delays the conversation it is repairing.

A reconcile is single-flighted per peer, so the connect edge and the heartbeat cannot run two
against the same peer at once. Progress is reported as a stream of
``KeepTalkingContextSyncEvent`` values through ``KeepTalkingClientSignals/contextSyncEvents``: one
`started`, a `messagesApplied` carrying the ids each persisted page produced, and then
`completed` or `failed`. All four share a `syncID` so a listener can group them. Side notes
report separately, through `sideNoteChanges`, because they also change on local writes and
inbound pushes rather than only during a reconcile.

### Blob transfer

Blob bytes never ride an envelope, and they are never pushed: every transfer is a *pull* by
the node that needs the bytes. Negotiation is a ``KeepTalkingBlobTransferEnvelope`` on the
control lane; the bytes follow on a blob stream of their own, point to point on a peer
link, never through the SFU. Pulling is what makes this simple. The node missing a blob
knows exactly what it lacks and how much of it it already has, so each blob comes from one
holder at a time, a broken transfer resumes where it stopped, and the SFU never carries
every byte to every member.

For context attachments, the ``KeepTalkingBlobTransferEnvelope/Step`` goes:

1. `wanted` — a node missing attachment bytes broadcasts their blob IDs to the room.
   Announcements of the same blob are spaced ten seconds apart.
2. `offer` — each member holding some of them tells the asker, with each blob's size.
3. `pull` — the asker picks one holder per blob and asks it to stream from an offset: the
   size of the partial copy it already has. Blobs are content-addressed, so any holder's
   bytes continue any other's.
4. The holder opens a blob stream to the puller, or answers `unavailable`. A pull that
   produced no stream lapses after thirty seconds, so the next offer can claim the blob.

Before it pulls, the asker tells the transport a stream is coming from that holder. A room
on the SFU has no peer links, so this asks for one for the next two minutes, and whichever
side's turn it is dials; the holder waits up to twenty seconds for a link before it gives
up.

A blob stream's first frame is a header — the item, the starting offset, the blob's total
size, MIME type, and extension — followed by 128 KiB chunks, each sealed with the room's
payload key. Finishing the stream completes the transfer; resetting it cancels. Blob
streams run at the lowest priority and QUIC flow control paces them, so a transfer never
needs sleeps and never holds up a lane. The receiver reads only streams it pulled, from
the holder it asked. It appends to the blob's partial file from the header's offset (or
starts over at zero), then checks the size and that the SHA-256 digest equals the blob ID
before promoting the file to ready; on a mismatch the partial is discarded and the blob is
marked missing.

Storage is content-addressed. ``KeepTalkingBlobStore`` writes `prefix/hash.ext` under a base
directory, streams incoming bytes into a separate `partial/` file, and promotes the partial
into place on completion; it can also prune orphaned files that no record claims — a *ready*
file is kept when its path is still referenced, a *partial* when its blob ID is. Deciding
that is not a single-database question: the directory is shared and deduplicated across
identities, so a file is reachable from any identity holding a record for it.
``KeepTalkingBlobReferenceIndex`` answers "which blobs is this database still referencing?"
against one `Database` handle at a time, so a caller can open each identity, collect, and
release rather than holding every store open at once. Availability changes, including
visible receive-progress steps, are reported through
``KeepTalkingClientSignals/blobAvailabilityChanges``.

**One-time blobs** are a different contract, used for action-call inputs and outputs rather
than conversation attachments: point-to-point, never recorded, never broadcast, and
discarded after use. The holder mints a fresh AES-256-GCM key per transfer, seals it to the
recipient, and snapshots the file into an outbox, so the bytes the recipient pulls are the
ones the reference described even if the producer deletes its source; an entry lives ten
minutes from its last pull. A ``KeepTalkingOneTimeBlobRef`` describing the transfer rides
inside the action-call request or result. One-time blobs skip `wanted` and `offer`: the node
whose request or result carried the reference is the holder, so the recipient pulls from it
as soon as the reference arrives, before anything asks for the file, and a tight agent run
never waits a round trip it did not have to. Only the recipient may pull.

Each 128 KiB plaintext chunk is sealed with additional authenticated data binding the
transfer ID and the chunk index, so a chunk replayed into another slot or moved between
transfers fails its tag even under the same key. The receiving assembler writes each
ciphertext chunk to a private temporary directory named by index and touches nothing else —
no blob store, no record, no attachment row. A transfer is complete only when the received
indices are exactly the contiguous range up to where the finished stream ended (count
parity alone would let a missing chunk hide behind an out-of-range one), idle transfers are reaped after two
minutes, and discarded transfer IDs are tombstoned so late frames cannot resurrect them.
Materialising waits for the pull with a timeout, retries a pull that broke mid-stream, and
stops when the holder answers `unavailable`. Plaintext appears only when the action layer
unseals the key and decrypts the chunks, which is also what verifies the sender. Failures
surface as ``KeepTalkingOneTimeBlobError``.

### Voice

Voice is datagrams only. ``KeepTalkingClient/makeVoiceSession()`` builds a
``KeepTalkingVoiceSession`` on the client's room; it takes no mode and needs no signalling of
its own.

- **Call presence** goes out as ordinary control-lane envelopes: `voiceCallStarted` on
  start, on a two-second heartbeat, and when a new participant is first seen, and
  `voiceCallEnded` on stop. Every participant converges on the lowest session ID it sees.
- **Audio** goes out as lossy datagrams. They are never queued: the SFU fans them out, or
  on the mesh they go to each member a network link reaches now — never over Bluetooth,
  which cannot carry a call. Each datagram is sealed with the call's key, derived from the
  context secret and the shared session ID, and the sender and the target ride *inside*
  the seal, so the transport, the SFU, and members outside the call see neither.

A participant joins on a `voiceCallStarted` or on its first audio; context presence alone
says a peer is in the chat, not in the call. ``KeepTalkingVoiceSession/PeerState`` reads
`joined` for a participant in the call and `receiving` while its audio is arriving.

## Topics

### The Process-Wide Transport

- ``KeepTalkingTransport``
- ``KeepTalkingIrohTransportHost``
- ``KeepTalkingIrohTransportHost/Configuration``
- ``KeepTalkingIrohTransportHost/BluetoothMode``
- ``KeepTalkingIrohDeliveryPolicy``

### Room Status and Diagnostics

- ``KeepTalkingTransportStatus``
- ``KeepTalkingRuntimeStats``
- ``KeepTalkingClient/transportStatus()``
- ``KeepTalkingClient/runtimeStats()``

### Envelopes and Lanes

- ``KeepTalkingEnvelope``
- ``KeepTalkingEnvelopeKind``
- ``KeepTalkingEnvelopeKind/delivery``
- ``KeepTalkingEnvelopeDelivery``
- ``KeepTalkingEnvelopePacket``
- ``KeepTalkingEnvelopeHandlers``
- ``KeepTalkingEnvelopeAsyncHandlers``
- ``KeepTalkingNodeStatus``

### Presence

- ``KeepTalkingP2PPresencePayload``
- ``KeepTalkingClient/isNodeOnline(_:)``
- ``KeepTalkingClient/onlineNodeIDs()``

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
- ``KeepTalkingContextSyncAttachmentRecordsRequest``
- ``KeepTalkingContextSyncAttachmentRecordsResult``
- ``KeepTalkingContextSyncFailureResult``
- ``KeepTalkingContextSyncEvent``

### Blob Transfer

- ``KeepTalkingBlobTransferEnvelope``
- ``KeepTalkingBlobStore``
- ``KeepTalkingBlobStoreError``
- ``KeepTalkingBlobReferenceIndex``
- ``KeepTalkingBlobReferenceIndexError``
- ``KeepTalkingOneTimeBlobRef``
- ``KeepTalkingOneTimeBlobError``

### Voice

- ``KeepTalkingClient/makeVoiceSession()``
- ``KeepTalkingVoiceSession``
