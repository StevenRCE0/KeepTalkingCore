# ``KeepTalkingSDK``

The core engine for KeepTalking — a distributed AI conversation platform with peer-to-peer transport, semantic threading, multi-provider AI, and MCP-based skill execution.

## Overview

KeepTalking is built around a *context*: a conversation container shared by one or
more *nodes*. A node is a participating device identity; a context is the unit of
membership, history, and encryption. Messages published into a context reach every
other node that holds the context's group secret.

``KeepTalkingClient`` is the entry point. One client instance drives one
context — hosts that present several conversations at once keep a pool of clients
keyed by context identifier, all attached to one process-wide transport. The client
owns persistence, AI orchestration, and skill execution behind one surface, and
reports everything that happens asynchronously through signals.

The SDK is deliberately layered so each concern can be replaced independently:

- **Transport** is process-wide and sits behind a transport-neutral seam. The host
  app builds one ``KeepTalkingIrohTransportHost`` and hands it to every client as
  ``KeepTalkingTransport``; a client attaches its context as a room and never
  starts, stops, or restarts the transport. How an envelope travels — its lane and
  whether it may be delivered twice — is a property of its kind.
- **AI providers** sit behind a single ``AIConnector`` seam. Call sites never touch
  vendor wire formats.
- **Persistence** is a protocol (``KeepTalkingLocalStore``), so a host may supply
  its own database rather than the bundled SQLite store.
- **Secrets** live behind ``KeepTalkingKeychainStore``, letting each platform bind
  to its own secure enclave, Secret Service, or credential manager.

A host application observes the client rather than polling it. See
<doc:Events> for the complete push surface.

### Platform Requirements

iOS 17.5+, macOS 14.5+, visionOS 1+, Swift 6.1+.

The transport needs a reachable iroh relay, which also names the KeepTalking SFU; see
<doc:Transport>. visionOS builds without a transport: clients there use the local
store and never connect.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>
- ``KeepTalkingClient``
- ``KeepTalkingConfig``

### Conversations

- <doc:Messaging>
- ``KeepTalkingContext``
- ``KeepTalkingContextMessage``
- ``KeepTalkingNode``
- ``KeepTalkingMessagePageDirection``

### Naming and Organisation

- ``KeepTalkingMapping``
- ``KeepTalkingMappingTarget``

### Observing the Client

- <doc:Events>
- ``KeepTalkingAgentRunSnapshot``

### AI and Agents

- <doc:AIAgents>
- ``AIConnector``
- ``OpenAIConnector``
- ``AnthropicConnector``

### Runtime Execution

- <doc:RuntimeIO>
- ``KTResourceManifest``
- ``SkillManager``
- ``MCPManager``

### Networking

- <doc:Transport>
- ``KeepTalkingTransport``
- ``KeepTalkingIrohTransportHost``
- ``KeepTalkingTransportStatus``

### Persistence and Secrets

- ``KeepTalkingLocalStore``
- ``KeepTalkingModelStore``
- ``KeepTalkingKeychainStore``

### The Reference App and Deployment

- <doc:KeepTalkingApp>
- <doc:Provisioning>
- ``KeepTalkingProvisionBundle``
