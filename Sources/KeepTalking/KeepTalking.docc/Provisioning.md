# Provisioning

Package topology, AI provider credentials, and preferences into a portable
bundle so a node can be configured in one step instead of by hand.

## Overview

A fresh node needs an SFU endpoint, often a PassKV server, usually at least one
AI provider's API key, and a handful of preferences before it is worth using.
Typing all of that in by hand on every device — or walking a non-technical
user through it — does not scale past "one person, one laptop." Provisioning
is the SDK's answer: ``KeepTalkingProvisionBundle`` is a portable, `Codable`
description of those settings that an operator builds once and a node applies
in a single step.

Provisioning is explicitly narrower than identity. Minting a node's keypair
and establishing PassKV trust relations happen separately, through the normal
node-identity and trust-invitation paths — a bundle configures a node that
already exists (or that the host creates alongside applying it); it never
mints or authorizes one. Keep that boundary in mind when reading the bundle's
fields: everything in it is settings, never key material.

### The bundle shape

``KeepTalkingProvisionBundle`` groups its fields by concern — topology
(``KeepTalkingProvisionBundle/passKVServerURL``,
``KeepTalkingProvisionBundle/sfuHost``, ``KeepTalkingProvisionBundle/sfuPort``),
AI (``KeepTalkingProvisionBundle/providers``,
``KeepTalkingProvisionBundle/roleAssignments``,
``KeepTalkingProvisionBundle/webSearch``), and preferences (wake keyword,
response languages, connection limits, attachment sync lookback, analytics
opt-in). Every field is optional at the *bundle* level, and that `nil` carries
meaning: it means "this profile does not configure this field," not "clear
it." A bundle is a diff to apply on top of whatever the node already has, not
a full snapshot that overwrites it — which is what lets one profile narrowly
distribute just an AI provider without also silently resetting a node's
network settings.

Each present field is wrapped in ``ProvisionedValue``, pairing the value with
a set of ``ProvisionPolicy`` flags:

- `.userConfigurable` — the user may edit or override this value after
  provisioning. Absent, the field is read-only in the UI.
- `.availableInOtherProfiles` — this value survives a SelfNode identity
  switch. Absent, it is scoped to whichever identity was active when it was
  installed.

An absent flag always means the stricter default, so a profile author who
sets nothing gets a locked, identity-scoped field rather than an accidentally
wide-open or leaky one.

``ProvisionedProvider`` describes one AI provider to install — kind,
display name, API key, base URL, and its own policy set. `displayName` is the
merge key: applying a profile twice updates the matching provider in place
rather than duplicating it. ``ProvisionedRoleAssignments`` maps each
``ProvisionAgentRole`` (`main`, `act`, `audioInteraction`) to a
``ProvisionedRoleTarget`` — a provider by `displayName` plus an optional model
override — and is deliberately resolved by name *after* providers are
installed, so a bundle never has to know a provider's UUID ahead of time.
``ProvisionedWebSearch`` configures the standalone web-search backend,
independent of any provider.

``ProvisionSecurity`` states how the payload itself is protected: `.none`
means plain JSON, and the bundle should be treated as a secret — it can
contain live API keys. `.sfuBound` is reserved for a future payload encrypted
behind SFU/PassKV authentication and is not implemented yet.

### Encoding and transport

``KeepTalkingProvisionEncoder`` and ``KeepTalkingProvisionDecoder`` mirror
`JSONEncoder`/`JSONDecoder`. Beyond plain JSON, they support a second,
*packed* wire form: the JSON bytes run through a deterministic keystream XOR
and prefixed with a two-byte marker distinct from JSON's leading `{`. This is
obfuscation, not encryption — reversible by anyone with the SDK's source — and
exists only to stop a provisioning file from being legible at a glance or
grep-able for a stray API key, not to protect it from a determined reader.

Decoding defaults to sniffing the form from the leading byte, so a caller that
does not know in advance whether a payload is packed can just decode it.
`decode(_:from:obscured:)` pins the expected form instead, throwing
``KeepTalkingProvisionPackingError/malformedPayload`` on a mismatch — useful
when the source's form is known and silently accepting the wrong one would be
worse than failing loudly.

``KeepTalkingProvisionBundle/provisionURL()`` builds the bundle's canonical
transport shape: a `ktprovision://import?payload=<base64url>` URL, where the
payload is whichever form the encoder produced — plain or packed — with
base64url as an outer layer applied after coding. The same encoded bytes can
just as well be written to a `.ktprovision` file; the URL and the file are two
containers for the same payload.

### What the SDK does and does not do

The SDK owns the bundle's shape and its coding — nothing more. There is no
`KeepTalkingClient` method that takes a bundle and applies it, because
applying one means writing into whatever a host uses for its own settings
storage (SwiftData, a config file, `UserDefaults`), and that store is a host
concern the same way ``KeepTalkingLocalStore`` and ``KeepTalkingKeychainStore``
are. A host that wants to support provisioning maps each present field onto
its own settings model and its own inputs to ``KeepTalkingConfig`` — honoring
absence as "leave it alone" and a locked policy as "show it, but do not let it
be edited."

### A generated JSON Schema

A `.ktprovision` file is plain JSON, so a schema is enough to get editor
validation and autocomplete while hand-writing one — hosted at
[keeptalking-provision.schema.json](https://docs.keeptalking.dev/schema/keeptalking-provision.schema.json).
It is not hand-maintained: `GenerateProvisionSchema`, an internal executable
target in this package, builds one fully-populated ``KeepTalkingProvisionBundle``
and walks it with `Mirror` to recover each field's shape and — because a
property's static optionality survives being boxed into `Any` — whether it is
required, which mirrors exactly what the synthesized decoder itself requires.
Nothing about it is checked into this repo: the docs-deploy workflow runs the
generator fresh on every deploy and writes the result straight into the site
being published, so the hosted copy can never drift from the bundle — there
is no separate "generate, then remember to commit" step to fall out of sync
with. Referencing it from an instance document —
`"$schema": "https://docs.keeptalking.dev/schema/keeptalking-provision.schema.json"`
— is harmless even though the bundle never declares that field, since the
decoder ignores unknown keys at every level.

## How KeepTalkingApp implements the full loop

KeepTalkingApp — see <doc:KeepTalkingApp> — is where this contract becomes a
complete, working feature, and it is worth reading end to end as a worked
example of "host owns the concern, SDK owns the contract."

The app registers `ktprovision` as a URL scheme and exports a `.ktprovision`
uniform type (conforming to `public.json`) in its `Info.plist`, so a profile
delivered as a link, an AirDropped file, or a Finder double-click all resolve
to the same entry point. A single router dispatches every incoming `kt*://`
URL and opened file — across both the iOS scene's `onOpenURL` and the macOS
app delegate — and gives provisioning links first priority ahead of OAuth
callbacks and the app's other share-import routes.

From there, a dedicated handler parses either shape — a
`ktprovision://import?payload=` URL or an opened `.ktprovision` file — decodes
it with the lenient, form-sniffing decoder, and publishes the result for the
UI to present. A URL or file that matched the scheme or extension but failed
to decode is still treated as consumed, so it never falls through to another
handler; it is simply dropped rather than surfaced as garbage to an unrelated
importer.

The confirmation screen the user actually sees is a per-field diff: every
provisioned value is listed next to a lock glyph when its policy is not
`.userConfigurable`, so what will and will not be editable afterward is
visible before anything is applied. Because a profile is normally "the
configuration for one account" rather than a blanket device default, the same
screen asks which identity it should install into — an existing one, or a
freshly created one — before committing.

Applying a bundle writes its topology and preference fields onto the target
identity, installs (or updates in place) a record of which fields that
profile locked — which is what lets those controls stay visibly greyed out
elsewhere in settings — and links or updates the provider and web-search rows
it describes, matched by `displayName` so re-applying the same profile
updates rather than duplicates. Removing an installed profile cascades to the
providers it installed while leaving anything the user created by hand
untouched, because the app models "this provider belongs to this profile" as
an actual relationship rather than a naming convention.

The reverse direction is symmetric: exporting the active identity's current
settings back into a bundle, sharing it as a link, saving it to a file, or
re-packing an existing plain-JSON profile into the obscured form — all live
next to the import path, so any node can act as a distribution source and not
only a receiver.

## Topics

### The bundle

- ``KeepTalkingProvisionBundle``
- ``ProvisionedValue``
- ``ProvisionPolicy``
- ``ProvisionSecurity``

### AI configuration

- ``ProvisionedProvider``
- ``ProvisionAgentRole``
- ``ProvisionedRoleTarget``
- ``ProvisionedRoleAssignments``
- ``ProvisionedWebSearch``

### Coding

- ``KeepTalkingProvisionEncoder``
- ``KeepTalkingProvisionDecoder``
- ``KeepTalkingProvisionPackingError``
