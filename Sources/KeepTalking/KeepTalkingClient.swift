import Foundation

public enum KeepTalkingClientError: LocalizedError {
    case kvServiceNotConfigured
    case localStoreNotConfigured
    case missingUserID

    public var errorDescription: String? {
        switch self {
        case .kvServiceNotConfigured:
            return "KV service is not configured."
        case .localStoreNotConfigured:
            return "Local store is not configured."
        case .missingUserID:
            return "KeepTalkingConfig.userID is required for KV node registration."
        }
    }
}

public final class KeepTalkingClient: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (KeepTalkingMessage) -> Void
    public typealias EnvelopeHandler = @Sendable (KeepTalkingP2PEnvelope) -> Void
    public typealias RawMessageHandler = @Sendable (String) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    public var onMessage: MessageHandler?
    public var onEnvelope: EnvelopeHandler?
    public var onRawMessage: RawMessageHandler?
    public var onLog: LogHandler? {
        didSet { rtcClient.onLog = onLog }
    }

    private let config: KeepTalkingConfig
    private let rtcClient: KeepTalkingRTCClient
    private let kvService: (any KeepTalkingKVService)?
    private let localStore: (any KeepTalkingLocalStore)?

    public init(
        config: KeepTalkingConfig,
        kvService: (any KeepTalkingKVService)? = nil,
        localStore: (any KeepTalkingLocalStore)? = KeepTalkingFileStore()
    ) {
        self.config = config
        self.kvService = kvService
        self.localStore = localStore
        rtcClient = KeepTalkingRTCClient(config: config)

        rtcClient.onLog = { [weak self] line in
            self?.onLog?(line)
        }
        rtcClient.onRawMessage = { [weak self] raw in
            self?.onRawMessage?(raw)
        }
        rtcClient.onMessage = { [weak self] message in
            self?.handleIncomingMessage(message)
        }
        rtcClient.onEnvelope = { [weak self] envelope in
            self?.handleIncomingEnvelope(envelope)
        }
    }

    public func connect() async throws {
        try await rtcClient.start()
        persistMyNode()
        if kvService != nil, config.userID != nil {
            try await registerCurrentNodeID()
        }
    }

    public func disconnect() {
        rtcClient.stop()
    }

    public func send(text: String, to peerID: String? = nil) throws {
        try rtcClient.sendText(text, to: peerID)
        persistConversationMessage(
            KeepTalkingConversationMessage(from: config.participantID, to: peerID, text: text),
            conversationID: conversationID(forPeer: peerID)
        )
    }

    public func announceCurrentNode(to peerID: String? = nil) throws {
        let node = KeepTalkingNode(nodeID: config.participantID, userID: config.userID)
        try rtcClient.sendEnvelope(.node(from: config.participantID, to: peerID, node: node))
        persistMyNode(node)
    }

    public func sendFriendNode(_ friendNode: KeepTalkingFriendNode, to peerID: String? = nil) throws {
        try rtcClient.sendEnvelope(.friendNode(from: config.participantID, to: peerID, friendNode: friendNode))
        persistFriendNode(friendNode)
    }

    public func sendConversationContext(_ context: KeepTalkingConversationContext, to peerID: String? = nil) throws {
        try rtcClient.sendEnvelope(.conversation(from: config.participantID, to: peerID, conversation: context))
        mergeConversation(context)
    }

    public func syncLocalState(to peerID: String? = nil) throws {
        guard let localStore else {
            throw KeepTalkingClientError.localStoreNotConfigured
        }
        let snapshot = try localStore.loadSnapshot()
        try rtcClient.sendEnvelope(.state(from: config.participantID, to: peerID, state: snapshot))
    }

    public func requestPeerState(from peerID: String? = nil) throws {
        try rtcClient.sendEnvelope(.stateRequest(from: config.participantID, to: peerID))
    }

    public func registerCurrentNodeID() async throws {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        guard let userID = config.userID else {
            throw KeepTalkingClientError.missingUserID
        }
        try await kvService.storeNodeID(config.participantID, for: userID)
    }

    public func fetchNodeIDs(for userID: String? = nil) async throws -> [String] {
        guard let kvService else {
            throw KeepTalkingClientError.kvServiceNotConfigured
        }
        let resolvedUserID: String
        if let userID {
            resolvedUserID = userID
        } else if let configUserID = config.userID {
            resolvedUserID = configUserID
        } else {
            throw KeepTalkingClientError.missingUserID
        }
        return try await kvService.loadNodeIDs(for: resolvedUserID)
    }

    public func loadLocalSnapshot() throws -> KeepTalkingLocalSnapshot {
        guard let localStore else {
            throw KeepTalkingClientError.localStoreNotConfigured
        }
        return try localStore.loadSnapshot()
    }

    public func saveLocalSnapshot(_ snapshot: KeepTalkingLocalSnapshot) throws {
        guard let localStore else {
            throw KeepTalkingClientError.localStoreNotConfigured
        }
        try localStore.saveSnapshot(snapshot)
    }

    public func runtimeStats() -> KeepTalkingRuntimeStats {
        rtcClient.runtimeStats()
    }

    private func handleIncomingMessage(_ message: KeepTalkingMessage) {
        persistConversationMessage(
            KeepTalkingConversationMessage(from: message.from, to: message.to, text: message.text),
            conversationID: conversationID(forPeer: message.from)
        )
        persistFriendNode(
            KeepTalkingFriendNode(friendID: message.from, nodeID: message.from)
        )
        onMessage?(message)
    }

    private func handleIncomingEnvelope(_ envelope: KeepTalkingP2PEnvelope) {
        switch envelope.resolvedKind {
        case .node:
            if let node = envelope.node {
                let friendID = node.userID ?? envelope.from
                persistFriendNode(KeepTalkingFriendNode(friendID: friendID, nodeID: node.nodeID, lastSeenAt: node.lastSeenAt))
            }
        case .friendNode:
            if let friendNode = envelope.friendNode {
                persistFriendNode(friendNode)
            }
        case .conversation:
            if let conversation = envelope.conversation {
                mergeConversation(conversation)
            }
        case .stateBundle:
            if let state = envelope.state {
                mergeSnapshot(state)
            }
        case .stateRequest:
            do {
                try syncLocalState(to: envelope.from)
            } catch {
                onLog?("[sdk] failed to answer state request from=\(envelope.from) error=\(error.localizedDescription)")
            }
        case .chat, .none:
            break
        }
        onEnvelope?(envelope)
    }

    private func persistMyNode(_ explicitNode: KeepTalkingNode? = nil) {
        let node = explicitNode ?? KeepTalkingNode(nodeID: config.participantID, userID: config.userID)
        mutateSnapshot { snapshot in
            upsertMyNode(node, in: &snapshot)
        }
    }

    private func persistFriendNode(_ node: KeepTalkingFriendNode) {
        mutateSnapshot { snapshot in
            upsertFriendNode(node, in: &snapshot)
        }
    }

    private func persistConversationMessage(_ message: KeepTalkingConversationMessage, conversationID: String) {
        mutateSnapshot { snapshot in
            appendConversationMessage(message, to: conversationID, in: &snapshot)
        }
    }

    private func mergeConversation(_ context: KeepTalkingConversationContext) {
        mutateSnapshot { snapshot in
            mergeConversationContext(context, in: &snapshot)
        }
    }

    private func mergeSnapshot(_ incoming: KeepTalkingLocalSnapshot) {
        mutateSnapshot { snapshot in
            for node in incoming.myNodes {
                upsertMyNode(node, in: &snapshot)
            }
            for node in incoming.friendNodes {
                upsertFriendNode(node, in: &snapshot)
            }
            for conversation in incoming.conversations {
                mergeConversationContext(conversation, in: &snapshot)
            }
        }
    }

    private func mutateSnapshot(_ mutator: (inout KeepTalkingLocalSnapshot) -> Void) {
        guard let localStore else {
            return
        }
        do {
            var snapshot = try localStore.loadSnapshot()
            mutator(&snapshot)
            try localStore.saveSnapshot(snapshot)
        } catch {
            onLog?("[sdk] local snapshot update failed error=\(error.localizedDescription)")
        }
    }

    private func conversationID(forPeer peerID: String?) -> String {
        if let peerID {
            return "peer:\(peerID)"
        }
        return "session:\(config.session):broadcast"
    }

    private func upsertMyNode(_ node: KeepTalkingNode, in snapshot: inout KeepTalkingLocalSnapshot) {
        if let idx = snapshot.myNodes.firstIndex(where: { $0.nodeID == node.nodeID }) {
            snapshot.myNodes[idx] = node
        } else {
            snapshot.myNodes.append(node)
        }
    }

    private func upsertFriendNode(_ node: KeepTalkingFriendNode, in snapshot: inout KeepTalkingLocalSnapshot) {
        if let idx = snapshot.friendNodes.firstIndex(where: { $0.friendID == node.friendID && $0.nodeID == node.nodeID }) {
            snapshot.friendNodes[idx] = node
        } else {
            snapshot.friendNodes.append(node)
        }
    }

    private func appendConversationMessage(
        _ message: KeepTalkingConversationMessage,
        to conversationID: String,
        in snapshot: inout KeepTalkingLocalSnapshot
    ) {
        if let idx = snapshot.conversations.firstIndex(where: { $0.conversationID == conversationID }) {
            if !snapshot.conversations[idx].messages.contains(where: { $0.id == message.id }) {
                snapshot.conversations[idx].messages.append(message)
                snapshot.conversations[idx].updatedAt = message.timestamp
            }
            return
        }
        snapshot.conversations.append(
            KeepTalkingConversationContext(
                conversationID: conversationID,
                messages: [message],
                updatedAt: message.timestamp
            )
        )
    }

    private func mergeConversationContext(_ context: KeepTalkingConversationContext, in snapshot: inout KeepTalkingLocalSnapshot) {
        if let idx = snapshot.conversations.firstIndex(where: { $0.conversationID == context.conversationID }) {
            var existing = snapshot.conversations[idx]
            for message in context.messages where !existing.messages.contains(where: { $0.id == message.id }) {
                existing.messages.append(message)
            }
            existing.messages.sort { $0.timestamp < $1.timestamp }
            existing.updatedAt = max(existing.updatedAt, context.updatedAt)
            snapshot.conversations[idx] = existing
            return
        }
        snapshot.conversations.append(context)
    }
}
