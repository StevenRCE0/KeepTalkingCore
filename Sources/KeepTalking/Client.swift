import Foundation
import FluentKit

public enum KeepTalkingClientError: LocalizedError {
    case kvServiceNotConfigured
    case missingNode

    public var errorDescription: String? {
        switch self {
        case .kvServiceNotConfigured:
            return "KV service is not configured."
        case .missingNode:
            return
                "KeepTalkingConfig.node is required for KV node registration."
        }
    }
}

public final class KeepTalkingClient: @unchecked Sendable {
    public typealias MessageHandler =
        @Sendable (KeepTalkingContextMessage) -> Void
    public typealias EnvelopeHandler =
        @Sendable (KeepTalkingP2PEnvelope) -> Void
    public typealias RawMessageHandler = @Sendable (String) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    public var onMessage: MessageHandler?
    public var onEnvelope: EnvelopeHandler?
    public var onRawMessage: RawMessageHandler?
    public var onLog: LogHandler? {
        didSet { rtcClient.onLog = onLog }
    }

    private let config: KeepTalkingConfig
    private let rtcClient: any KeepTalkingTransportClient
    private let kvService: (any KeepTalkingKVService)?
    private let localStore: any KeepTalkingLocalStore

    public init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        localStore: any KeepTalkingLocalStore =
            KeepTalkingClient.makeDefaultLocalStore()
    ) {
        self.config = config
        self.kvService = kvService
        self.localStore = localStore
        self.rtcClient = KeepTalkingHybridRTCClient(
            config: config,
            localStore: localStore
        )

        rtcClient.onLog = { [weak self] line in
            self?.onLog?(line)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            self?.onRawMessage?(raw)
        }
        rtcClient.onMessage = { [weak self] message in
            Task {
                try await self?.handleIncomingMessage(message)
            }
        }
        rtcClient.onEnvelope = { [weak self] envelope in
            Task {
                try await self?.handleIncomingEnvelope(envelope)
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
        try await rtcClient.start()
        try await persistMyNode()
        if kvService != nil {
            try await registerCurrentNodeID()
        }
    }

    public func disconnect() {
        rtcClient.stop()
    }

    public func send(_ text: String, in context: KeepTalkingContext, sender: KeepTalkingContextMessage.Sender? = nil)
        async throws
    {
        let node = try await getCurrentNodeInstance()
        try await context.save(on: localStore.database)

        let message = KeepTalkingContextMessage(
            context: context,
            sender: try sender ?? .node(node: node.requireID()),
            content: text
        )
        context.updatedAt = message.timestamp
        _ = try await context.$messages.get(on: localStore.database)

        try await message.save(on: localStore.database)
        try await context.save(on: localStore.database)

        try rtcClient.sendEnvelope(.message(message))
    }

    public func announceCurrentNode() async throws {
        let node = try await getCurrentNodeInstance()
        try blocking {
            try await node.save(on: self.localStore.database)
        }
        try rtcClient.sendEnvelope(.node(node))
    }

    public func sendConversationContext(
        _ context: KeepTalkingConversationContext
    ) async throws {
        try await saveContext(context)
        try rtcClient.sendEnvelope(.context(context))
    }

    public func registerCurrentNodeID() async throws {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        try await kvService.storeNodeID(config.node)
    }

    public func fetchNodeIDs(for userID: String? = nil) async throws -> [UUID] {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        return try await kvService.loadNodeIDs()
    }

    public func runtimeStats() -> KeepTalkingRuntimeStats {
        rtcClient.runtimeStats()
    }

    public func requestP2PTrial() {
        rtcClient.requestP2PTrial()
    }

    public func trust(node targetNodeID: UUID) async throws {
        guard targetNodeID != config.node else { return }

        let localNode = try await getCurrentNodeInstance()
        let localNodeID = try localNode.requireID()

        let remoteNode: KeepTalkingNode
        if let existing = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, targetNodeID)
            .first()
        {
            remoteNode = existing
        } else {
            remoteNode = KeepTalkingNode(id: targetNodeID)
            try await remoteNode.save(on: localStore.database)
        }

        if let relation = try await KeepTalkingNodeRelation
            .query(on: localStore.database)
            .filter(\.$from.$id, .equal, localNodeID)
            .filter(\.$to.$id, .equal, targetNodeID)
            .first()
        {
            relation.relationship = .trusted
            try await relation.save(on: localStore.database)
            return
        }

        let relation = try KeepTalkingNodeRelation(
            from: localNode,
            to: remoteNode,
            relationship: .trusted
        )
        try await relation.save(on: localStore.database)
    }

    private func getCurrentNodeInstance() async throws -> KeepTalkingNode {
        if let node = try await KeepTalkingNode.query(on: localStore.database)
            .filter(\.$id, .equal, config.node)
            .first()
        {
            return node
        }

        let node = KeepTalkingNode(id: config.node)
        try await node.save(on: localStore.database)
        return node
    }

    private func persistMyNode(_ explicitNode: KeepTalkingNode? = nil)
        async throws
    {
        let node: KeepTalkingNode
        if let explicitNode {
            node = explicitNode
        } else {
            node = try await getCurrentNodeInstance()
        }

        try await node.save(on: localStore.database)
    }

    private func mergeContext(_ context: KeepTalkingContext) {
        Task {
            try? await self.saveContext(context)
        }
    }

    private func handleIncomingMessage(_ message: KeepTalkingContextMessage)
        async throws
    {
        Task {
            try? await message.save(on: localStore.database)
        }

        let node = try await getCurrentNodeInstance()

        if case .node(let nodeID) = message.sender, nodeID != config.node {
            let senderNode: KeepTalkingNode
            if let existingSenderNode = try await KeepTalkingNode
                .query(on: localStore.database)
                .filter(\.$id, .equal, nodeID)
                .first()
            {
                senderNode = existingSenderNode
            } else {
                senderNode = KeepTalkingNode(id: nodeID)
                try await senderNode.save(on: localStore.database)
            }

            let relationExists = try await KeepTalkingNodeRelation
                .query(on: localStore.database)
                .filter(\.$from.$id, .equal, try node.requireID())
                .filter(\.$to.$id, .equal, nodeID)
                .count() > 0

            if !relationExists {
                let relationship = try KeepTalkingNodeRelation(
                    from: node,
                    to: senderNode,
                    relationship: .pending  // TODO: Update conditionally
                )
                try await relationship.save(on: localStore.database)
            }
        }

        onMessage?(message)
    }

    private func handleIncomingEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
        case .message(let message):
            try await handleIncomingMessage(message)
        case .node(let node):
            try await node.save(on: localStore.database)
        case .context(let context):
            mergeContext(context)
            if let latestMessage = context.messages.max(by: {
                $0.timestamp < $1.timestamp
            }) {
                onMessage?(latestMessage)
            }
        case .p2pSignal, .p2pPresence:
            break  // Never reached since it gets intercepted
        }

        onEnvelope?(envelope)
    }

    private func saveContext(_ context: KeepTalkingContext) async throws {
        try await context.save(on: localStore.database)
        for message in context.messages {
            message.context = context
            try await message.save(on: localStore.database)
        }
    }

    private func blocking<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result else {
            fatalError("Blocking operation did not produce a result.")
        }
        return try result.get()
    }
}
