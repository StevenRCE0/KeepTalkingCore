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
                return
                    "No AI model is configured for this conversation. Choose a provider and model for the main and ACT agents."
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
@dynamicMemberLookup
public final class KeepTalkingClient: @unchecked Sendable {
    public static let availablePrimitiveActions =
        KeepTalkingPrimitiveBundle.availablePrimitiveActions
    public typealias MCPHTTPAuthURLHandler =
        @Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult
    /// Resolves an ACP agent's `auth_required` challenge by picking one of the
    /// methods it advertised. The ACP counterpart of `MCPHTTPAuthURLHandler`.
    public typealias ACPAuthHandler =
        @Sendable (UUID, [KeepTalkingACPAuthMethod]) async -> KeepTalkingACPAuthResult
    public typealias ActionApprovalHandler =
        @Sendable (KeepTalkingActionCallRequest, KeepTalkingAction, KeepTalkingContext) async -> Bool
    public typealias PrimitiveActionPostResultHandler =
        @Sendable (KeepTalkingPrimitiveBundle, KeepTalkingActionCall) -> Void
    /// Optional app-provided semantic ranking signal. Canonical scope
    /// enforcement and lexical retrieval remain SDK-owned.
    public typealias SemanticSearchCallback =
        @Sendable (String, Int) async throws -> [KeepTalkingSemanticSearchResult]
    /// App-side fulfilment of the built-in `actionCreation` capability: present
    /// the request (intention, context, caller) to the user for confirmation and
    /// curation, returning the created action's ID — or nil when the user
    /// declines or dismisses the flow.
    public typealias ActionCreationHandler =
        @Sendable (_ intention: String, _ contextID: UUID?, _ callerNodeID: UUID) async -> UUID?
    /// Callback that performs a web search. Used when the connector is in chat-completions
    /// mode (e.g. OpenRouter) where web search is a client-side function call rather than
    /// a built-in Responses API tool. Parameter: query string. Returns raw result text.
    public typealias WebSearchProvider = @Sendable (String) async throws -> String

    public typealias LogHandler = @Sendable (String) -> Void

    // MARK: - Signals
    //
    // The client's whole push surface lives under `Signals/`: the
    // primitives, the `KeepTalkingClientSignals` box, its payload types, and
    // the `KeepTalkingClient+Signals.swift` forwarders that keep
    // `client.envelopes`, `client.lifecycle`, … reading alike no matter which
    // object owns the underlying primitive.
    public let signals: KeepTalkingClientSignals

    /// Producer-side sink for `log`, handed to the transport and the managers
    /// at init so no early line is lost.
    let onLog: LogHandler?
    /// Display name of *this* node's voice agent — the configured wake keyword,
    /// shown beside the node name when rendering the agent's `.realtime`
    /// transcript lines. The app sets it from its voice settings; nil (or a
    /// peer-authored line, whose wake keyword we don't know) falls back to "ai".
    public var localVoiceAgentName: String?

    /// Whether the host installed an agent configuration provider. A run
    /// can still fail with `aiNotConfigured` when the provider has nothing
    /// for its context.
    public var aiEnabled: Bool {
        agentConfigurationProvider != nil
    }

    public let logon: UUID
    /// Tracks which contexts have an ongoing joinable voice call, fed
    /// by inbound `voiceCallStarted` / `voiceCallEnded` envelopes. The
    /// app reads from this to glow the in-context Voice button when
    /// another participant has started a call but local self hasn't
    /// joined yet.
    public let voiceCallPresence: KeepTalkingVoiceCallPresenceRegistry
    /// In-memory voice-call bookkeeping, keyed by session id. Replaces the former
    /// `kt_voice_calls` table — voice calls are never persisted; only their
    /// transcript lines and the sealed `.voiceCallSeal` entry are durable.
    let voiceCalls = KeepTalkingVoiceCallRegistry()
    var activeVoiceSession: KeepTalkingVoiceSession?
    let config: KeepTalkingConfig
    let rtcClient: any KeepTalkingTransportClient
    let kvService: (any KeepTalkingKVService)?
    public let localStore: any KeepTalkingLocalStore
    public let keychain: any KeepTalkingKeychainStore
    let livenessState: KeepTalkingContextLivenessState
    let mcpManager: MCPManager
    let mcpCredentialStore: KeepTalkingMCPCredentialStore
    /// Keychain seam for ACP agent secrets. Cross-platform (unlike `acpManager`)
    /// so an action authored on iOS still keeps its environment out of the DB.
    let acpCredentialStore: KeepTalkingACPCredentialStore
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
    let blobStore: KeepTalkingBlobStore
    /// Per-thread isolated execution workspaces (scratch/output dirs used as the
    /// cwd for skill / provider-side ACT runs); reaped on thread archive/delete.
    let threadWorkspaces: KeepTalkingThreadWorkspaceManager
    var mcpHTTPAuthURLHandler: MCPHTTPAuthURLHandler?
    var acpAuthHandler: ACPAuthHandler?
    var actionApprovalHandler: ActionApprovalHandler?
    var actionCreationHandler: ActionCreationHandler?
    var primitiveActionPostResultHandler: PrimitiveActionPostResultHandler?
    let primitiveRegistry: KeepTalkingPrimitiveRegistry?
    var semanticSearchCallback: SemanticSearchCallback?
    var webSearchProvider: WebSearchProvider?
    /// Builds link previews on the send path; nil sends messages without them.
    var linkPreviewFetcher: (any KeepTalkingLinkPreviewFetching)?
    /// Supplies the agent configuration for work the node runs without one
    /// handed in (see `KeepTalkingAgentConfiguration`).
    var agentConfigurationProvider: AgentConfigurationProvider?
    var jsRuntime: (any KeepTalkingJSRuntime)?
    /// Background work `init` started against the store (the orphan-workspace
    /// reap). A host that shuts the store down under a live client awaits it
    /// first via `awaitStartupWork()`; the store cannot serve a query after
    /// shutdown.
    private var startupWork: Task<Void, Never>?

    // MARK: Agent coordination
    let agentCoordinator: AgentCoordinator
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
    let syncSideNotePages = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncSideNotesPageResult>()
    let syncMessageDeletionPages = KeepTalkingSyncResponseRegistry<KeepTalkingContextSyncMessageDeletionsPageResult>()
    let contextSyncSingleFlight = KeepTalkingContextSyncSingleFlight()

    /// Serialises every rewrite of a context's thread rows — re-threading from
    /// turning points, chitter-chatter consumption, the boundary shrink a
    /// deletion makes — so two syncs completing at once, or a sync and a local
    /// mark, never both place the same thread and write it twice.
    let threadingGate = KeepTalkingSerialGate()

    /// Serialises tombstone merges per context. The set is read, unioned and
    /// written back, so a push and a summary merging at once would otherwise
    /// each drop the other's tombstones.
    let messageDeletionGate = KeepTalkingSerialGate()

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

    /// The connection lifecycle: connect/disconnect state machine, transport
    /// binding, and the `lifecycle` / `presence` / `transportStats` signals.
    /// Resolved on the init thread so its first touch can't race.
    lazy var connection = KeepTalkingClientConnection(client: self)

    /// Inbound attachment DTOs whose parent message hasn't been persisted yet.
    /// Message and attachment arrive as *separate* envelopes, each handled in
    /// its own Task (see `rtcClient.onEnvelope`), so an attachment can land
    /// before its message. Rather than drop it (which left live-received
    /// attachments missing until a later full resync repopulated them via
    /// `saveContext`), buffer it here keyed by `parentMessageID` and re-drive
    /// when the parent message is saved. Guarded by `orphanAttachmentLock`.
    let orphanAttachmentLock = NSLock()
    var orphanAttachmentsByParentMessageID: [UUID: [KeepTalkingContextAttachmentDTO]] = [:]

    /// Creates a client with its transport and storage. AI runs take their
    /// models per run — see `KeepTalkingAgentConfiguration`.
    ///
    /// - Parameters:
    ///   - config: Session configuration for the local node.
    ///   - kvService: Optional KV backend used for node discovery and metadata.
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
    public convenience init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
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
        self.init(
            config: config,
            kvService: kvService,
            stdioTransportLauncher: stdioTransportLauncher,
            skillScriptExecutor: skillScriptExecutor,
            primitiveRegistry: primitiveRegistry,
            logon: logon,
            localStore: localStore,
            keychain: keychain,
            transport: nil
        )
    }

    /// Designated initializer with the transport seam: `nil` builds the
    /// production `KeepTalkingContextTransport`; tests inject a fake.
    init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        skillScriptExecutor: (any SkillScriptExecuting)? =
            DefaultSkillScriptExecutor.current,
        primitiveRegistry: KeepTalkingPrimitiveRegistry? = nil,
        logon: UUID = UUID(),
        // No default: constructing a store is now async, and a default argument
        // cannot await. Callers build the store first and inject it.
        localStore: any KeepTalkingLocalStore,
        keychain: any KeepTalkingKeychainStore = KeepTalkingInMemoryKeychainStore(),
        transport: (any KeepTalkingTransportClient)?
    ) {
        self.config = config
        self.kvService = kvService
        self.localStore = localStore
        self.keychain = keychain
        self.logon = logon
        self.blobStore = KeepTalkingBlobStore.makeDefault(for: localStore)
        self.threadWorkspaces = KeepTalkingThreadWorkspaceManager.makeDefault(for: localStore)
        livenessState = KeepTalkingContextLivenessState(
            localNode: config.node
        )
        let rtcClient =
            transport
            ?? KeepTalkingContextTransport(
                config: config,
                livenessState: livenessState
            )
        self.rtcClient = rtcClient
        // The box needs the transport's first stats sample, so it is built
        // right after the transport and before anything that logs.
        let signals = KeepTalkingClientSignals(initialTransportStats: rtcClient.runtimeStats())
        self.signals = signals
        self.onLog = { [log = signals.log] in log.send($0) }
        self.agentCoordinator = AgentCoordinator(runs: signals.agentRuns)
        self.voiceCallPresence = KeepTalkingVoiceCallPresenceRegistry(
            changes: signals.voiceCallPresenceChanges
        )
        let mcpCredentialStore = KeepTalkingMCPCredentialStore(keychain: keychain)
        self.mcpCredentialStore = mcpCredentialStore
        let acpCredentialStore = KeepTalkingACPCredentialStore(keychain: keychain)
        self.acpCredentialStore = acpCredentialStore
        self.mcpManager = MCPManager(
            nodeConfig: config,
            stdioTransportLauncher: stdioTransportLauncher,
            credentialStore: mcpCredentialStore
        )
        #if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
        // Start capturing the login shell's environment (PATH from Homebrew,
        // nvm, cargo, …) now, off this thread, so the first stdio MCP server,
        // ACP agent or skill spawn doesn't wait for it. Cached per process.
        KeepTalkingLoginShellEnvironment.prewarm()
        #endif

        self.skillManager = SkillManager(
            nodeConfig: config,
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
            stdioTransportLauncher: stdioTransportLauncher,
            credentialStore: acpCredentialStore
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
        // Once per process: the sweep deletes shared roots, so a later client
        // doing it again would delete staged bytes the existing clients own.
        KeepTalkingClient.pruneStaleOneTimeBlobTempDirsOnce()
        // Reap execution workspaces whose thread was archived/deleted while away.
        startupWork = Task { [weak self] in await self?.reapOrphanThreadWorkspaces() }

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

        rtcClient.onLog = onLog
        Task { [weak self] in
            guard let self else { return }
            await self.skillManager.setLogHandler(self.onLog)
            await self.mcpManager.setLogHandler(self.onLog)
        }

        // Resolve the lazy connection on the init thread for the same reason
        // as the delegation coordinator, then hand it the transport callbacks.
        _ = connection
        connection.bindTransport()
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

    public func setActionCreationHandler(
        _ handler: ActionCreationHandler?
    ) {
        actionCreationHandler = handler
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

    /// Installs the host's answer to "which models run this?" for work the
    /// node starts on its own: delegated actions and tasks, plugin ACT turns,
    /// planner ACT agents, and `runAI` calls without a configuration. Called
    /// at the moment the work runs, so a model switch applies to the next
    /// piece of work with no reconnect.
    public func setAgentConfigurationProvider(_ provider: AgentConfigurationProvider?) {
        agentConfigurationProvider = provider
    }

    /// Installs (or removes) what fetches link previews for messages this node
    /// sends — people's and its agents' alike. Receivers never fetch: the
    /// preview travels with the message.
    public func setLinkPreviewFetcher(_ fetcher: (any KeepTalkingLinkPreviewFetching)?) {
        linkPreviewFetcher = fetcher
    }

    /// Installs (or removes) the JavaScript runtime that backs the
    /// `kt_evaluate_js` meta tool. When `nil`, the tool returns a
    /// "runtime not configured" error to the agent on call.
    public func setJSRuntime(_ runtime: (any KeepTalkingJSRuntime)?) {
        jsRuntime = runtime
    }

    func notifyContextSync(_ event: KeepTalkingContextSyncEvent) async {
        signals.contextSyncEvents.send(event)
    }

    func notifyBlobAvailabilityChange(contextID: UUID, blobID: String) {
        signals.blobAvailabilityChanges.send(.init(contextID: contextID, blobID: blobID))
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

    /// Starts transports and persists local node state. `lifecycle` reports
    /// every step; see `KeepTalkingClientConnection` for the sequence.
    ///
    /// Registering local action executors is intentionally NOT part of connect:
    /// a failing executor (e.g. an HTTP MCP server that needs re-auth) must never
    /// block bringing the transport up or pop a blocking auth prompt as a side
    /// effect of connecting. Callers that want executors live should invoke
    /// `registerLocalActionsInExecutors()` explicitly (the App and CLI do, off
    /// the connection path); the daemon opts out.
    public func connect() async throws {
        try await connection.connect()
    }

    /// Stops transports and fails any pending remote requests. Returns before
    /// the WebRTC teardown completes (it joins worker threads, so it runs on a
    /// detached task); `lifecycle` publishes `.idle` once it has, and a
    /// subsequent `connect()` awaits it. Silent on an already-idle client.
    public func disconnect() {
        connection.disconnect()
    }

    /// Awaitable variant of `disconnect()` that returns once the transport
    /// has fully torn down (`signals.lifecycle.current.phase == .idle`).
    public func disconnectAndWait() async {
        await connection.disconnectAndWait()
    }

    /// Installs a callback for HTTP-based MCP authorization flows.
    public func setMCPHTTPAuthURLHandler(_ handler: MCPHTTPAuthURLHandler?) {
        mcpHTTPAuthURLHandler = handler
        Task { [weak self] in
            await self?.mcpManager.setHTTPAuthURLHandler(handler)
        }
    }

    /// Installs a callback that resolves ACP `auth_required` challenges by
    /// choosing one of the agent's advertised auth methods.
    ///
    /// Triggered in-band: the agent rejects `session/new` with -32000, this
    /// handler picks a method, `authenticate` runs and `session/new` is retried —
    /// the same shape as MCP driving OAuth off a 401/403. The choice is
    /// remembered in the keychain, so the owner is asked once, not once per call.
    public func setACPAuthHandler(_ handler: ACPAuthHandler?) {
        acpAuthHandler = handler
        #if os(macOS)
        Task { [weak self] in
            await self?.acpManager.setAuthHandler(handler)
        }
        #endif
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

    /// Reads `TransportHealth` from the transport's current broadcast state.
    /// Pure read, no I/O. `signals.lifecycle.current.transport` is the last *reported*
    /// state; this is the live one.
    public func transportHealth() -> TransportHealth {
        connection.transportHealth()
    }

    /// Actively confirms a `.healthy` backbone is really carrying bytes, not
    /// wedged open (e.g. the keepalive task starved across a long suspend).
    /// Returns `true` if inbound traffic advanced within `timeout`, `false`
    /// on timeout (wedged → caller should re-establish). Only worth calling
    /// when `transportHealth() == .healthy`.
    public func probeTransport(timeout: Duration = .milliseconds(2500)) async -> Bool {
        await connection.probeTransport(timeout: timeout)
    }

    /// Tears the transport down and brings it back up **on this same client
    /// instance**, preserving every object that captured the client — most
    /// importantly an `activeVoiceSession`. `lifecycle` reads
    /// `disconnecting → connecting → connected` with no `idle` in between.
    public func reestablishTransport() async throws {
        try await connection.reestablishTransport()
    }

    func isConnectionActive(_ generation: UInt64) -> Bool {
        connection.isConnectionActive(generation)
    }

    func isConnectionLifecycleActive(_ generation: UInt64) -> Bool {
        connection.isConnectionLifecycleActive(generation)
    }

    func debug(_ message: String) {
        rtcClient.debug(message)
    }

    /// Waits for the background work `init` started against the store. Call
    /// it before shutting a store down under a live client (tests do); the
    /// app never does, it drops the client with the store.
    public func awaitStartupWork() async {
        await startupWork?.value
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

    #if os(macOS)
    /// Runs the ACP `initialize` handshake against a bundle's command without
    /// saving anything, so the add/edit form can verify the agent when the owner
    /// clicks Done. Throws with the agent's stderr when the command is wrong or
    /// is not an ACP agent; otherwise reports how the agent authenticates and
    /// what a session lets you configure (model, effort, …).
    public func preflightACPAgent(
        bundle: KeepTalkingACPBundle
    ) async throws -> KeepTalkingACPAgentProbe {
        try await acpManager.preflightInitialize(bundle: bundle)
    }
    #endif

    // MARK: - ACP agent credentials

    /// Persists the keychain-only credentials (secret environment + the auth
    /// method last used) for an ACP action. Never written to the action's
    /// database payload, and never synced to peers.
    public func storeACPCredentials(
        actionID: UUID,
        _ credentials: KeepTalkingACPCredentials
    ) async throws {
        try await acpCredentialStore.store(credentials, actionID: actionID)
    }

    /// Reads the stored credentials for an ACP action, or `nil` if none.
    public func loadACPCredentials(
        actionID: UUID
    ) async throws -> KeepTalkingACPCredentials? {
        try await acpCredentialStore.load(actionID: actionID)
    }

    /// Forgets the remembered auth method so the next call re-prompts, leaving
    /// the stored environment intact. The ACP equivalent of signing out.
    public func clearACPAuthMethod(actionID: UUID) async throws {
        try await acpCredentialStore.setMethodID(nil, actionID: actionID)
    }

    /// Removes any stored credentials for an ACP action.
    public func deleteACPCredentials(actionID: UUID) async throws {
        try await acpCredentialStore.delete(actionID: actionID)
    }
}
