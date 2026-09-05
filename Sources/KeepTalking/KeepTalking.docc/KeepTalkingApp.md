# KeepTalkingApp

The first-party iOS and macOS host built on this package — the reference
implementation of what a real conformance to the SDK's seams looks like.

## Overview

This package is deliberately incomplete on its own. ``KeepTalkingClient``
requires a ``KeepTalkingLocalStore`` and a ``KeepTalkingKeychainStore``, an
``AIConnector`` sits behind every AI feature, ``KeepTalkingSemanticStore`` has
no bundled implementation at all, and a node's identity, its provider
credentials, and its preferences all have to live *somewhere* the SDK never
opens a database or a file for. Those are seams by design — see
<doc:Architecture> — but a seam only proves itself once something real is
plugged into it.

KeepTalkingApp, in the sibling `KeepTalkingApp` repository next to this
package, is that something. It is not a demo target inside this package; it
is the shipping, unified iOS/macOS application built against the published
`KeepTalkingSDK` library product, and it is the place to look when a doc page
here describes a protocol or a "the host decides" default and the natural
next question is "decides it how, concretely." Because it lives outside this
package, its own types are not linkable from this catalog — the sections
below name them in prose rather than with symbol links.

### What the app supplies

- **Node identity.** A `SelfNode` model (SwiftData) persists the UUID that
  becomes ``KeepTalkingConfig/node``, along with each identity's SFU and
  PassKV endpoints. An identity registry lets one device hold several such
  identities side by side — a personal account and a provisioned work
  account, say — and switch the active one without losing the others' state.
- **Secrets.** The app injects the SDK's own `KeepTalkingSecItemKeychainStore`
  rather than the in-memory default, and shares it across the main app and
  its extensions through a common `keychain-access-groups` entitlement — the
  concrete answer to ``KeepTalkingKeychainStore``'s "letting each platform
  bind to its own secure enclave" promise in <doc:GettingStarted>.
- **AI credentials.** Provider configuration lives in its own SwiftData model,
  one row per configured provider with one marked active, editable in a
  dedicated settings tab. That active row is what drives the API key, model,
  and backend a client is constructed with.
- **Semantic storage.** ``KeepTalkingSemanticStore`` has no bundled backend,
  by design — see <doc:RuntimeIO> and <doc:Architecture>. The app's own
  `VecturaSemanticStore` wraps VecturaKit to fill that seam, kept at the app
  layer specifically because VecturaKit's platform floor is higher than the
  SDK's own.

### Companion targets

A Notification Service Extension decrypts and badges incoming push payloads,
and a Share Extension lets other apps hand content into a context, alongside
several other extension targets. Both share the main app's App Group and
keychain-access-group wiring rather than reimplementing secret storage —
another consequence of the app, not the SDK, owning where secrets live.

### Provisioning: a worked example end to end

The clearest single example of "the SDK owns the contract, the app owns the
concern" is deployment configuration. ``KeepTalkingProvisionBundle`` and its
coding are entirely SDK-owned, portable, and platform-neutral; the URL scheme
that delivers one, the confirmation screen that previews it field by field,
which identity it installs into, and the record of which fields it locked
are all choices the app makes on top. See <doc:Provisioning> for the full
guide, including how that loop is wired together in this app specifically.

## Topics

### Related guides

- <doc:Provisioning>
- <doc:GettingStarted>
- <doc:Architecture>
- <doc:RuntimeIO>

### Seams the app fills in

- ``KeepTalkingConfig``
- ``KeepTalkingKeychainStore``
- ``KeepTalkingSemanticStore``
- ``AIConnector``
