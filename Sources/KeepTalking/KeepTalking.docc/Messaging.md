# Messaging and Contexts

Create or join a conversation context, exchange messages inside it, page through its history, and give its participants human-readable names.

## Overview

A *context* is KeepTalking's unit of membership, history, and encryption. It is a
container identified by a UUID: messages, attachments, threads, and side notes all
hang off it, and every node that holds the context's group secret can read what is
published into it. A *node* — ``KeepTalkingNode`` — is one participating device
identity. The pairing of the two is deliberately simple: nodes are who, contexts are
where.

``KeepTalkingClient`` is always scoped to exactly one context, fixed at construction
through ``KeepTalkingConfig``. That is why "switching contexts" means building a new
configuration with ``KeepTalkingConfig/withContextID(_:)`` and constructing a second
client rather than reconfiguring the first — the transport's channel labels are
derived from the context ID. Hosts that present several conversations at once keep a
pool of clients keyed by context. See <doc:GettingStarted> for the full setup path.

``KeepTalkingContext`` itself carries very little state: an ID, a last-activity
`updatedAt`, and the list of mark messages this node has already consumed.
Everything interesting is in its children. Note that sync metadata is *not* stored
on the row — it is derived from the context's message rows on demand when a sync
stream is built, so there is nothing to keep up to date.

`updatedAt` is a plain field rather than an auto-updating timestamp, because it is
advanced *forward-only* by writes to those children — an incoming batch of old
messages must never drag a context's last-activity time backwards. Single-model
writes (sending a message, updating a continuation state, saving an attachment)
advance it through a model middleware whose update is conditioned on the child being
newer. The batched sync path uses a bulk insert, which bypasses middleware, so there
the context is touched directly by the same forward-only upsert — which likewise
only writes when the incoming value is newer than the stored one.

### Creating a context

``KeepTalkingClient/createContext(named:)`` creates the context identified by the
client's own configured context ID, optionally gives it an alias, and makes sure a
group chat secret exists for it. Use it when this node originates the conversation.

```swift
let context = try await client.createContext(named: "Design review")
```

The static form, ``KeepTalkingClient/createContext(contextID:named:on:)``, does the
same row-and-alias work against any Fluent database without a client. It is the path
for hosts that own a store but have not brought a per-context client up yet — a
daemon backend materialising a context on request, or a view model preparing a
conversation before anyone connects. It does not mint a secret, because secrets are
client-and-keychain concerns.

A name is optional in both forms. It is trimmed of surrounding whitespace, and an
empty result simply means no alias is recorded — the context is still perfectly
usable, it just displays by identifier.

### Joining a context

Joining is the mirror image of creating. You already know the context UUID, and what
you need is its group secret, which reaches you out of band or through the trust
invitation handshake. Build a configuration for that context, construct a client,
install the shared secret with ``KeepTalkingClient/setGroupChatSecret(_:for:)``, and
connect.

```swift
let config = existingConfig.withContextID(joinedContextID)
let client = KeepTalkingClient(config: config, localStore: store, keychain: keychain)
try await client.setGroupChatSecret(sharedSecret, for: joinedContextID)
try await client.connect()
```

``KeepTalkingClient/connect()`` ensures the configured context row exists, so there
is no separate "register the context" step on the joining side. Do *not* reach for
``KeepTalkingClient/createContext(named:)`` here: it would mint a brand-new secret
that no peer holds, and the resulting client would be unable to read or write the
conversation it thinks it joined.

### Group chat secrets and what they gate

Each context has one 256-bit symmetric key, stored in the keychain under
``KeepTalkingKeychainKey/groupSecret(contextID:)`` — never in the model database.
``KeepTalkingClient/ensureGroupChatSecret(for:)`` returns the stored secret or mints
one if none exists, and ``KeepTalkingClient/setGroupChatSecret(_:for:)`` replaces it
with a secret you obtained elsewhere. Both make sure the context row exists before
they write a secret; `setGroupChatSecret` rejects empty data rather than storing an
unusable key.

The secret is what makes a context private, and it gates more than chat text:

- **Transport payloads.** Every envelope that declares a transport context ID —
  context messages, attachment envelopes, context sync, action calls, trust
  handshake envelopes, voice call envelopes — is sealed with the
  context secret before it leaves the process, and opened with it on arrival. With
  no secret, outbound encoding fails with a missing-context-secret error and
  inbound frames for that context cannot be decoded at all.
- **Trust handshakes.** ``KeepTalkingClient/requestTrust(with:in:)`` refuses to
  start if the context has no secret, because the handshake itself rides the
  context's encrypted signaling path.
- **Voice sessions.** A voice session is created with the context secret as its
  frame secret, so realtime audio frames are protected by the same key as chat.
- **Push wake previews.** Wake notification payloads are decrypted with the
  context secret to render a preview; without it the preview cannot be recovered.

Because of this, sending is defensive: the send path calls
``KeepTalkingClient/ensureGroupChatSecret(for:)`` for the target context before it
attempts any transport push. Note the asymmetry that follows — minting a secret is
safe for a context you originate, and useless for a context someone else already
shares. For those, install theirs.

### Sending messages

``KeepTalkingClient/send(_:in:sender:type:agentTurnID:emitLocalEnvelope:)-(_,UUID,_,_,_,_)`` persists
a message and broadcasts it. Only the text and the target are required; the target
may be a ``KeepTalkingContext`` or a bare context UUID, and overloads accept local
files (`attachments:`) or blobs already present in the blob store
(`existingBlobs:`).

```swift
try await client.send("Shipping the branch now.", in: context)
```

One check runs before anything is written. Content larger than
``KeepTalkingMessageLimits/maximumContentBytes`` — 512 KiB, half the envelope
ceiling, to leave room for sealing and framing overhead — throws
`KeepTalkingClientError.messageTooLarge` and no row is created. Transport does not
fragment envelopes, so a message past that ceiling could be neither pushed nor
replicated; refusing it at creation is what stops it from becoming a permanently
retrying outbox row that also stalls the sync page containing it.

Past that guard the ordering is the important part, and it is local-first. The
client resolves the current node, upserts the context, defaults the sender to this
node when none is given, saves the message with a time-ordered UUIDv7 primary key,
persists any attachments, and — if `emitLocalEnvelope` is true — fires the local
envelope sink so the UI can render the message immediately instead of waiting for it
to come back off the wire. Saving the message is also what advances the context's
`updatedAt`, through the touch middleware rather than an explicit step.

Only then does transport enter the picture, and from that point failures no longer
throw. The message is already durable, so it is enqueued on the outbox, pushed, and
cleared from the outbox on success. A transport failure is logged and simply leaves
the row in place: the outbox records nothing about the attempt — no error, no retry
count — because it is purely a delivery hint that the next drain retries when
channels reopen. Even if it never drains, the message still reaches peers through
ordinary context sync. A caller that gets no error back has a persisted message, not
necessarily a delivered one.

Two smaller behaviours are worth knowing. Wake notifications are only considered for
plain `.message` rows, and the preview text is truncated to 160 characters. And on
the receiving side, a message from a node this device has never seen creates that
``KeepTalkingNode`` row plus a ``KeepTalkingNodeRelation`` in the `.pending` state —
receiving a message from a stranger records the stranger, it does not trust them.

There is no bulk "send the whole context" call. Replicating history in bulk is the
context sync path's job, not the send path's: a joining or reconnecting node pulls
the messages it is missing through sync rather than having a peer push a
whole-context envelope at it.

### Reading history

History is read through one primitive,
``KeepTalkingClient/loadMessagePage(in:cursor:direction:limit:lowerBound:upperBound:)``.
Its semantics are deliberately direction-agnostic: callers ask for messages relative
to a timestamp cursor with an explicit walk direction, and assemble the pages into
whatever orientation their UI wants.

```swift
public func loadMessagePage(
    in contextID: UUID,
    cursor: Date?,
    direction: KeepTalkingMessagePageDirection,
    limit: Int,
    lowerBound: Date? = nil,
    upperBound: Date? = nil
) async throws -> [KeepTalkingContextMessage]
```

The cursor is a `Date`, not a message ID, and it is exclusive: `.backward` returns
messages strictly older than it, `.forward` messages strictly newer. Passing `nil`
reads from the extreme of the chosen direction — the newest messages for
`.backward`, the oldest for `.forward`. `lowerBound` and `upperBound` are inclusive
clamps applied independently of the cursor, which is how you restrict a page to a
known time window such as a thread's range. `limit` caps the row count.

**The ordering contract:** results come back in the direction's natural order, not
in display order. A `.backward` page is sorted descending, so its first element is
the message just before the cursor and its last element is the oldest row in the
page. A `.forward` page is sorted ascending. The caller re-sorts for display and
takes the next cursor from the *last* element of the page it just received.

```swift
var cursor: Date?
let page = try await client.loadMessagePage(
    in: contextID,
    cursor: cursor,
    direction: .backward,
    limit: 50
)
let displayOrder = Array(page.reversed())   // oldest → newest
cursor = page.last?.timestamp               // feed straight back in
```

This single primitive serves both orientations in practice: a chat list docked at
the bottom starts at the tail with a `nil` cursor and walks `.backward`, while a
view that reads a conversation top-down starts at the head and walks `.forward`.

### Message types

Every row is a ``KeepTalkingContextMessage``, and its
``KeepTalkingContextMessage/MessageType`` says what kind of thing it is. The
distinction matters beyond rendering: the agent transcript builder replays only
`.message` rows, so everything else is chat-surface or bookkeeping rather than
working context.

- `.message` — ordinary conversation text. The only type included in agent context
  replay, and the only type that triggers a wake notification.
- `.thinking` — reasoning emitted by the model on a turn. Stored beside the
  assistant message so the UI can show it, excluded from agent-to-agent replay.
- `.intermediate` — an in-flight tool-invocation hint carrying a human-readable
  label, plus — for non-built-in tools — the target node, action ID, and action
  name. The arguments the agent passed ride along too, but *sealed pairwise* to the
  caller and the executor. The row itself replicates to every member of the
  context, so the hint stays legible to everyone while the arguments open only for
  those two ends; `openSealedCallParameters` returns `nil` for anyone else.
- `.markTurningPoint` and `.markChitterChatter` — annotations an agent stores to
  name the live thread, signal a topic shift, or flag a message as noise. They are
  ordinary messages, so they replicate through normal sync; each node applies them
  locally once and records them in the context's consumed-marks list, which is not
  itself propagated.
- `.agentTurnContinuation` — a suspended agent turn waiting on a remote user, with
  its tool call ID, the action and target node, a continuation kind, an
  asymmetrically encrypted payload, and an
  ``KeepTalkingContextMessage/AgentTurnContinuationState``. These rows sync by
  *replacement*: when a non-pending state arrives for a continuation that already
  exists locally, it is updated in place and re-emitted rather than dropped as a
  duplicate.
- `.transcript` — speech text, tagged with a
  ``KeepTalkingContextMessage/TranscriptSource`` distinguishing on-device
  recognition from a realtime voice API.
- `.haywire` — a visible marker that an agent run ended abnormally, carrying a
  ``KeepTalkingContextMessage/HaywireReason`` of `failed` or `cancelled`.
- `.voiceCallSeal` — one durable, syncable entry per voice call, pointing at the
  session whose full transcript is stored separately. Its message ID is derived
  from the session ID so concurrent sealers on different nodes converge on a
  single entry.

### Senders

``KeepTalkingContextMessage/Sender`` has two shapes. `.node(node:)` attributes a
message to a peer device by UUID and is the default when you send without an
explicit sender. `.autonomous(name:node:model:)` attributes it to an AI agent: the
name is the role label, the node identifies which device ran the agent, and the
model records which model produced it. ``KeepTalkingContextMessage/Sender/nodeID``
extracts the UUID from the node case and returns `nil` for autonomous senders,
which is exactly the check that keeps agent output from being mistaken for a peer.

The distinction runs deep enough that the sender relation logic ignores autonomous
senders entirely — an agent is not a stranger to record and trust; the node that
ran it already is.

### Agent turn IDs

``KeepTalkingContextMessage`` carries an optional `agentTurnID`. One UUID is minted
per agent run and stamped on every row that run produces: the user's prompt message,
the assistant's replies, its thinking rows, its intermediate hints, and any
continuation it suspends on.

That single identifier does three jobs. It lets the UI recognise a prompt as an AI
prompt and style it accordingly, with no in-band `@AI` text marker polluting the
message body. It groups a run's output for display. And it scopes cleanup and
resumption: when a run finishes or is cancelled, continuations still pending for
that turn ID are cancelled, and a continuation response coming back from a remote
node is matched to the suspended turn through it. Messages typed by a human outside
an agent run simply leave it `nil`.

### Naming things: aliases and tags

Contexts, nodes, threads, and actions are all identified by UUIDs, which are
excellent keys and terrible labels. ``KeepTalkingMapping`` is the single abstraction
that attaches human meaning to any of them. A mapping row names its subject through
``KeepTalkingMappingTarget`` — `.node`, `.context`, `.thread`, or `.action`, with
exactly one of the four foreign keys populated and the other three explicitly null —
and carries a ``KeepTalkingMappingKind`` of either `alias` or `tag`.

Both kinds store the trimmed value the user typed alongside a lowercased normalized
value used for lookup and deduplication, so `"Design Review"` and `"design review"`
are the same tag but only the first spelling is displayed. Removal is always a soft
delete: rows are stamped with a deletion date and filtered out of reads by default,
which is what allows re-adding a tag to revive its original identity and colour.

**Aliases** are the single display name for a target. There is at most one live
alias per target, and `setAlias` enforces that invariant: it upserts the primary row
and soft-deletes any extras it finds. Passing `nil` — or a string that trims to
empty — soft-deletes the alias entirely, returning the target to displaying by
identifier.

**Tags** are many-per-target labels, optionally grouped by a namespace. A tag is
unique per target within a `(namespace, normalized value)` pair, so adding the same
tag twice is idempotent and adding one that was previously removed revives it. Tag
colours are chosen for consistency rather than per-row novelty: a new tag inherits
the colour of the oldest existing tag row anywhere with the same namespace and
value, and only falls back to a generated pastel hex when the tag is genuinely new.
An empty or whitespace-only namespace normalizes to none, so there is exactly one
unnamespaced bucket rather than several indistinguishable ones.

```swift
try await client.setAlias("Design review", for: .context(contextID))
try await client.addTag("urgent", namespace: "priority", to: .context(contextID))

let urgent = try await client.tags(for: .context(contextID), namespace: "priority")
```

### Static-on-database and instance forms

Every mapping operation exists twice: as an instance method on ``KeepTalkingClient``
that uses the client's own local store, and as a static method taking an explicit
`on database:` parameter. The instance form is sugar — it forwards straight to the
static one.

The reason for the pair is that naming is not a connected-client concern. A host
frequently needs to read or write mappings when no client for the relevant context
exists: a daemon backend answering a "list contexts" request, a view model
rendering a picker across every context on the device, a process that owns the store
but has not connected transport. Those call the static forms and pass their
database. Code that already holds a live client for the context it is naming uses
the instance form and never thinks about the store.

```swift
// With a live client:
try await client.addTag("archived", to: .thread(threadID))

// From a host that only has a database:
try await KeepTalkingClient.addTag("archived", to: .thread(threadID), on: database)
```

Reads follow the same pattern. ``KeepTalkingClient/mappings(for:includeDeleted:)``
returns every live mapping for a target sorted by value,
``KeepTalkingClient/alias(for:)`` returns just the alias string, and
``KeepTalkingClient/tags(for:namespace:)`` returns the tags in one namespace.

### Rendering names efficiently

Resolving names one query at a time does not scale to a message list. ``KeepTalkingAliasLookup``
is the answer: build it once from a mapping snapshot with
``KeepTalkingClient/aliasLookup()`` (or the static
``KeepTalkingClient/aliasLookup(mappings:)`` over mappings you already loaded), then
resolve synchronously as you render.

```swift
let lookup = try await client.aliasLookup()
for message in page {
    let who = lookup.resolve(sender: message.sender)
    print(who.combined())   // "Ada (Bright Otter)", or just "Bright Otter"
}
```

``KeepTalkingAliasLookup/resolve(sender:fallback:)`` understands both sender shapes:
node senders resolve through their alias, and autonomous senders render as the role
name joined to the name of the node that ran the agent. The resulting
``KeepTalkingAliasResolution`` separates the display name from the identifier, so a
UI can show a primary label, an optional secondary identifier, or a combined string,
and can tell from ``KeepTalkingAliasResolution/isFallback`` whether it is showing a
real alias or a stand-in.

## Topics

### Contexts

- ``KeepTalkingContext``
- ``KeepTalkingOperatorContext``
- ``KeepTalkingClient/createContext(named:)``
- ``KeepTalkingClient/createContext(contextID:named:on:)``

### Group chat secrets

- ``KeepTalkingClient/ensureGroupChatSecret(for:)``
- ``KeepTalkingClient/setGroupChatSecret(_:for:)``
- ``KeepTalkingKeychainKey/groupSecret(contextID:)``

### Sending messages

- ``KeepTalkingClient/send(_:in:sender:type:agentTurnID:emitLocalEnvelope:)-(_,UUID,_,_,_,_)``
- ``KeepTalkingLocalAttachmentInput``
- ``KeepTalkingExistingBlobReference``
- ``KeepTalkingMessageLimits``

### Reading history

- ``KeepTalkingClient/loadMessagePage(in:cursor:direction:limit:lowerBound:upperBound:)``
- ``KeepTalkingMessagePageDirection``

### Message shape

- ``KeepTalkingContextMessage``
- ``KeepTalkingContextMessage/MessageType``
- ``KeepTalkingContextMessage/Sender``
- ``KeepTalkingContextMessage/TranscriptSource``
- ``KeepTalkingContextMessage/HaywireReason``
- ``KeepTalkingContextMessage/AgentTurnContinuationState``

### Participants

- ``KeepTalkingNode``
- ``KeepTalkingNodeRelation``
- ``KeepTalkingRelationship``

### Aliases and tags

- ``KeepTalkingMapping``
- ``KeepTalkingMappingTarget``
- ``KeepTalkingMappingKind``
- ``KeepTalkingMappingError``
- ``KeepTalkingClient/setAlias(_:for:)``
- ``KeepTalkingClient/setAlias(_:for:on:)``
- ``KeepTalkingClient/alias(for:)``
- ``KeepTalkingClient/alias(for:on:)``
- ``KeepTalkingClient/addTag(_:namespace:to:)``
- ``KeepTalkingClient/addTag(_:namespace:to:on:)``
- ``KeepTalkingClient/removeTag(_:namespace:from:)``
- ``KeepTalkingClient/removeTag(_:namespace:from:on:)``
- ``KeepTalkingClient/tags(for:namespace:)``
- ``KeepTalkingClient/tags(for:namespace:on:)``
- ``KeepTalkingClient/mappings(for:includeDeleted:)``
- ``KeepTalkingClient/mappings(for:includeDeleted:on:)``

### Displaying names

- ``KeepTalkingAliasLookup``
- ``KeepTalkingClient/aliasLookup()``
- ``KeepTalkingClient/aliasLookup(mappings:)``
- ``KeepTalkingAliasLookup/resolve(sender:fallback:)``
- ``KeepTalkingAliasResolution``
- ``KeepTalkingAliasResolution/IDDisplayMode``
