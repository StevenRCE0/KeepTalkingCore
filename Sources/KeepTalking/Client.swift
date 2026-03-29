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
    public var onLog: LogHandler? {
        didSet {
            rtcClient.onLog = onLog
            Task { [weak self] in
                guard let self else { return }
                await self.mcpManager.setLogHandler(self.onLog)
            }
        }
    }

    public var aiEnabled: Bool {
        openAIConnector != nil
    }

    public let logon: UUID
    let config: KeepTalkingConfig
    let rtcClient: any KeepTalkingTransportClient
    let kvService: (any KeepTalkingKVService)?
    public let localStore: any KeepTalkingLocalStore
    let livenessState: KeepTalkingContextLivenessState
    let mcpManager: MCPManager
    let skillManager: SkillManager
    let primitiveActionManager: PrimitiveActionManager
    let openAIConnector: OpenAIConnector?
    let blobStore: KeepTalkingBlobStore
    private var mcpHTTPAuthURLHandler: MCPHTTPAuthURLHandler?
    var actionApprovalHandler: ActionApprovalHandler?
    var primitiveActionPostResultHandler: PrimitiveActionPostResultHandler?

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

    // MARK: Blob request/response properties
    let blobTransportQueue = KeepTalkingBlobTransportQueue()

    let blobFrameProcessor = KeepTalkingBlobFrameProcessor()

    /// Creates a client with its transport, storage, and optional AI integrations.
    ///
    /// - Parameters:
    ///   - config: Session configuration for the local node.
    ///   - kvService: Optional KV backend used for node discovery and metadata.
    ///   - openAIAPIKey: Explicit OpenAI API key override.
    ///   - openAIEndpoint: Optional OpenAI-compatible endpoint override.
    ///   - openAIAPIMode: Which OpenAI API to use (`.responses` or `.chatCompletions`).
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
        openAIAPIMode: OpenAIAPIMode = .responses,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        skillScriptExecutor: (any SkillScriptExecuting)? =
            DefaultSkillScriptExecutor.current,
        primitiveActionCallback: KeepTalkingPrimitiveActionCallback? = nil,
        logon: UUID = UUID(),
        localStore: any KeepTalkingLocalStore =
            KeepTalkingClient.makeDefaultLocalStore()
    ) {
        self.config = config
        self.kvService = kvService
        self.localStore = localStore
        self.logon = logon
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
            self.openAIConnector =
                try? OpenAIConnector(apiKey: apiKey, endpoint: endpoint, apiMode: openAIAPIMode)
        } else {
            self.openAIConnector = nil
        }
        self.skillManager = SkillManager(
            nodeConfig: config,
            openAIConnector: self.openAIConnector,
            scriptExecutor: skillScriptExecutor
        )
        self.primitiveActionManager = PrimitiveActionManager(
            callback: primitiveActionCallback
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
        rtcClient.onPeerConnect = { [weak self] nodeID in
            Task {
                await self?.handlePeerConnect(nodeID: nodeID)
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
    }

    /// Stops transports and fails any pending remote requests.
    public func disconnect() {
        failAllPendingActionCalls(error: SignalError.closed)
        failAllPendingActionCatalogRequests(error: SignalError.closed)
        failAllPendingContextSync(error: SignalError.closed)
        cancelDebouncedNodeStateBroadcast()
        rtcClient.stop()
    }

    /// Installs a callback for HTTP-based MCP authorization flows.
    public func setMCPHTTPAuthURLHandler(_ handler: MCPHTTPAuthURLHandler?) {
        mcpHTTPAuthURLHandler = handler
        Task { [weak self] in
            await self?.mcpManager.setHTTPAuthURLHandler(handler)
        }
    }

    /// Returns the current transport statistics for diagnostics and UI.
    public func runtimeStats() -> KeepTalkingRuntimeStats {
        rtcClient.runtimeStats()
    }

    /// Asks the transport to attempt a direct P2P connection.
    public func requestP2PTrial() {
        rtcClient.requestP2PTrial()
    }

    func debug(_ message: String) {
        rtcClient.debug(message)
    }
}
