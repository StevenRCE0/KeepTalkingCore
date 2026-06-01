import FluentKit
import Foundation

public enum KeepTalkingClientError: LocalizedError {
    case kvServiceNotConfigured
    case missingNode
    case missingAction
    case aiNotConfigured
    case unknownTool(String)
    case invalidToolArguments(String)
    case actionNotHostedLocally(UUID)
    case relationNotTrustedOrOwned(UUID)
    case actionCallNotAuthorized(action: UUID, caller: UUID, context: UUID)
    case actionCallTimeout(UUID)
    case actionCatalogTimeout(UUID)
    case contextSyncTimeout(UUID)
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

    public var errorDescription: String? {
        switch self {
            case .kvServiceNotConfigured:
                return "KV service is not configured."
            case .missingNode:
                return "KeepTalkingConfig.node is required for KV node registration."
            case .missingAction:
                return "Action is not found required for the operation."
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
            case .actionCallNotAuthorized(let actionID, let caller, let context):
                return "Action call is not authorized. action=\(actionID) caller=\(caller) context=\(context)"
            case .actionCallTimeout(let requestID):
                return "Timed out waiting for remote action call result: \(requestID)"
            case .actionCatalogTimeout(let requestID):
                return "Timed out waiting for remote action catalog result: \(requestID)"
            case .contextSyncTimeout(let requestID):
                return "Timed out waiting for remote context sync result: \(requestID)"
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
    /// Callback that executes semantic thread search. Injected by the app layer.
    /// Parameters: query, topK, contextIDs filter, tagIDs filter.
    public typealias SemanticSearchCallback =
        @Sendable (String, Int, [UUID], [UUID]) async throws -> [KeepTalkingSemanticSearchResult]
    /// Callback that performs a web search. Used when the connector is in chat-completions
    /// mode (e.g. OpenRouter) where web search is a client-side function call rather than
    /// a built-in Responses API tool. Parameter: query string. Returns raw result text.
    public typealias WebSearchProvider = @Sendable (String) async throws -> String

    public typealias EnvelopeHandler = @Sendable (any KeepTalkingEnvelope) -> Void
    public typealias RawMessageHandler = @Sendable (String) -> Void
    public typealias BlobAvailabilityHandler = @Sendable (UUID, String) -> Void
    public typealias PeerConnectHandler = @Sendable (UUID) -> Void
    public typealias ContextSyncHandler = @Sendable (UUID) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    public var onEnvelope: EnvelopeHandler?
    public var onRawMessage: RawMessageHandler?
    public var onBlobAvailabilityChange: BlobAvailabilityHandler?
    public var onPeerConnect: PeerConnectHandler?
    public var onContextSync: ContextSyncHandler?
    /// Notifies the app when the outbox set of pending message IDs changes
    /// (entry added, removed on successful drain, or cancelled by user).
    public var onOutboxChanged: (@Sendable () -> Void)?
    public var onThreadsChanged: (@Sendable () -> Void)?
    public var onMappingsChanged: (@Sendable () -> Void)?
    public var onAgentRunsChanged: (@Sendable ([KeepTalkingAgentRunSnapshot]) -> Void)? {
        didSet { agentRunQueue.onChanged = onAgentRunsChanged }
    }
    /// Called when an agent run finishes (normally, with error, or after cancellation).
    /// Receives the context ID and the error if the run failed, or nil on success/cancel.
    public var onAgentRunCompleted: (@Sendable (UUID, (any Error)?) -> Void)?
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
    let skillManager: SkillManager
    let primitiveActionManager: PrimitiveActionManager
    let semanticRetrievalActionManager: SemanticRetrievalActionManager
    let filesystemActionManager: FilesystemActionManager
    #if os(macOS)
    let scopeManager: ScopeManager
    #endif
    let aiConnector: (any AIConnector)?
    let blobStore: KeepTalkingBlobStore
    private var mcpHTTPAuthURLHandler: MCPHTTPAuthURLHandler?
    var actionApprovalHandler: ActionApprovalHandler?
    var primitiveActionPostResultHandler: PrimitiveActionPostResultHandler?
    let primitiveRegistry: KeepTalkingPrimitiveRegistry?
    var semanticSearchCallback: SemanticSearchCallback?
    var webSearchProvider: WebSearchProvider?
    var jsRuntime: (any KeepTalkingJSRuntime)?

    // MARK: Agent Run Queue
    let agentRunQueue = AgentRunQueue()

    // MARK: NodeState Broadcast properties
    var nodeStateBroadcastDebounceTask: Task<Void, Never>?

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

    // MARK: Action Catalog properties
    let actionCatalogQueue = DispatchQueue(
        label: "KeepTalking.client.action-catalog"
    )
    var pendingActionCatalogResults: [UUID: CheckedContinuation<KeepTalkingActionCatalogResult, Error>] = [:]

    // MARK: Context Sync properties
    let contextSyncQueue = DispatchQueue(
        label: "KeepTalking.client.context-sync"
    )
    var pendingContextSyncSummaries: [UUID: CheckedContinuation<KeepTalkingContextSyncSummaryResult, Error>] = [:]
    var pendingContextSyncMessages: [UUID: CheckedContinuation<KeepTalkingContextSyncMessagesResult, Error>] = [:]
    var pendingContextSyncSideNotes: [UUID: CheckedContinuation<KeepTalkingContextSyncSideNotesResult, Error>] = [:]

    // MARK: Trust handshake properties
    let trustQueue = DispatchQueue(
        label: "KeepTalking.client.trust"
    )
    var pendingTrustSessions: [UUID: KeepTalkingPendingTrustSession] = [:]
    var incomingTrustHandler: KeepTalkingIncomingTrustHandler?

    // MARK: Blob request/response properties
    let blobTransportQueue = KeepTalkingBlobTransportQueue()

    let blobFrameProcessor = KeepTalkingBlobFrameProcessor()

    // MARK: Teardown serialization
    // `rtcClient.stop()` synchronously closes WebRTC peer connections, which
    // joins worker threads and can block for hundreds of milliseconds. We run
    // it on a detached task so MainActor callers don't freeze the UI, and
    // gate `connect()` on any in-flight teardown so a tight disconnect→connect
    // sequence still serializes correctly.
    private let teardownLock = NSLock()
    private var pendingTeardown: Task<Void, Never>?

    private func takePendingTeardown() -> Task<Void, Never>? {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        let task = pendingTeardown
        pendingTeardown = nil
        return task
    }

    private func setPendingTeardown(_ task: Task<Void, Never>) {
        teardownLock.lock()
        pendingTeardown = task
        teardownLock.unlock()
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
    ///   - stdioTransportLauncher: Optional stdio transport launcher used for
    ///     MCP stdio actions.
    ///   - skillScriptExecutor: Optional skill script executor used for skill
    ///     script tool calls.
    ///   - primitiveActionCallback: Callback used by primitive actions.
    ///   - logon: Correlation identifier for the current client runtime.
    ///   - localStore: Local persistence backend for models and state.
    public init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        openAIAPIKey: String? = nil,
        openAIEndpoint: String? = nil,
        openAIBackend: OpenAIConnectorBackend = .openRouter,
        openAIModel: String? = nil,
        responseLanguages: [String] = [],
        aiConnector: (any AIConnector)? = nil,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        skillScriptExecutor: (any SkillScriptExecuting)? =
            DefaultSkillScriptExecutor.current,
        primitiveRegistry: KeepTalkingPrimitiveRegistry? = nil,
        logon: UUID = UUID(),
        localStore: any KeepTalkingLocalStore =
            KeepTalkingClient.makeDefaultLocalStore(),
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
        livenessState = KeepTalkingContextLivenessState(
            localNode: config.node
        )
        self.rtcClient = KeepTalkingContextTransport(
            config: config,
            livenessState: livenessState
        )
        self.mcpManager = MCPManager(
            nodeConfig: config,
            stdioTransportLauncher: stdioTransportLauncher
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
        #endif

        // All stored properties are initialized above; [weak self] is safe from here on.
        // Inject the blob bridge synchronously so blob transfer operations are available
        // immediately, using the same send(attachments:) path as ask-for-file.
        filesystemActionManager.bridgeBox.bridge = FilesystemBlobBridge(
            readBlob: { [weak self] blobID in
                guard let self else {
                    throw FilesystemActionManagerError.blobBridgeNotConfigured
                }
                let records = try await self.blobRecordsByBlobID([blobID])
                guard let record = records[blobID], record.availability == .ready else {
                    throw FilesystemActionManagerError.blobNotAvailable(blobID)
                }
                return try self.blobStore.read(
                    relativePath: record.relativePath,
                    blobID: blobID
                )
            },
            uploadFileAsContextAttachment: { [weak self] fileURL, filename, mimeType, contextID in
                guard let self else {
                    throw FilesystemActionManagerError.blobBridgeNotConfigured
                }
                let data = try Data(contentsOf: fileURL)
                let blobID = self.hexDigest(for: data)
                try await self.send(
                    "",
                    attachments: [
                        KeepTalkingLocalAttachmentInput(
                            sourceURL: fileURL,
                            filename: filename,
                            mimeType: mimeType
                        )
                    ],
                    in: contextID,
                    type: .intermediate(hint: "file-to-blob")
                )
                return blobID
            }
        )

        rtcClient.onLog = { [weak self] line in
            self?.onLog?(line)
        }
        rtcClient.contextSecretProvider = { [weak self] contextID in
            try await self?.loadGroupChatSecret(for: contextID)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            self?.onRawMessage?(raw)
        }
        rtcClient.onBlobData = { [weak self] data in
            guard let self else {
                return
            }
            Task {
                do {
                    try await self.blobFrameProcessor.process {
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
            _ = self?.activeVoiceSession?.receiveRelayedFrame(data)
        }
        rtcClient.onEnvelope = { [weak self] envelope in
            Task {
                do {
                    try await self?.handleIncomingEnvelope(envelope)
                } catch {
                    self?.onLog?(
                        "[client] failed handling envelope error=\(error.localizedDescription)"
                    )
                }
            }
        }
        rtcClient.onTrustEnvelope = { [weak self] envelope in
            Task {
                await self?.handleIncomingTrustEnvelope(envelope)
            }
        }
        rtcClient.onPeerConnect = { [weak self] nodeID in
            Task {
                await self?.handlePeerConnect(nodeID: nodeID)
            }
        }
        rtcClient.onBroadcastReady = { [weak self] in
            // Broadcast just opened — drain anything queued on the outbox
            // even before any peer is observed, since SFU forwarding can
            // deliver to peers who joined the room while we were offline.
            Task { await self?.drainOutbox() }
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

    func notifyContextDidSync(_ context: UUID) {
        onContextSync?(context)
    }

    func notifyBlobAvailabilityChange(contextID: UUID, blobID: String) {
        onBlobAvailabilityChange?(contextID, blobID)
    }

    /// Creates the default local store, preferring SQLite and falling back to memory.
    public static func makeDefaultLocalStore() -> any KeepTalkingLocalStore {
        do {
            return try KeepTalkingModelStore()
        } catch {
            return KeepTalkingInMemoryStore()
        }
    }

    /// Starts transports, persists local node state, and registers local actions.
    public func connect() async throws {
        // Ensure any in-flight teardown from a previous disconnect() completes
        // before bringing the transport back up.
        if let teardown = takePendingTeardown() {
            await teardown.value
        }

        await mcpManager.setHTTPAuthURLHandler(mcpHTTPAuthURLHandler)
        _ = try await ensure(config.contextID, for: KeepTalkingContext.self)

        try await rtcClient.start()
        try await persistMyNode()

        try await registerLocalActionsInExecutors()

        if kvService != nil {
            do {
                try await registerCurrentNodeID()
            } catch {
                debug("[kv] KV registration failed: \(error)")
            }
        }

        await broadcastLocalNodeState(reason: "connect")
        await reconcileStaleContinuations()
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
        failAllPendingActionCalls(error: KeepTalkingClientError.clientDisconnected)
        failAllPendingActionCatalogRequests(error: KeepTalkingClientError.clientDisconnected)
        failAllPendingContextSync(error: KeepTalkingClientError.clientDisconnected)
        cancelDebouncedNodeStateBroadcast()

        let rtc = rtcClient
        let previous = takePendingTeardown()
        let teardown = Task.detached(priority: .userInitiated) {
            if let previous {
                await previous.value
            }
            rtc.stop()
        }
        setPendingTeardown(teardown)
    }

    /// Awaitable variant of `disconnect()` that returns once the WebRTC
    /// transport has fully torn down. Prefer this when the caller needs to
    /// observe a fully-stopped state (e.g. tests, or a controlled shutdown).
    public func disconnectAndWait() async {
        disconnect()
        if let teardown = takePendingTeardown() {
            await teardown.value
        }
    }

    /// Installs a callback for HTTP-based MCP authorization flows.
    public func setMCPHTTPAuthURLHandler(_ handler: MCPHTTPAuthURLHandler?) {
        mcpHTTPAuthURLHandler = handler
        Task { [weak self] in
            await self?.mcpManager.setHTTPAuthURLHandler(handler)
        }
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
    /// Sends one presence wave and watches the transport's inbound counter
    /// for progress within `timeout`. Any inbound byte — a presence echo, an
    /// SFU roster reply, a peer's traffic — counts. Returns `true` if inbound
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
}
