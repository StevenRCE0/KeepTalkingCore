import FluentKit
import Foundation

public enum KeepTalkingClientError: LocalizedError {
    case kvServiceNotConfigured
    case missingNode
    case aiNotConfigured
    case unknownTool(String)
    case invalidToolArguments(String)
    case actionNotHostedLocally(UUID)
    case relationNotTrustedOrOwned(UUID)
    case actionCallNotAuthorized(action: UUID, caller: UUID, context: UUID)
    case actionCallTimeout(UUID)
    case localIdentityPrivateKeyMissing
    case remoteIdentityPublicKeyMissing(UUID)
    case remoteIdentityPublicKeyInvalid(UUID)
    case malformedEncryptedActionCall
    case malformedEncryptedNodeStatus

    public var errorDescription: String? {
        switch self {
        case .kvServiceNotConfigured:
            return "KV service is not configured."
        case .missingNode:
            return "KeepTalkingConfig.node is required for KV node registration."
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
        case .localIdentityPrivateKeyMissing:
            return "Local private identity key is missing."
        case .remoteIdentityPublicKeyMissing(let nodeID):
            return "No remote public key is known for node: \(nodeID)"
        case .remoteIdentityPublicKeyInvalid(let nodeID):
            return "Remote public key is invalid for node: \(nodeID)"
        case .malformedEncryptedActionCall:
            return "Encrypted action-call envelope payload is malformed."
        case .malformedEncryptedNodeStatus:
            return "Encrypted node-status envelope payload is malformed."
        }
    }
}

public final class KeepTalkingClient: @unchecked Sendable {
    public typealias EnvelopeHandler = @Sendable (KeepTalkingP2PEnvelope) -> Void
    public typealias RawMessageHandler = @Sendable (String) -> Void
    public typealias PeerConnectHandler = @Sendable (UUID) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    public var onEnvelope: EnvelopeHandler?
    public var onRawMessage: RawMessageHandler?
    public var onPeerConnect: PeerConnectHandler?
    public var onLog: LogHandler? {
        didSet { rtcClient.onLog = onLog }
    }

    public var aiEnabled: Bool {
        openAIConnector != nil
    }

    public let logon: UUID

    let config: KeepTalkingConfig
    let rtcClient: any KeepTalkingTransportClient
    let kvService: (any KeepTalkingKVService)?
    public let localStore: any KeepTalkingLocalStore
    let mcpManager: MCPManager
    let openAIConnector: OpenAIConnector?

    let actionCallQueue = DispatchQueue(
        label: "KeepTalking.client.action-call"
    )
    var pendingActionCallResults:
        [UUID: CheckedContinuation<KeepTalkingActionCallResult, Error>] = [:]
    var nodeStateBroadcastDebounceTask: Task<Void, Never>?

    public init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        logon: UUID = UUID(),
        localStore: any KeepTalkingLocalStore =
            KeepTalkingClient.makeDefaultLocalStore()
    ) {
        self.config = config
        self.kvService = kvService
        self.logon = logon
        self.localStore = localStore
        self.rtcClient = KeepTalkingHybridRTCClient(
            config: config,
            localStore: localStore
        )
        self.mcpManager = MCPManager(nodeConfig: config)

        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let apiKey, !apiKey.isEmpty {
            self.openAIConnector = OpenAIConnector(apiKey: apiKey)
        } else {
            self.openAIConnector = nil
        }

        rtcClient.onLog = { [weak self] line in
            self?.onLog?(line)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            self?.onRawMessage?(raw)
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

    public static func makeDefaultLocalStore() -> any KeepTalkingLocalStore {
        do {
            return try KeepTalkingModelStore()
        } catch {
            return KeepTalkingInMemoryStore()
        }
    }

    public func connect() async throws {
        let context = try await ensure(config.contextID, for: KeepTalkingContext.self)

        try await rtcClient.start()
        try await persistMyNode()

        do {
            try await registerLocalActionsInMCP()
        } catch {
            debug(
                "[client] failed to register local MCP actions: \(error.localizedDescription)"
            )
        }

        if kvService != nil {
            do {
                try await registerCurrentNodeID()
            } catch {
                debug("[kv] KV registration failed: \(error)")
            }
        }

        await broadcastLocalNodeState(reason: "connect")
    }

    public func disconnect() {
        failAllPendingActionCalls(error: SignalError.closed)
        cancelDebouncedNodeStateBroadcast()
        rtcClient.stop()
    }

    public func runtimeStats() -> KeepTalkingRuntimeStats {
        rtcClient.runtimeStats()
    }

    public func requestP2PTrial() {
        rtcClient.requestP2PTrial()
    }

    func debug(_ message: String) {
        rtcClient.debug(message)
    }
}
