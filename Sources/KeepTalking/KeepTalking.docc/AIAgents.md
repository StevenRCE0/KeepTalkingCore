# AI Connectors and Agents

How KeepTalking talks to language models, and how the main, ACT, and audio agent roles divide the work of a single turn.

## Overview

Every model call in the SDK goes through one protocol. ``AIConnector`` is the single seam wrapping any LLM backend: it takes KT-native values — ``AIMessage``, ``KeepTalkingActionToolDefinition``, ``AIToolCall``, ``AIToolChoice`` — and translates them into a vendor's wire format inside the connector. Call sites never construct vendor types, which is what makes the seam worth having: adding a provider means adding one connector and changing nothing upstream of it.

The protocol is deliberately small. A connector reports its feature set and knows how to complete one turn:

```swift
public protocol AIConnector: Actor, Sendable {
    nonisolated var capabilities: AIConnectorCapabilities { get }
    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
    ) async throws -> AITurnResult
}
```

Conformance is `Actor`-constrained because a connector owns a live network service and its credentials. A minimal implementation is short:

```swift
actor EchoConnector: AIConnector {
    nonisolated let capabilities = AIConnectorCapabilities(
        supportsNativeToolCalling: false
    )

    func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
    ) async throws -> AITurnResult {
        AITurnResult(
            assistantText: messages.last?.content?.text,
            toolCalls: []
        )
    }
}
```

Pass an instance as the client's `aiConnector` and it drives every agent loop in the SDK. A second connector may be supplied as `actConnector` so the action-calling sub-agent targets a different provider or endpoint than the main agent; when it is omitted, the ACT role falls back to the main connector.

### Capabilities and per-turn configuration

``AIConnectorCapabilities`` is how the rest of the SDK asks what a backend can do without knowing who it is. `supportsNativeToolCalling` says whether the model accepts a tool list on the wire — when it is `false`, an agent loop may fall back to explicit prompting instead. `supportsThinking` says whether the connector can populate ``AITurnResult/thinking``; callers should not expect reasoning text from a connector that reports `false`, even when a reasoning model is requested.

Everything else that varies per turn travels in one value, ``AITurnConfiguration``. This is KT-owned rather than a re-export of a vendor request body, because no unified request shape exists across providers: sealing the configuration here keeps ``AIConnector`` stable while each connector destructures the fields it understands and ignores the rest.

```swift
let configuration = AITurnConfiguration(
    reasoning: AIReasoning(effort: .high),
    temperature: 0.2,
    maxOutputTokens: 4_096
)
```

``AIReasoning`` carries an abstract effort level, an optional reasoning-token cap, and an `exclude` flag; each connector maps it onto whatever its provider actually exposes. ``AIResponseFormat`` covers plain text, JSON object mode, and JSON schema for providers that have such a switch. The audio fields — `modalities`, ``AIAudioOutputConfig``, and ``AIStreamingAudioHandler`` — request spoken output and, when a handler is attached, deliver decoded chunks as they arrive rather than only at the end of the turn.

``AIStage`` tells the connector which half of the loop it is in: `.planning` when the model should be choosing tools, `.execution` when it should be answering the user. Connectors are free to use it or ignore it; the SDK also uses it to decide how a tool call is described in the conversation.

### The KT-native message IR

``AIMessage`` is the intermediate representation the whole SDK builds histories in. It has four roles. `system` carries instructions and persona — connectors targeting providers without a system role hoist those into a top-level field instead. `user` is end-user input. `assistant` is model output, and its `content` is allowed to be `nil` for turns that consist entirely of tool calls. `tool` is the result of executing a call the assistant requested, and must carry the `toolCallID` that matches it.

Content is either plain text or a list of parts. Parts are what make the IR multimodal: `.text`, `.imageURL`, and `.inputAudio`. Image parts accept `data:` URLs, which is how attachments are inlined for vision models, and audio parts carry raw bytes plus a wire-format label that the connector base64-encodes on the way out.

```swift
let message = AIMessage.user(parts: [
    .text("What changed in this screenshot?"),
    .imageURL(URL(string: "data:image/png;base64,\(png.base64EncodedString())")!)
])
```

``AIMessage/Content`` also exposes a `text` projection for providers that only accept a string body. It concatenates the text legs and drops everything else, so callers that genuinely need vision must handle `.parts` explicitly rather than leaning on the projection.

``AIToolCall`` keeps the provider-issued call ID, the function name, and the arguments as the raw JSON blob the model emitted — the SDK does not pre-parse them, so dispatchers decode on demand and nothing is lost in a round trip. ``AIToolChoice`` abstracts the four choices every provider expresses somehow: `auto`, `none`, `required`, and `specific(name:)`.

Coming back the other way, ``AITurnResult`` carries the assistant text, the tool calls, optional reasoning content, and optional ``AIAudioOutput``. Reasoning is surfaced rather than swallowed because the orchestrator — not the connector — decides whether to publish it into the conversation.

### The built-in connectors

Two connectors ship with the SDK, each with a backend enum that selects an endpoint shape rather than a different code path.

| Connector | Backends |
|---|---|
| ``OpenAIConnector`` | `.openRouter`, `.openAI`, `.custom(baseURL:)` |
| ``AnthropicConnector`` | `.anthropic`, `.custom(baseURL:)` |

``OpenAIConnector`` speaks the OpenAI Chat Completions shape. All three ``OpenAIConnectorBackend`` cases hit the same `/v1/chat/completions` endpoint and differ only in base URL and defaults — OpenRouter and OpenAI supply theirs, and `.custom(baseURL:)` takes a host root to which the connector appends the path. It reports both native tool calling and thinking support, translates user content into OpenAI's vision parts, and switches to a streaming request whenever audio output is configured, because audio only arrives over the stream.

``AnthropicConnector`` translates straight into the Anthropic Messages shape with no OpenAI intermediate hop. System messages are concatenated and hoisted into the top-level `system` field; tool results become user-role messages carrying a `tool_result` block, which is how Anthropic models them; `data:` image URLs are decoded into base64 image sources and `https://` URLs into URL sources. Reasoning effort maps onto an extended-thinking token budget, and the connector opts in only when a caller explicitly asked for reasoning. A few things are deliberately not modelled and are dropped to keep the body lean: per-message `name`, `responseFormat` (structured output is handled at the prompt level instead), and audio input, which is replaced by a text placeholder rather than silently disappearing.

Both connectors accept an explicit API key or fall back to environment variables, resolve their endpoint from an argument, then the environment, then the backend default, and both expose a `listModels()` call for populating a model picker. Both also run the HTTP call in a child task so that cancelling the surrounding agent run actually tears down the request instead of leaving it streaming until timeout.

```swift
let connector = try AnthropicConnector(backend: .anthropic)
let client = KeepTalkingClient(
    config: config,
    aiConnector: connector,
    localStore: store
)
```

### What the main agent is given

The primary loop is not handed the full action surface. It receives meta tools and primitives only — static schemas with no server I/O behind them — and reaches real actions through a single delegation tool. That set covers `kt_run_action` (the ACT hand-off), skill metadata lookup, the context-attachment listing, reader, and metadata updater, thread memory search, JavaScript evaluation, web search, turning-point and chitter-chatter marking, side-note editing, and file staging.

Web search is pluggable in two shapes. ``KeepTalkingWebSearchTool`` builds a search provider closure from a ``WebSearchToolConfiguration`` by issuing a one-shot chat completion with the provider's own server-side search tool attached: ``OpenRouterWebSearchTool`` attaches OpenRouter's `openrouter:web_search` tool block and refuses any endpoint that is not on `openrouter.ai`, while ``OpenAIWebSearchTool`` attaches the plain `web_search` block on OpenAI-compatible endpoints that accept it. ``StandaloneWebSearchBackend`` is the alternative for search that does not run through a model at all — ``ExaWebSearchBackend`` queries Exa directly and formats results as text. Either way, the resulting provider is installed on the client with `setWebSearchProvider(_:)`, and the `web_search` tool reports a clear error when none is set.

Thread memory search — the `kt_search_threads` tool — is SDK-owned rather than delegated. Reach is decided first: `retrievableSemanticMemoryScopes(for:on:)` resolves which threads a context is entitled to search, which is its own threads plus every other context and thread that shares one of its tags, each returned as a ``KeepTalkingSemanticMemoryScope`` carrying the tags that matched. Retrieval then runs inside that fence. ``KeepTalkingClient/retrieveSemanticMemory(query:topK:scopes:semanticSearch:on:)`` runs a lexical pass over the scoped thread documents and, in parallel, the app's optional embedding callback, then fuses the two rankings reciprocally and normalises the scores.

The division matters: scope enforcement and the lexical leg are the SDK's, and the injected ``KeepTalkingClient/SemanticSearchCallback`` is only a ranking signal — its results are filtered back down to the allowed threads regardless of what it returns. A host that installs no callback still gets working search, just without the embedding leg. On top of the local result the tool fans out to any peer exposing a semantic-retrieval action, and merges the returned rows by score.

The action tools the agent can actually reach are described by ``KeepTalkingActionToolDefinition`` — a function name, a JSON-schema parameter object, the owning node and action IDs, and a ``KeepTalkingActionToolDefinition/Source`` tag. ``KeepTalkingClient/discoverActionToolCatalog(in:)`` returns the ``KeepTalkingActionToolCatalog`` for a context.

### Three agent roles

**The main agent** is ``AIOrchestrator``. It runs the execution loop: complete a turn, publish anything the model produced, execute whatever tools it asked for, append the results to the transcript, and go again — up to `maxTurns`, which defaults to 32. Publishing is ordered so the conversation reads correctly: reasoning first as a `thinking` message, then the assistant text, then a single intermediate message describing the tools about to run. Tool calls are executed one at a time, in the order the model emitted them, each retried on its own up to `maxToolRetries` times — two by default — with an optional observer so a host can surface the retry. Cancellation is checked between turns and between individual tools, so a cancelled run stops promptly instead of draining a multi-tool batch first. Progress is recorded in an ``AIAgentCheckpoint`` after every turn and every completed tool call, so a host that persists one can resume a run where it stopped rather than replaying it.

The orchestrator's collaborators are all injected through ``AIOrchestrator/Dependencies``: how to run a turn, how to build the assistant message from a result, how to execute tools, how to adapt executions back into transcript messages, how to publish to the conversation, and how to name and describe a tool call for the UI. That last pair — ``AIOrchestrator/ToolNameResolver`` and ``AIOrchestrator/ToolHintResolver`` — is what turns `kt_search_threads` into "Searching for …" with the query attached, using the hints in ``AIOrchestrator/IntermediateMessageHints``.

Publishing comes in two shapes. ``AIOrchestrator/AssistantPublisher`` writes ordinary rows — the `thinking` message, the assistant text. ``AIOrchestrator/ToolHintPublisher`` writes the tool-hint row and hands the host that row's arguments *in the clear* as a third parameter, because the orchestrator holds no key material and cannot seal them itself. A host that supplies no hint publisher gets a default that falls through to the assistant publisher and drops the arguments entirely: the row publishes bare rather than ever carrying them unsealed.

**The ACT agent** — action-calling-turn — is reached exclusively through the `kt_run_action` tool, modelled as ``AIOrchestrator/ACTAgent``: a `canHandle` predicate and an executor. When the main model has chosen an action, it calls `kt_run_action` with the action ID and a natural-language task, plus optional input handles for files to feed in and output slots for files it wants back. The ACT agent then runs its own short loop against the selected action alone: it resolves that action's tools, calls the appropriate one with arguments derived from the task, and distils the result into a short summary. This is why the main loop stays meta-tool only — schema resolution and argument construction happen one level down, against one action, instead of flooding the primary context with every tool on every node.

The ACT agent runs at `.planning` stage, uses the `actConnector` and `actModel` when configured, and publishes trace rows through the same ``AIOrchestrator/ToolHintPublisher`` the main loop uses, so each inner step folds into the parent tool-call row in the conversation and its arguments are sealed on the way in. It also aggregates the `produced_resources` its inner calls emit and passes them up, so files an action produced reach the main agent by handle rather than being lost inside prose. ``KeepTalkingClient/makeSkillPlannerACTAgent(contextID:actModel:)`` builds the same agent bound to a context for use inside the skill planner, with a no-op publisher.

**The audio agent**, ``AudioInterfaceAgent``, is explicitly not a standalone agent — it is a voice-to-text bridge with the main agent behind it. Its run has three phases. First it sends the user's audio to an audio-capable model with one tool available, `delegate_to_agent`, and asks it to respond briefly in speech and extract an intent; greetings and small talk are answered directly and never delegated. Second, it hands the extracted ``AudioInterfaceAgent/DelegationRequest`` to the main agent through the ``AudioInterfaceAgent/Delegate`` closure — and because audio models emit speech or a tool call but not both, a delegating turn produces no audio, so the bridge speaks a short acknowledgement concurrently with the (often slow) delegation. Third, it rephrases the answer for spoken delivery.

The delegate returns ``AudioInterfaceAgent/DelegateOutcome``. `.answered` carries the text to speak. `.deferred` means the backend turn suspended on something out of band — a confirmation, another participant, a file — in which case the bridge speaks a short status and ends the voice turn rather than holding a possibly-doomed call open; the real answer lands in the conversation as a normal message. ``AudioInterfaceAgent/speak(text:connector:audioOutputHandler:)`` exists for exactly that case: reading a deferred result aloud later, if the user is still on the call when it resolves.

### Sealed call parameters

A tool-hint row is a context message, so it replicates to every member of the context — not just the peer being asked to do the work. Arguments are the most revealing thing an agent turn produces, though: a shell command, a file path, a search query. So the row and its arguments are separated. The hint, action, and target node stay legible to everyone; the arguments are sealed to the two ends of the call.

The seal happens in exactly one place, in the client's hint publisher, on the way from the orchestrator to the conversation. The row's own `targetNodeID` names the recipient, so caller and callee can both open it. A `nil` target means a built-in or local tool, which seals to this node — where both ends of the call are us, and no other peer is entitled to the contents either. The result lands in the `sealedParameters` payload of the `.intermediate` message type; a third peer holds the row but no key material, so its inspector simply has nothing to show.

``KeepTalkingClient/openSealedCallParameters(_:)`` is the read side, and it tries the recipient path then the sender path — one of the two succeeds on each end of a call, neither anywhere else. ``KeepTalkingClient/continuationCallParameters(for:)`` does the equivalent for a suspended continuation, whose request is already sealed inside the continuation message, so an approval bubble can show what it is being asked to authorize. ``KeepTalkingCallParameters`` gives both surfaces one presentation order, so the same call reads the same way in the approval alert, the continuation card, and the chat inspector.

Sealing is never worth failing a turn over: if it fails, the arguments are dropped and the row renders without them.

### Queueing runs

``KeepTalkingClient/enqueueAIPrompt(_:attachments:in:model:actModel:roleName:reasoningEffort:)`` is the normal entry point. It prepares attachments, mints an agent turn ID, and hands a unit of work to the coordinator, returning a stable run ID immediately.

```swift
let runID = await client.enqueueAIPrompt(
    "Summarise what changed in this conversation today.",
    in: contextID,
    model: modelID,          // must match the active provider's naming
    reasoningEffort: .medium
)
```

Two details matter. The user's prompt message is sent to the conversation only when the run actually starts, so a queued prompt stays invisible until it is its turn — the conversation never shows a question that has not begun being answered. And the queued work is split in two: the full closure sends the prompt and then runs the AI, while the retry closure runs only the AI, because on retry the prompt is already in the context from the first attempt.

Within a context, local turns are serialized: the first enqueued run starts immediately and the rest form a per-context backlog that advances automatically. Runs are not globally serial, though — different contexts proceed independently, a suspended turn frees its slot, and work this node performs on behalf of other nodes joins the same queue. That is why the component is a coordinator rather than a queue.

Hosts that need a prompt to survive navigation, app switching, or process death should own their own durable queue and call ``KeepTalkingClient/runDequeuedAIPrompt(_:attachments:in:model:actModel:roleName:reasoningEffort:sendPromptMessage:promptType:agentTurnID:onPromptMessageSent:checkpoint:onCheckpoint:)`` when an item reaches the head; it deliberately does not touch the in-memory coordinator, and it returns the run's final assistant text so a caller such as the voice bridge can speak it. It also takes an ``AIAgentCheckpoint`` to resume an interrupted run from, plus a callback fired with each new one to persist. ``KeepTalkingClient/runAI(prompt:in:model:actModel:roleName:currentPromptAttachments:)`` is the direct, unqueued path used by the CLI and internal callers.

### Run lifecycle

Every run the coordinator knows about appears in ``KeepTalkingAgentRunSnapshot``, pushed to `onAgentRunsChanged` on each transition. A run is in exactly one ``KeepTalkingAgentRunSnapshot/State``:

| State | Meaning |
|---|---|
| `queued` | In a context's backlog, not yet started. Its prompt is not in the conversation yet. |
| `running` | Holds the context's active slot, or has resumed from suspension. |
| `suspended` | Parked awaiting an out-of-band continuation. Its slot has been released. |
| `failed(message:)` | Threw, and is being kept so the user can retry or dismiss it. |

There is no completed state: a run that finishes simply leaves the snapshot list. Failures are parked only for resumable local turns — a delegated run has already unwound its awaiting caller by the time it fails, so re-running it would be unsound, and it is discarded instead. ``KeepTalkingClient/retryAgentRun(_:)`` re-runs a parked failure using the AI-only closure, ``KeepTalkingClient/dismissAgentRun(_:)`` drops it, and ``KeepTalkingClient/cancelAgentRun(_:)`` stops a run in any state and writes a permanent cancellation marker into the conversation so the transcript records where it stopped. Cancellation frees the slot at once and lets the next queued run start while the cancelled task unwinds in the background.

### Suspension and resumption

A turn suspends when it needs an answer that cannot come from the model: a remote node must execute something, a user must approve an authorization bubble, someone must pick a file. The SDK writes a continuation message into the conversation, fires `onAgentTurnSuspended` with a ``KeepTalkingAgentTurnSuspension`` naming the turn, the step within it, the kind, and the node that must respond, and then parks.

One run can suspend more than once — a multi-step turn may need two approvals, or a remote execution and then a file. So a suspension is identified by its own persisted continuation message rather than by the run it belongs to: that ID is the `agentStepID` on both the suspension and the resumption, and it is what a response is matched against. `agentTurnID` still names the outer run, which is what cancellation and reconciliation work in terms of.

Parking releases the context's active slot on purpose. A turn waiting on a human or a remote peer must not hold the conversation hostage, so a queued run may start while this one waits, and the two may briefly overlap when it resumes. When the response arrives, `onAgentTurnResumed` fires with a ``KeepTalkingAgentTurnResumption`` — on rejection as well as fulfilment, since either way the turn is running again. A response that arrives before its continuation has finished parking is stashed against that continuation's ID and picked up the moment it does, so the race is closed rather than lost.

The responding side calls ``KeepTalkingClient/respondToAgentTurnContinuation(continuationMessageID:agentTurnID:originNodeID:state:resultContent:producedResources:outputTransfers:)``, which encrypts the full result — content plus produced resources plus private output transfers — to the originating node, because a blocking action must deliver everything the direct result path would. When the approval is local, ``KeepTalkingClient/fulfilAgentTurnContinuation(continuationMessageID:)`` executes the original call on this node instead. Cancelling a suspended run resolves its continuation with a cancellation error, and ``KeepTalkingClient/reconcileStaleContinuations()`` cleans up on connect, cancelling pending continuations whose turns are no longer alive.

## Topics

### The connector seam

- ``AIConnector``
- ``AIConnectorCapabilities``
- ``AIStage``
- ``AITurnConfiguration``
- ``AIReasoning``
- ``AIReasoning/Effort``
- ``AIResponseFormat``

### The message IR

- ``AIMessage``
- ``AIMessage/Role``
- ``AIMessage/Content``
- ``AIMessage/Part``
- ``AIMessage/user(parts:name:)``
- ``AIMessage/assistantToolCalls(_:text:name:audioReference:)``
- ``AIMessage/tool(_:toolCallID:name:)``
- ``AIToolCall``
- ``AIToolChoice``
- ``AITurnResult``

### Audio turns

- ``AIAudioOutput``
- ``AIAudioOutputConfig``
- ``AIStreamingAudioHandler``

### Built-in connectors

- ``OpenAIConnector``
- ``OpenAIConnectorBackend``
- ``AnthropicConnector``
- ``AnthropicConnectorBackend``

### Tools the agent is given

- ``KeepTalkingActionToolDefinition``
- ``KeepTalkingActionToolDefinition/Source``
- ``KeepTalkingActionToolCatalog``
- ``KeepTalkingActionStub``
- ``KeepTalkingClient/discoverActionToolCatalog(in:)``

### Thread memory search

- ``KeepTalkingSemanticMemoryScope``
- ``KeepTalkingSemanticMemoryScope/Target``
- ``KeepTalkingSemanticMemoryScope/Tag``
- ``KeepTalkingClient/retrieveSemanticMemory(query:topK:scopes:semanticSearch:on:)``
- ``KeepTalkingSemanticSearchResult``
- ``KeepTalkingClient/SemanticSearchCallback``
- ``KeepTalkingClient/setSemanticSearchCallback(_:)``

### Web search

- ``KeepTalkingWebSearchTool``
- ``WebSearchToolConfiguration``
- ``OpenRouterWebSearchTool``
- ``OpenAIWebSearchTool``
- ``StandaloneWebSearchBackend``
- ``StandaloneWebSearchConfiguration``
- ``ExaWebSearchBackend``
- ``KeepTalkingClient/setWebSearchProvider(_:)``

### The main agent

- ``AIOrchestrator``
- ``AIOrchestrator/Dependencies``
- ``AIOrchestrator/Configuration``
- ``AIOrchestrator/run(messages:tools:model:toolChoice:turnConfiguration:checkpoint:onCheckpoint:)``
- ``AIAgentCheckpoint``
- ``AIOrchestrator/ToolExecution``
- ``AIOrchestrator/ToolHintContext``
- ``AIOrchestrator/IntermediateMessageHints``
- ``AIOrchestrator/AssistantPublisher``
- ``AIOrchestrator/ToolHintPublisher``

### Sealed call parameters

- ``KeepTalkingCallParameters``
- ``KeepTalkingClient/openSealedCallParameters(_:)``
- ``KeepTalkingClient/continuationCallParameters(for:)``

### The ACT agent

- ``AIOrchestrator/ACTAgent``
- ``KeepTalkingClient/makeSkillPlannerACTAgent(contextID:actModel:)``

### The audio interface agent

- ``AudioInterfaceAgent``
- ``AudioInterfaceAgent/Configuration``
- ``AudioInterfaceAgent/run(audioData:inputFormat:contextID:connector:delegate:audioOutputHandler:statusObserver:routingContext:)``
- ``AudioInterfaceAgent/speak(text:connector:audioOutputHandler:)``
- ``AudioInterfaceAgent/DelegationRequest``
- ``AudioInterfaceAgent/DelegateOutcome``
- ``AudioInterfaceAgent/BridgeResult``
- ``AudioInterfaceAgent/BridgeStatus``
- ``AudioInterfaceAgentError``

### Queueing and running turns

- ``KeepTalkingClient/enqueueAIPrompt(_:attachments:in:model:actModel:roleName:reasoningEffort:)``
- ``KeepTalkingClient/runDequeuedAIPrompt(_:attachments:in:model:actModel:roleName:reasoningEffort:sendPromptMessage:promptType:agentTurnID:onPromptMessageSent:checkpoint:onCheckpoint:)``
- ``KeepTalkingClient/runAI(prompt:in:model:actModel:roleName:currentPromptAttachments:)``
- ``KeepTalkingClient/cancelAgentRun(_:)``
- ``KeepTalkingClient/retryAgentRun(_:)``
- ``KeepTalkingClient/dismissAgentRun(_:)``

### Run lifecycle and suspension

- ``KeepTalkingAgentRunSnapshot``
- ``KeepTalkingAgentRunSnapshot/State``
- ``KeepTalkingAgentTurnSuspension``
- ``KeepTalkingAgentTurnResumption``
- ``KeepTalkingClient/respondToAgentTurnContinuation(continuationMessageID:agentTurnID:originNodeID:state:resultContent:producedResources:outputTransfers:)``
- ``KeepTalkingClient/fulfilAgentTurnContinuation(continuationMessageID:)``
- ``KeepTalkingClient/reconcileStaleContinuations()``
