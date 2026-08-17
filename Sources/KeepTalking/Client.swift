import FluentKit
import Foundation
import MCP

public enum KeepTalkingClientError: LocalizedError {
    case kvServiceNotConfigured
    case missingNode
    case missingAction
    case missingMapping(UUID)
    case aiNotConfigured
    case unknownTool(String)
    case invalidToolArguments(String)
    case actionNotHostedLocally(UUID)
    case relationNotTrustedOrOwned(UUID)
    case actionCallNotAuthorized(action: UUID, caller: UUID, context: UUID)
    case actionCallTimeout(UUID)
    /// Gave up waiting for a remote action-call result because the target node
    /// went offline while we were patiently waiting on it.
    case actionCallTargetOffline(requestID: UUID, targetNodeID: UUID)
    case actionCatalogTimeout(UUID)
    case contextSyncTimeout(UUID)
    case contextSyncRemoteFailure(
        requestID: UUID,
        responder: UUID,
        message: String
    )
    case localExecutorRegistrationTimedOut(
        actionID: UUID,
        source: String,
        actionName: String,
        timeoutSeconds: TimeInterval
    )
    case localExecutorRegistrationFailed(
        actionID: UUID,
        source: String,
        actionName: String,
        message: String
    )
    case localIdentityPrivateKeyMissing
    case remoteIdentityPublicKeyMissing(UUID)
    case remoteIdentityPublicKeyInvalid(UUID)
    case malformedEncryptedActionCall
    case malformedEncryptedRequestAck
    case malformedEncryptedActionCatalog
    case malformedEncryptedNodeStatus
    case unsupportedActionPayload
    case missingRelation
    case missingContextSecret(UUID)
    case missingContext(UUID?)
    case invalidTurningPoint(UUID)
    case invalidContinuationMessage
    case notAuthorized
    case invalidTrustScope
    /// In-flight call/sync/request rejected because the client is being
    /// torn down (e.g. `disconnect()`).
    case clientDisconnected
    /// `makeVoiceSession` was called but the client has no SFU endpoint
    /// configured. Voice requires SFU presence + signaling.
    case noSFUEndpointConfigured
    case invalidSideNote(String)
    /// Message content exceeds what a single envelope can carry. Refused at
    /// creation: transport no longer fragments, so a message this large could
    /// never be delivered *or* replicated, and persisting it would leave an
    /// undeliverable outbox row and a sync page that cannot be served.
    case messageTooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
            case .kvServiceNotConfigured:
                return "KV service is not configured."
            case .missingNode:
                return "KeepTalkingConfig.node is required for KV node registration."
            case .missingAction:
                return "Action is not found required for the operation."
            case .missingMapping(let mappingID):
                return "Mapping is not found: \(mappingID)"
            case .aiNotConfigured:
                return "OpenAI is not configured. Set OPENAI_API_KEY to enable AI tool planning."
            case .unknownTool(let functionName):
                return "Tool is not in the normalized action catalog: \(functionName)"
            case .invalidToolArguments(let raw):
                return "Tool arguments are not valid JSON object: \(raw)"
            case .actionNotHostedLocally(let actionID):
                return "Action is not hosted by this node: \(actionID)"
            case .relationNotTrustedOrOwned(let nodeID):
                return "No trusted/owned relation exists to node: \(nodeID)"
            case .messageTooLarge(let bytes, let limit):
                return
                    "Message content is \(bytes) bytes, above the \(limit)-byte limit a single envelope can carry."
            case .actionCallNotAuthorized(let actionID, let caller, let context):
                return "Action call is not authorized. action=\(actionID) caller=\(caller) context=\(context)"
            case .actionCallTimeout(let requestID):
                return "Timed out waiting for remote action call result: \(requestID)"
            case .actionCallTargetOffline(let requestID, let targetNodeID):
                return
                    "Target node \(targetNodeID.uuidString.lowercased()) went offline while waiting for action call result: \(requestID.uuidString.lowercased())"
            case .actionCatalogTimeout(let requestID):
                return "Timed out waiting for remote action catalog result: \(requestID)"
            case .contextSyncTimeout(let requestID):
                return "Timed out waiting for remote context sync result: \(requestID)"
            case .contextSyncRemoteFailure(
                let requestID,
                let responder,
                let message
            ):
                return
                    "Peer \(responder.uuidString.lowercased()) failed context sync request \(requestID.uuidString.lowercased()): \(message)"
            case .localExecutorRegistrationTimedOut(
                let actionID,
                let source,
                let actionName,
                let timeoutSeconds
            ):
                return
                    "Timed out registering \(source) executor '\(actionName)' (\(actionID.uuidString.lowercased())) after \(Int(timeoutSeconds))s."
            case .localExecutorRegistrationFailed(
                let actionID,
                let source,
                let actionName,
                let message
            ):
                return
                    "Failed registering \(source) executor '\(actionName)' (\(actionID.uuidString.lowercased())): \(message)"
            case .localIdentityPrivateKeyMissing:
                return "Local private identity key is missing."
            case .remoteIdentityPublicKeyMissing(let nodeID):
                return "No remote public key is known for node: \(nodeID)"
            case .remoteIdentityPublicKeyInvalid(let nodeID):
                return "Remote public key is invalid for node: \(nodeID)"
            case .malformedEncryptedActionCall:
                return "Encrypted action-call envelope payload is malformed."
            case .malformedEncryptedRequestAck:
                return "Encrypted request-ack envelope payload is malformed."
            case .malformedEncryptedActionCatalog:
                return "Encrypted action-catalog envelope payload is malformed."
            case .malformedEncryptedNodeStatus:
                return "Encrypted node-status envelope payload is malformed."
            case .unsupportedActionPayload:
                return "Action payload is unsupported by local executors."
            case .missingRelation:
                return "Missing relation."
            case .missingContextSecret(let contextID):
                return "Missing context secret for context: \(contextID)"
            case .missingContext(let contextID):
                return "Context not found: \(String(describing: contextID))"
            case .invalidTurningPoint(let messageID):
                return "Message cannot be used as a turning point (not found or is the first message): \(messageID)"
            case .invalidContinuationMessage:
                return "Agent turn continuation message is invalid or expired."
            case .notAuthorized:
                return "Operation not authorized."
            case .invalidTrustScope:
                return
                    "Trust scope must include at least one context (or use \"all contexts\")."
            case .clientDisconnected:
                return "Client is disconnecting; in-flight operation cancelled."
            case .noSFUEndpointConfigured:
                return "No SFU endpoint is configured for this client; voice requires SFU presence + signaling."
            case .invalidSideNote(let detail):
                return "Side note is invalid: \(detail)"
        }
    }
}

/// High-level entry point for messaging, node coordination, and action execution.
public final class KeepTalkingClient: @unchecked Sendable {
    public static let availablePrimitiveActions =
        KeepTalkingPrimitiveBundle.availablePrimitiveActions
    public typealias MCPHTTPAuthURLHandler =
        @Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult
    public typealias ActionApprovalHandler =
        @Sendable (KeepTalkingActionCallRequest, KeepTalkingAction, KeepTalkingContext) async -> Bool
    public typealias PrimitiveActionPostResultHandler =
        @Sendable (KeepTalkingPrimitiveBundle, KeepTalkingActionCall) -> Void
    /// Optional app-provided semantic ranking signal. Canonical scope
    /// enforcement and lexical retrieval remain SDK-owned.
    public typealias SemanticSearchCallback =
        @Sendable (String, Int) async throws -> [KeepTalkingSemanticSearchResult]
    /// Callback that performs a web search. Used when the connector is in chat-completions
    /// mode (e.g. OpenRouter) where web search is a client-side function call rather than
    /// a built-in Responses API tool. Parameter: query string. Returns raw result text.
    public typealias WebSearchProvider = @Sendable (String) async throws -> String

    public typealias EnvelopeHandler = @Sendable (any KeepTalkingEnvelope) -> Void
    public typealias RawMessageHandler = @Sendable (String) -> Void
    public typealias BlobAvailabilityHandler = @Sendable (UUID, String) -> Void
    public typealias PeerConnectHandler = @Sendable (UUID) -> Void
    public typealias ContextSyncHandler =
        @Sendable (KeepTalkingContextSyncEvent) async -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    public var onEnvelope: EnvelopeHandler?
    public var onRawMessage: RawMessageHandler?
    /// Fires when a blob changes availability or crosses a visible receive-progress step.
    public var onBlobAvailabilityChange: BlobAvailabilityHandler?
    public var onPeerConnect: PeerConnectHandler?
    public var onContextSync: ContextSyncHandler?
    /// Fires when a context's side notes changed — locally or by merge. The
    /// app uses it to refresh the notes UI and reload the widget timeline.
    public var onSideNotesChanged: (@Sendable (UUID) async -> Void)?
    public var onThreadsChanged: (@Sendable () -> Void)?
    /// Requests reconciliation of the derived semantic index for a context.
    /// The handler should enqueue best-effort work and return promptly; the
    /// persisted thread rows remain the source of truth.
    public var onSemanticIndexNeedsReconciliation: (@Sendable (UUID) async -> Void)?
    public var onMappingsChanged: (@Sendable () -> Void)?
    public var onActionCallActivity: (@Sendable (KeepTalkingActionCallActivity) async -> Void)?
    public var onAgentRunsChanged: (@Sendable ([KeepTalkingAgentRunSnapshot]) -> Void)? {
        didSet { agentCoordinator.onChanged = onAgentRunsChanged }
    }
    /// Called when an agent run finishes (normally, with error, or after cancellation).
    /// Receives the context ID and the error if the run failed, or nil on success/cancel.
    public var onAgentRunCompleted: (@Sendable (UUID, (any Error)?) -> Void)?
    /// Fired the moment an agent turn suspends to wait on an out-of-band
    /// continuation. A non-blocking driver (e.g. the voice bridge) uses this to
    /// acknowledge and detach — see `KeepTalkingAgentTurnSuspension`.
    public var onAgentTurnSuspended: (@Sendable (KeepTalkingAgentTurnSuspension) -> Void)?
    /// Symmetric counterpart to `onAgentTurnSuspended`: fired when a previously
    /// suspended turn resumes (its continuation was answered — fulfilled or
    /// rejected — or an early response was already waiting). A driver that
    /// detached on suspend uses this to flip the run's UI back from "waiting"
    /// to "running" — see `KeepTalkingAgentTurnResumption`.
    public var onAgentTurnResumed: (@Sendable (KeepTalkingAgentTurnResumption) -> Void)?
    /// Fired whenever a voice-call transcript line is persisted — both locally
    /// appended (own mic) and received from a peer. The app drives the live
    /// quick-panel + viewer from this. Carries the Sendable envelope payload so
    /// no Fluent model crosses the actor boundary.
    public var onVoiceTranscriptLine: (@Sendable (KeepTalkingVoiceCallTranscriptLinePayload) -> Void)?
    /// Display name of *this* node's voice agent — the configured wake keyword,
    /// shown beside the node name when rendering the agent's `.realtime`
    /// transcript lines. The app sets it from its voice settings; nil (or a
    /// peer-authored line, whose wake keyword we don't know) falls back to "ai".
    public var localVoiceAgentName: String?
    public var onLog: LogHandler? {
        didSet {
            rtcClient.onLog = onLog
            Task { [weak self] in
                guard let self else { return }
                await self.skillManager.setLogHandler(self.onLog)
                await self.mcpManager.setLogHandler(self.onLog)
            }
        }
    }

    public var aiEnabled: Bool {
        aiConnector != nil
    }

    public let logon: UUID
    /// Tracks which contexts have an ongoing joinable voice call, fed
    /// by inbound `voiceCallStarted` / `voiceCallEnded` envelopes. The
    /// app reads from this to glow the in-context Voice button when
    /// another participant has started a call but local self hasn't
    /// joined yet.
    public let voiceCallPresence = KeepTalkingVoiceCallPresenceRegistry()
    /// In-memory voice-call bookkeeping, keyed by session id. Replaces the former
    /// `kt_voice_calls` table — voice calls are never persisted; only their
    /// transcript lines and the sealed `.voiceCallSeal` entry are durable.
    let voiceCalls = KeepTalkingVoiceCallRegistry()
    /// The periodic maintenance heartbeat (ContextMaintenance `.heartbeat`
    /// trigger). Started on `connect()`, cancelled on `disconnect()`.
    var maintenanceTask: Task<Void, Never>?
    /// Ancillary work that starts after the transport is usable. It must not
    /// keep `connect()` — and therefore the app's connection UI — pending.
    var postConnectTask: Task<Void, Never>?
    var activeVoiceSession: KeepTalkingVoiceSession?
    let config: KeepTalkingConfig
    let rtcClient: any KeepTalkingTransportClient
    let kvService: (any KeepTalkingKVService)?
    public let localStore: any KeepTalkingLocalStore
    public let keychain: any KeepTalkingKeychainStore
    let openAIBackend: OpenAIConnectorBackend
    /// Default model identifier passed to internally-driven agent loops
    /// (`SkillManager.callAction`, etc.) when the caller does not supply one
    /// explicitly. Set this to the active provider's model so OpenRouter and
    /// other providers don't 404 on the OpenAI-style default.
    public let openAIModel: String?
    public let responseLanguages: [String]
    let livenessState: KeepTalkingContextLivenessState
    let mcpManager: MCPManager
    let mcpCredentialStore: KeepTalkingMCPCredentialStore
    let skillManager: SkillManager
    let primitiveActionManager: PrimitiveActionManager
    let semanticRetrievalActionManager: SemanticRetrievalActionManager
    let filesystemActionManager: FilesystemActionManager
    #if os(macOS)
    let scopeManager: ScopeManager
    let acpManager: ACPManager
    /// Shared per-node KTPP host. Constructed eagerly but INERT — it listens
    /// only after `enablePluginHost()`, so a node that never uses plugins pays
    /// nothing beyond reading the Catalogue file.
    public let pluginHost: KeepTalkingPluginHost
    #endif
    let aiConnector: (any AIConnector)?
    /// Connector used by the ACT (action/tool-calling) sub-agent. `nil` means
    /// the ACT agent shares the main `aiConnector`; set it only when the ACT
    /// role is configured with a different provider/endpoint than the main
    /// agent. Resolved via `resolveACTConnector()`.
    let actConnector: (any AIConnector)?
    let blobStore: KeepTalkingBlobStore
    /// Per-thread isolated execution workspaces (scratch/output dirs used as the
    /// cwd for skill / provider-side ACT runs); reaped on thread archive/delete.
    let threadWorkspaces: KeepTalkingThreadWorkspaceManager
    private var mcpHTTPAuthURLHandler: MCPHTTPAuthURLHandler?
    var actionApprovalHandler: ActionApprovalHandler?
    var primitiveActionPostResultHandler: PrimitiveActionPostResultHandler?
    let primitiveRegistry: KeepTalkingPrimitiveRegistry?
    var semanticSearchCallback: SemanticSearchCallback?
    var webSearchProvider: WebSearchProvider?
    var jsRuntime: (any KeepTalkingJSRuntime)?

    // MARK: Agent coordination
    let agentCoordinator = AgentCoordinator()
    /// Coordinates work this node runs ON BEHALF OF a caller (provider-side ACT
    /// today; task delegation on the roadmap) — cancel-only runs in the
    /// `agentCoordinator`, plus the orchestrator-summon seam.
    lazy var delegationCoordinator = KeepTalkingDelegationCoordinator(
        queue: agentCoordinator, log: { [weak self] in self?.onLog?($0) })

    // MARK: Action Call properties
    let actionCallQueue = DispatchQueue(
        label: "KeepTalking.client.action-call"
    )
    var pendingActionCallAcknowledgements: [UUID: CheckedContinuation<KeepTalkingRequestAck, Error>] = [:]
    var receivedActionCallAcknowledgements: [UUID: KeepTalkingRequestAck] = [:]
    var receivedActionCallAcknowledgementOrder: [UUID] = []
    var pendingActionCallResults: [UUID: CheckedContinuation<KeepTalkingActionCallResult, Error>] = [:]
    var receivedActionCallResults: [UUID: KeepTalkingActionCallResult] = [:]
    var receivedActionCallResultOrder: [UUID] = []
    var inFlightIncomingActionCalls: [UUID: Task<KeepTalkingActionCallResult, Never>] = [:]
    var completedIncomingActionCallResults: [UUID: KeepTalkingActionCallResult] = [:]
    var completedIncomingActionCallOrder: [UUID] = []
    /// Caller node per in-flight incoming action call — the authorization key for a
    /// cancel (only the original caller may cancel its run). Cleared on finalize.
    var incomingActionCallCallers: [UUID: UUID] = [:]
    /// Cancels that arrived before their target request (reorder / push-wake-first):
    /// target requestID → canceller node. Consumed when the request lands.
    var cancelledBeforeArrival: [UUID: UUID] = [:]
    var cancelledBeforeArrivalOrder: [UUID] = []

    // MARK: Action Catalog properties
    let actionCatalogQueue = DispatchQueue(
        label: "KeepTalking.client.action-catalog"
    )
    var pendingActionCatalogResults: [UUID: CheckedContinuation<KeepTalkingActionCatalogResult, Error>] = [:]

    // MARK: Context Sync properties
    // One request/response registry per result type — each owns its pending
    // continuations + timeout (see KeepTalkingSyncResponseRegistry). Both
    // contextSyncing and transcriptSyncing dispatch through these.
    let syncSummaries = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncSummaryResult>()
    let syncMessages = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncMessagesResult>()
    let syncTranscriptSummaries = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncTranscriptSummaryResult>()
    let syncTranscriptLines = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncTranscriptLinesResult>()
    let contextSyncSingleFlight = KeepTalkingContextSyncSingleFlight()

    /// Serialises mark consumption per context, so two syncs completing at
    /// once cannot both apply the same projection.
    let markConsumptionGate = KeepTalkingSerialGate()

    // MARK: Trust handshake properties
    let trustQueue = DispatchQueue(
        label: "KeepTalking.client.trust"
    )
    var pendingTrustSessions: [UUID: KeepTalkingPendingTrustSession] = [:]
    var incomingTrustHandler: KeepTalkingIncomingTrustHandler?
    /// Trust-request session ids this node has taken responsibility for.
    /// Guarded by `trustQueue`.
    ///
    /// Claimed before the human-latency await so a redelivery cannot raise a
    /// second prompt, and — unlike a purely in-flight claim — kept after the
    /// decision settles. A trust request redelivered *after* acceptance is the
    /// same hazard as one redelivered during it: re-accepting mints a fresh
    /// ephemeral keypair and overwrites the pending session, so the initiator
    /// binds one transcript while this node holds another and the handshake
    /// strands. The claim is released only when the request failed before
    /// settling, so a genuine retry after a transient error still works.
    ///
    /// Growth is bounded in practice: entries are one per human-initiated trust
    /// request, for the lifetime of the client.
    var handledTrustRequestSessionIDs: Set<UUID> = []

    // MARK: Blob request/response properties
    let blobTransportQueue = KeepTalkingBlobTransportQueue()

    let blobFrameProcessor = KeepTalkingBlobFrameProcessor()

    /// Reassembles inbound one-time-blob (OTB) transfers — ephemeral, encrypted,
    /// point-to-point file payloads carried alongside action calls.
    let oneTimeBlobAssembler = KeepTalkingOneTimeBlobAssembler()

    /// Holds files peers have preflighted (staged) onto this node ahead of a
    /// tool call, keyed by handle. A real call references the handle for its
    /// input file object.
    let stagedFileStore = KeepTalkingStagingIOStore()

    // MARK: Teardown serialization
    // `rtcClient.stop()` synchronously closes WebRTC peer connections, which
    // joins worker threads and can block for hundreds of milliseconds. We run
    // it on a detached task so MainActor callers don't freeze the UI, and
    // gate `connect()` on any in-flight teardown so a tight disconnect→connect
    // sequence still serializes correctly.
    private let lifecycleLock = NSLock()
    private var pendingTeardown: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var activeConnectGeneration: UInt64?
    private var isConnected = false
    private var isDisconnecting = false

    /// Inbound attachment DTOs whose parent message hasn't been persisted yet.
    /// Message and attachment arrive as *separate* envelopes, each handled in
    /// its own Task (see `rtcClient.onEnvelope`), so an attachment can land
    /// before its message. Rather than drop it (which left live-received
    /// attachments missing until a later full resync repopulated them via
    /// `saveContext`), buffer it here keyed by `parentMessageID` and re-drive
    /// when the parent message is saved. Guarded by `orphanAttachmentLock`.
    let orphanAttachmentLock = NSLock()
    var orphanAttachmentsByParentMessageID: [UUID: [KeepTalkingContextAttachmentDTO]] = [:]

    private func pendingTeardownSnapshot() -> Task<Void, Never>? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return pendingTeardown
    }

    private func beginConnect() -> UInt64? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard activeConnectGeneration == nil, !isConnected, !isDisconnecting else {
            return nil
        }
        lifecycleGeneration &+= 1
        activeConnectGeneration = lifecycleGeneration
        return lifecycleGeneration
    }

    private func ensureCurrentConnect(_ generation: UInt64) throws {
        try Task.checkCancellation()
        lifecycleLock.lock()
        let isCurrent =
            lifecycleGeneration == generation
            && activeConnectGeneration == generation
        lifecycleLock.unlock()
        if !isCurrent { throw CancellationError() }
    }

    private func prepareTransportStart(_ generation: UInt64) throws -> Task<Void, Error> {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lifecycleGeneration == generation,
            activeConnectGeneration == generation
        else { throw CancellationError() }
        return try rtcClient.start()
    }

    private func cancelConnect(_ generation: UInt64) {
        lifecycleLock.lock()
        if lifecycleGeneration == generation,
            activeConnectGeneration == generation
        {
            activeConnectGeneration = nil
        }
        lifecycleLock.unlock()
    }

    func isConnectionActive(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycleGeneration == generation && isConnected
    }

    private func connectionLifecycleSnapshot() -> UInt64? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isDisconnecting,
            activeConnectGeneration == lifecycleGeneration || isConnected
        else { return nil }
        return lifecycleGeneration
    }

    func isConnectionLifecycleActive(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lifecycleGeneration == generation
            && !isDisconnecting
            && (activeConnectGeneration == generation || isConnected)
    }

    private func commitConnect(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lifecycleGeneration == generation,
            activeConnectGeneration == generation
        else { return false }

        activeConnectGeneration = nil
        isConnected = true
        maintenanceTask?.cancel()
        maintenanceTask = makeMaintenanceTask(generation: generation)
        postConnectTask?.cancel()
        postConnectTask = Task { [weak self] in
            guard let self, self.isConnectionActive(generation) else { return }
            await self.dispatchMaintenance(
                .connected,
                generation: generation
            )
            guard !Task.isCancelled,
                self.isConnectionActive(generation),
                self.kvService != nil
            else { return }
            do {
                try await self.registerCurrentNodeID()
            } catch {
                self.debug("[kv] KV registration failed: \(error)")
            }
        }
        return true
    }

    private func beginDisconnect(ifConnecting expectedGeneration: UInt64? = nil) -> (
        Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>, UInt64
    )? {
        lifecycleLock.lock()
        if let expectedGeneration,
            lifecycleGeneration != expectedGeneration
                || activeConnectGeneration != expectedGeneration
        {
            lifecycleLock.unlock()
            return nil
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        activeConnectGeneration = nil
        isConnected = false
        isDisconnecting = true
        let tasks = (maintenanceTask, postConnectTask)
        maintenanceTask = nil
        postConnectTask = nil

        let previous = pendingTeardown
        let rtc = rtcClient
        let teardown = Task.detached(priority: .userInitiated) {
            if let previous { await previous.value }
            rtc.stop()
        }
        pendingTeardown = teardown
        lifecycleLock.unlock()
        return (tasks.0, tasks.1, teardown, generation)
    }

    private func finishDisconnect(_ generation: UInt64) {
        lifecycleLock.lock()
        if lifecycleGeneration == generation { isDisconnecting = false }
        lifecycleLock.unlock()
    }

    /// Creates a client with its transport, storage, and optional AI integrations.
    ///
    /// - Parameters:
    ///   - config: Session configuration for the local node.
    ///   - kvService: Optional KV backend used for node discovery and metadata.
    ///   - openAIAPIKey: Explicit OpenAI API key override.
    ///   - openAIEndpoint: Optional OpenAI-compatible endpoint override.
    ///   - openAIBackend: Which OpenAI-compatible backend to target. Defaults to OpenRouter.
    ///   - openAIModel: Default model identifier sent to the connector when
    ///                  the SDK runs internal agent loops (e.g. skill execution
    ///                  on incoming action calls). Should match the active
    ///                  provider's model — for OpenRouter this is provider-prefixed
    ///                  (e.g. `openai/gpt-5-codex`).
    ///   - responseLanguages: Preferred natural-language output languages for
    ///                        agent prompts. Empty means infer from the user.
    ///   - aiConnector: Optional pre-built connector for the main agent. When
    ///                  supplied it is used as-is and the `openAI*` parameters are
    ///                  ignored. When `nil`, the client builds an OpenAI-compatible
    ///                  connector from `openAIAPIKey` (falling back to the
    ///                  `OPENAI_API_KEY` environment variable); if no key is found
    ///                  anywhere, no connector is created and AI features stay off
    ///                  while messaging and transport continue to work.
    ///   - actConnector: Optional connector for the ACT (action/tool-calling)
    ///                   sub-agent. When `nil`, the ACT agent reuses
    ///                   `aiConnector`. Pass a distinct connector only when the
    ///                   ACT role targets a different provider/endpoint than the
    ///                   main agent.
    ///   - stdioTransportLauncher: Optional stdio transport launcher used for
    ///     MCP stdio actions.
    ///   - skillScriptExecutor: Optional skill script executor used for skill
    ///     script tool calls.
    ///   - primitiveRegistry: Optional registry supplying the platform primitive
    ///                        actions available to agents on this host. When `nil`,
    ///                        no primitive actions are exposed.
    ///   - logon: Correlation identifier for the current client runtime.
    ///   - localStore: Local persistence backend for models and state. Required —
    ///                 constructing a store is asynchronous and a default argument
    ///                 cannot await, so callers build the store first and inject it.
    ///   - keychain: Secure backing store for secrets that must never live in the
    ///               model database — group chat secrets, node identity private
    ///               keys, and credentials. Defaults to an in-memory store, which
    ///               forgets every secret on process exit; shipping hosts should
    ///               pass a persistent implementation.
    public init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        openAIAPIKey: String? = nil,
        openAIEndpoint: String? = nil,
        openAIBackend: OpenAIConnectorBackend = .openRouter,
        openAIModel: String? = nil,
        responseLanguages: [String] = [],
        aiConnector: (any AIConnector)? = nil,
        actConnector: (any AIConnector)? = nil,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        skillScriptExecutor: (any SkillScriptExecuting)? =
            DefaultSkillScriptExecutor.current,
        primitiveRegistry: KeepTalkingPrimitiveRegistry? = nil,
        logon: UUID = UUID(),
        // No default: constructing a store is now async, and a default argument
        // cannot await. Callers build the store first and inject it.
        localStore: any KeepTalkingLocalStore,
        keychain: any KeepTalkingKeychainStore = KeepTalkingInMemoryKeychainStore()
    ) {
        self.config = config
        self.kvService = kvService
        self.localStore = localStore
        self.keychain = keychain
        self.logon = logon
        self.openAIBackend = openAIBackend
        let trimmedModel = openAIModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIModel = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        self.responseLanguages = responseLanguages.reduce(into: []) { result, language in
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        self.blobStore = KeepTalkingBlobStore.makeDefault(for: localStore)
        self.threadWorkspaces = KeepTalkingThreadWorkspaceManager.makeDefault(for: localStore)
        livenessState = KeepTalkingContextLivenessState(
            localNode: config.node
        )
        self.rtcClient = KeepTalkingContextTransport(
            config: config,
            livenessState: livenessState
        )
        let mcpCredentialStore = KeepTalkingMCPCredentialStore(keychain: keychain)
        self.mcpCredentialStore = mcpCredentialStore
        self.mcpManager = MCPManager(
            nodeConfig: config,
            stdioTransportLauncher: stdioTransportLauncher,
            credentialStore: mcpCredentialStore
        )

        if let aiConnector {
            self.aiConnector = aiConnector
        } else {
            let apiKey =
                openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint =
                openAIEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ProcessInfo.processInfo.environment["OPENAI_ENDPOINT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let apiKey, !apiKey.isEmpty {
                self.aiConnector =
                    try? OpenAIConnector(apiKey: apiKey, endpoint: endpoint, backend: openAIBackend)
            } else {
                self.aiConnector = nil
            }
        }
        self.actConnector = actConnector
        self.skillManager = SkillManager(
            nodeConfig: config,
            aiConnector: self.aiConnector,
            scriptExecutor: skillScriptExecutor
        )
        self.primitiveRegistry = primitiveRegistry
        self.primitiveActionManager = PrimitiveActionManager(
            registry: primitiveRegistry
        )
        self.semanticRetrievalActionManager = SemanticRetrievalActionManager(
            database: localStore.database
        )
        self.filesystemActionManager = FilesystemActionManager()
        #if os(macOS)
        self.scopeManager = ScopeManager(sandbox: SeatbeltSandbox())
        self.pluginHost = KeepTalkingPluginHost.shared(forNode: config.node)
        self.acpManager = ACPManager(
            nodeConfig: config,
            stdioTransportLauncher: stdioTransportLauncher
        )
        #endif

        // All stored properties are initialized above; [weak self] is safe from here on.
        // Inject the one-time-blob transfer bridge: filesystem get-file streams a
        // host file straight to the caller, encrypted and point-to-point — no
        // context attachment, no broadcast, no record.
        filesystemActionManager.bridgeBox.bridge = FilesystemTransferBridge(
            sendOneTimeBlob: { [weak self] fileURL, filename, mimeType, recipient in
                guard let self else {
                    throw FilesystemActionManagerError.blobBridgeNotConfigured
                }
                return try await self.sendOneTimeBlob(
                    fileURL: fileURL,
                    filename: filename,
                    mimeType: mimeType,
                    to: recipient
                )
            }
        )

        // Clear any decrypted/ciphertext OTB temp dirs orphaned by a prior run.
        KeepTalkingClient.pruneStaleOneTimeBlobTempDirs()
        // Reap execution workspaces whose thread was archived/deleted while away.
        Task { [weak self] in await self?.reapOrphanThreadWorkspaces() }

        // Resolve the lazy delegation coordinator on the init thread so its first
        // touch can't race two concurrent callers, then wire the orchestrator-
        // summon seam: a delegated TASK (roadmap) drives a full main turn.
        _ = delegationCoordinator
        Task { [weak self] in
            guard let self else { return }
            await self.delegationCoordinator.setOrchestratorSummon {
                [weak self] contextID, prompt, _ in
                guard let self else { return }
                let context =
                    (try? await self.upsertContext(KeepTalkingContext(id: contextID)))
                    ?? KeepTalkingContext(id: contextID)
                _ = try? await self.runAI(prompt: prompt, in: context)
            }
        }

        rtcClient.onLog = { [weak self] line in
            self?.onLog?(line)
        }
        rtcClient.contextSecretProvider = { [weak self] contextID in
            try await self?.loadGroupChatSecret(for: contextID)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            guard let self, let generation = self.connectionLifecycleSnapshot(),
                self.isConnectionLifecycleActive(generation)
            else { return }
            self.onRawMessage?(raw)
        }
        rtcClient.onBlobData = { [weak self] data in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                do {
                    try await self.blobFrameProcessor.process {
                        guard self.isConnectionLifecycleActive(generation) else { return }
                        try await self.handleIncomingBlobFrameData(data)
                    }
                } catch {
                    self.onLog?(
                        "[client/blob] failed handling blob frame error=\(error.localizedDescription)"
                    )
                }
            }
        }
        rtcClient.onRealtimeData = { [weak self] data in
            guard let self, let generation = self.connectionLifecycleSnapshot(),
                self.isConnectionLifecycleActive(generation)
            else { return }
            _ = self.activeVoiceSession?.receiveRelayedFrame(data)
        }
        rtcClient.onEnvelope = { [weak self] envelope in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                do {
                    try await self.handleIncomingEnvelope(envelope)
                } catch {
                    self.onLog?(
                        "[client] failed handling envelope error=\(error.localizedDescription)"
                    )
                }
            }
        }
        rtcClient.onTrustEnvelope = { [weak self] envelope in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.handleIncomingTrustEnvelope(envelope)
            }
        }
        rtcClient.onPeerConnect = { [weak self] nodeID in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.handlePeerConnect(
                    nodeID: nodeID,
                    generation: generation
                )
            }
        }
        rtcClient.onBroadcastReady = { [weak self] in
            guard let self, let generation = self.connectionLifecycleSnapshot() else { return }
            Task {
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.drainOutbox()
                guard self.isConnectionLifecycleActive(generation) else { return }
                await self.dispatchMaintenance(
                    .heartbeat,
                    generation: generation
                )
            }
        }
    }

    public func isNodeOnline(_ node: UUID) -> Bool {
        livenessState.isNodeOnline(node)
    }

    public func onlineNodeIDs() -> Set<UUID> {
        livenessState.onlineNodeIDs()
    }

    public func setActionApprovalHandler(
        _ handler: ActionApprovalHandler?
    ) {
        actionApprovalHandler = handler
    }

    public func setPrimitiveActionPostResultHandler(
        _ handler: PrimitiveActionPostResultHandler?
    ) {
        primitiveActionPostResultHandler = handler
    }

    public func setSemanticSearchCallback(_ callback: SemanticSearchCallback?) {
        semanticSearchCallback = callback
        Task { [weak self] in
            await self?.semanticRetrievalActionManager.setSearchCallback(callback)
        }
    }

    public func setWebSearchProvider(_ provider: WebSearchProvider?) {
        webSearchProvider = provider
    }

    /// Installs (or removes) the JavaScript runtime that backs the
    /// `kt_evaluate_js` meta tool. When `nil`, the tool returns a
    /// "runtime not configured" error to the agent on call.
    public func setJSRuntime(_ runtime: (any KeepTalkingJSRuntime)?) {
        jsRuntime = runtime
    }

    func notifyContextSync(_ event: KeepTalkingContextSyncEvent) async {
        await onContextSync?(event)
    }

    func notifyBlobAvailabilityChange(contextID: UUID, blobID: String) {
        onBlobAvailabilityChange?(contextID, blobID)
    }

    /// Creates the default local store, preferring SQLite and falling back to memory.
    public static func makeDefaultLocalStore() async throws
        -> any KeepTalkingLocalStore
    {
        do {
            return try await KeepTalkingModelStore.make()
        } catch {
            return try await KeepTalkingInMemoryStore.make()
        }
    }

    /// Starts transports and persists local node state.
    ///
    /// Registering local action executors is intentionally NOT part of connect:
    /// a failing executor (e.g. an HTTP MCP server that needs re-auth) must never
    /// block bringing the transport up or pop a blocking auth prompt as a side
    /// effect of connecting. Callers that want executors live should invoke
    /// `registerLocalActionsInExecutors()` explicitly (the App and CLI do, off
    /// the connection path); the daemon opts out.
    public func connect() async throws {
        try Task.checkCancellation()
        guard let generation = beginConnect() else {
            throw KeepTalkingTransportError.allChannelsUnavailable
        }

        var transportStarted = false
        do {
            // Ensure any in-flight teardown from a previous disconnect() completes
            // before bringing the transport back up.
            if let teardown = pendingTeardownSnapshot() {
                await teardown.value
            }
            try ensureCurrentConnect(generation)

            await mcpManager.setHTTPAuthURLHandler(mcpHTTPAuthURLHandler)
            try ensureCurrentConnect(generation)
            _ = try await ensure(config.contextID, for: KeepTalkingContext.self)
            try ensureCurrentConnect(generation)

            openContextSyncRequests(generation: generation)
            let startTask = try prepareTransportStart(generation)
            transportStarted = true
            try await startTask.waitPropagatingCancellation()
            try ensureCurrentConnect(generation)
            try await persistMyNode()
            try ensureCurrentConnect(generation)

            guard commitConnect(generation) else { throw CancellationError() }
        } catch {
            if transportStarted,
                let teardown = scheduleDisconnect(ifConnecting: generation)
            {
                await teardown.value
            } else {
                failAllPendingContextSync(
                    error: KeepTalkingClientError.clientDisconnected
                )
                cancelConnect(generation)
            }
            throw error
        }
    }

    /// Stops transports and fails any pending remote requests.
    ///
    /// Lightweight bookkeeping (failing pending continuations, cancelling
    /// debounce tasks) runs synchronously. The WebRTC teardown is dispatched
    /// to a detached task because `peer.close()` synchronously joins WebRTC
    /// worker threads — calling it from MainActor would freeze the UI for
    /// hundreds of milliseconds. A subsequent `connect()` will await the
    /// in-flight teardown before restarting the transport.
    public func disconnect() {
        _ = scheduleDisconnect()
    }

    private func scheduleDisconnect(
        ifConnecting generation: UInt64? = nil
    ) -> Task<Void, Never>? {
        guard let tasks = beginDisconnect(ifConnecting: generation) else { return nil }
        defer { finishDisconnect(tasks.3) }
        tasks.0?.cancel()
        tasks.1?.cancel()
        failAllPendingActionCalls(error: KeepTalkingClientError.clientDisconnected)
        failAllPendingActionCatalogRequests(error: KeepTalkingClientError.clientDisconnected)
        failAllPendingContextSync(error: KeepTalkingClientError.clientDisconnected)
        return tasks.2
    }

    /// Awaitable variant of `disconnect()` that returns once the WebRTC
    /// transport has fully torn down. Prefer this when the caller needs to
    /// observe a fully-stopped state (e.g. tests, or a controlled shutdown).
    public func disconnectAndWait() async {
        if let teardown = scheduleDisconnect() { await teardown.value }
    }

    /// Installs a callback for HTTP-based MCP authorization flows.
    public func setMCPHTTPAuthURLHandler(_ handler: MCPHTTPAuthURLHandler?) {
        mcpHTTPAuthURLHandler = handler
        Task { [weak self] in
            await self?.mcpManager.setHTTPAuthURLHandler(handler)
        }
    }

    /// Installs a factory supplying a per-action `HTTPClientAuthorizer` so the MCP
    /// transport performs OAuth in-protocol (driven by 401/403 challenges) instead
    /// of a bespoke preflight gate. The provider is invoked with the action ID and
    /// the HTTP MCP endpoint, and returns the authorizer (or nil to skip).
    public func setMCPAuthorizerProvider(
        _ provider: (@Sendable (UUID, URL) async -> (any HTTPClientAuthorizer)?)?
    ) async {
        await mcpManager.setAuthorizerProvider(provider)
    }

    #if os(macOS)
    /// Installs a callback invoked when the agent requests creation of a new scoped action.
    ///
    /// The handler receives the request details (descriptor, reason, duration) and returns
    /// whether the request is approved and with what grant duration.
    public func setActionCreationApprovalHandler(
        _ handler: ScopeManager.ActionCreationApprovalHandler?
    ) {
        Task { [weak self] in
            await self?.scopeManager.setApprovalHandler(handler)
        }
    }
    #endif

    /// Returns the current transport statistics for diagnostics and UI.
    public func runtimeStats() -> KeepTalkingRuntimeStats {
        rtcClient.runtimeStats()
    }

    /// Asks the transport to attempt a direct P2P connection.
    public func requestP2PTrial() {
        rtcClient.requestP2PTrial()
    }

    // MARK: - Transport health

    /// Coarse health of the always-on broadcast (SFU) backbone, derived
    /// purely from the transport's own pushed state — never a probe.
    ///
    /// The carriers already self-report liveness: libjuice consent-freshness
    /// for ICE, and `HTTP2KeepAliveHandler` (PING / read-deadline) for both
    /// the SFU and P2P HTTP/2 channels. Loss flips `BroadcastChannelState`
    /// without any polling here. This enum is just a consumer-facing read of
    /// that state so callers (e.g. the app's foreground-resume path) can
    /// decide whether a re-establish is even warranted.
    ///
    /// P2P readiness is intentionally *not* reflected: a dead direct channel's
    /// recovery is SFU fallback, handled inside the transport — it never
    /// justifies tearing down the client.
    public enum TransportHealth: Sendable, Equatable {
        /// Broadcast backbone is ready. The path may still be stale-open
        /// (rare); callers that care can confirm with `probeTransport()`.
        case healthy
        /// Backbone is mid-reconnect. The state machine retries with backoff
        /// and never gives up — leave it alone; do not re-establish.
        case recovering
        /// Backbone is down (only reachable via an explicit stop). A
        /// re-establish is warranted.
        case down
    }

    /// Reads `TransportHealth` from the transport's current broadcast state.
    /// Pure read, no I/O.
    public func transportHealth() -> TransportHealth {
        switch rtcClient.broadcastState() {
            case .ready:
                return .healthy
            case .connecting, .reconnecting:
                return .recovering
            case .failed:
                return .down
        }
    }

    /// Actively confirms a `.healthy` backbone is really carrying bytes, not
    /// wedged open (e.g. the keepalive task starved across a long suspend).
    ///
    /// Sends one presence wave plus a native SFU roster request, then watches
    /// the transport's inbound counter for progress within `timeout`. Any
    /// inbound byte — a presence echo, roster reply, or peer's traffic —
    /// counts. Returns `true` if inbound
    /// advanced (live), `false` on timeout (wedged → caller should
    /// re-establish).
    ///
    /// Only worth calling when `transportHealth() == .healthy`: `.recovering`
    /// already self-heals and `.down` is unambiguous.
    public func probeTransport(timeout: Duration = .milliseconds(2500)) async -> Bool {
        let before = rtcClient.runtimeStats().received
        rtcClient.sendLivenessProbe()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if rtcClient.runtimeStats().received > before {
                return true
            }
        }
        return false
    }

    /// Tears the transport down and brings it back up **on this same client
    /// instance**. Unlike the app dropping and rebuilding a `KeepTalkingClient`,
    /// this preserves every object that captured the client — most importantly
    /// an `activeVoiceSession`, whose send closures route through
    /// `self.rtcClient`. The voice session keeps running across the bounce; its
    /// heartbeat re-announces over the freshly-started transport.
    ///
    /// `connect()` awaits the detached teardown `disconnect()` schedules, so
    /// the stop fully completes before the restart.
    public func reestablishTransport() async throws {
        debug("reestablishTransport: bouncing transport in place")
        disconnect()
        try await connect()
    }

    func debug(_ message: String) {
        rtcClient.debug(message)
    }

    /// Wipes all local persisted state — drops Fluent tables and clears every
    /// keychain entry the SDK owns (group secrets, identity private keys,
    /// login credentials). The transport must be disconnected before calling.
    public func eraseLocalState() async throws {
        try await localStore.reset()
        try await keychain.deleteAll()
    }

    // MARK: - HTTP MCP credentials

    /// Persists the keychain-only credentials (request headers + client secret)
    /// for an HTTP MCP action. Never written to the action's database payload.
    public func storeMCPCredentials(
        actionID: UUID,
        _ credentials: KeepTalkingMCPCredentials
    ) async throws {
        try await mcpCredentialStore.store(credentials, actionID: actionID)
    }

    /// Reads the stored credentials for an HTTP MCP action, or `nil` if none.
    public func loadMCPCredentials(
        actionID: UUID
    ) async throws -> KeepTalkingMCPCredentials? {
        try await mcpCredentialStore.load(actionID: actionID)
    }

    /// Updates only the OAuth client secret for an action, preserving headers.
    public func setMCPClientSecret(
        actionID: UUID,
        _ secret: String?
    ) async throws {
        try await mcpCredentialStore.setClientSecret(secret, actionID: actionID)
    }

    /// Removes any stored credentials for an HTTP MCP action.
    public func deleteMCPCredentials(actionID: UUID) async throws {
        try await mcpCredentialStore.delete(actionID: actionID)
    }
}
