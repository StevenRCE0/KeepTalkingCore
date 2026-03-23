import CryptoKit
import FluentKit
import Foundation

extension KeepTalkingClient {
    private static let maxPushWakePreviewCharacters = 160

    /// Persists and broadcasts a message within a conversation context.
    ///
    /// - Parameters:
    ///   - text: Message body to send.
    ///   - context: Target conversation context.
    ///   - sender: Optional explicit sender override.
    ///   - type: Message classification used by the UI.
    ///   - emitLocalEnvelope: Whether to emit the envelope locally before transport delivery.
    public func send(
        _ text: String,
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)

        let message = KeepTalkingContextMessage(
            context: persistedContext,
            sender: try sender ?? .node(node: node.requireID()),
            content: text,
            type: type
        )
        persistedContext.updatedAt = message.timestamp

        try await message.save(on: localStore.database)
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
        if emitLocalEnvelope {
            onEnvelope?(.message(message))
        }

        _ = try await ensureGroupChatSecret(for: persistedContext.requireID())
        try rtcClient.sendEnvelope(.message(message))
        guard message.type == .message else {
            return
        }

        if let messagePreview = await pushWakePreview(for: message) {
            Task { [weak self] in
                await self?.sendContextWakeNotificationsIfNeeded(
                    for: persistedContext,
                    messagePreview: messagePreview
                )
            }
        }
    }

    /// Convenience overload that resolves the target context from its identifier.
    public func send(
        _ text: String,
        in context: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let targetContext = try await ensure(
            context,
            for: KeepTalkingContext.self
        )

        try await send(
            text,
            in: targetContext,
            sender: sender,
            type: type,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Shares the full conversation context with connected peers.
    public func sendConversationContext(
        _ context: KeepTalkingConversationContext
    ) async throws {
        try await saveContext(context)
        try rtcClient.sendEnvelope(.context(context))
    }

    func mergeContext(_ context: KeepTalkingContext) {
        Task {
            try? await self.saveContext(context)
        }
    }

    func handleIncomingMessage(_ message: KeepTalkingContextMessage)
        async throws
    {
        try await saveIncomingMessages([message], in: message.$context.id)
    }

    func handleIncomingEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
            case .message(let message):
                try await handleIncomingMessage(message)
                rtcClient.debug("Message cast to envelope")
            case .node(let node):
                try await mergeDiscoveredNode(node)
            case .nodeStatus(let status):
                try await mergeDiscoveredNodeStatus(status)
            case .encryptedNodeStatus(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                do {
                    let status = try await decryptNodeStatusEnvelope(envelope)
                    try await mergeDiscoveredNodeStatus(status)
                } catch {
                    throw error
                }
            case .contextSync(let envelope):
                try await handleIncomingContextSyncEnvelope(envelope)
            case .context(let context):
                mergeContext(context)
            case .actionCallRequest(let request):
                if request.targetNodeID == config.node {
                    Task { [weak self] in
                        do {
                            try await self?.handleIncomingActionCallRequest(
                                request
                            )
                        } catch {
                            self?.onLog?(
                                "[action-call/request] failed request=\(request.id.uuidString.lowercased()) action=\(request.call.action.uuidString.lowercased()) error=\(error.localizedDescription)"
                            )
                        }
                    }
                }
            case .requestAck(let acknowledgement):
                if acknowledgement.callerNodeID == config.node {
                    handleIncomingRequestAck(acknowledgement)
                }
            case .actionCallResult(let result):
                _ = resolvePendingActionCall(result)
            case .encryptedActionCallRequest(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let request = try await decryptActionCallRequestEnvelope(envelope)
                Task { [weak self] in
                    do {
                        try await self?.handleIncomingActionCallRequest(
                            request
                        )
                    } catch {
                        self?.onLog?(
                            "[action-call/request] failed request=\(request.id.uuidString.lowercased()) action=\(request.call.action.uuidString.lowercased()) error=\(error.localizedDescription)"
                        )
                    }
                }
            case .encryptedRequestAck(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let acknowledgement = try await decryptRequestAckEnvelope(
                    envelope
                )
                if acknowledgement.callerNodeID == config.node {
                    handleIncomingRequestAck(acknowledgement)
                }
            case .encryptedActionCallResult(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let result = try await decryptActionCallResultEnvelope(envelope)
                _ = resolvePendingActionCall(result)
            case .actionCatalogRequest(let request):
                if request.targetNodeID == config.node {
                    Task { [weak self] in
                        try await self?.handleIncomingActionCatalogRequest(
                            request
                        )
                    }
                }
            case .actionCatalogResult(let result):
                _ = resolvePendingActionCatalogResult(result)
            case .encryptedActionCatalogRequest(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let request = try await decryptActionCatalogRequestEnvelope(
                    envelope
                )
                Task { [weak self] in
                    try await self?.handleIncomingActionCatalogRequest(request)
                }
            case .encryptedActionCatalogResult(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let result = try await decryptActionCatalogResultEnvelope(
                    envelope
                )
                _ = resolvePendingActionCatalogResult(result)
            case .p2pPresence(let presence):
                guard presence.node != config.node else {
                    break
                }
                let nodeIDText = presence.node.uuidString.lowercased()
                do {
                    try await markNodeDiscovered(presence.node)
                } catch {
                    rtcClient.debug(
                        "mark node discovered failed node=\(nodeIDText) error=\(error.localizedDescription)"
                    )
                }
                scheduleDebouncedNodeStateBroadcast(
                    reason: "p2pPresence node=\(nodeIDText)"
                )
            default:
                break
        }

        onEnvelope?(envelope)
    }

    func saveContext(_ context: KeepTalkingContext) async throws {
        let persistedContext = try await upsertContext(context)
        let newMessages = try await filterNewMessages(context.messages)

        for message in newMessages {
            message.$context.id = try persistedContext.requireID()
            message.$context.value = persistedContext
            try await message.save(on: localStore.database)
            if let updatedAt = persistedContext.updatedAt {
                persistedContext.updatedAt = max(updatedAt, message.timestamp)
            } else {
                persistedContext.updatedAt = message.timestamp
            }
        }
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
    }

    func saveIncomingMessages(
        _ messages: [KeepTalkingContextMessage],
        in contextID: UUID
    ) async throws {
        guard !messages.isEmpty else {
            return
        }

        let newMessages = try await filterNewMessages(messages)
        guard !newMessages.isEmpty else {
            return
        }

        let latestTimestamp = newMessages.map(\.timestamp).max() ?? Date()
        let persistedContext = try await upsertContext(
            KeepTalkingContext(
                id: contextID,
                updatedAt: latestTimestamp
            )
        )

        for message in newMessages {
            message.$context.id = try persistedContext.requireID()
            message.$context.value = persistedContext
            try await message.save(on: localStore.database)
            try await ensureMessageSenderRelation(for: message)
        }

        persistedContext.updatedAt = max(
            persistedContext.updatedAt ?? latestTimestamp,
            latestTimestamp
        )
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
    }

    func upsertContext(_ context: KeepTalkingContext) async throws
        -> KeepTalkingContext
    {
        guard let contextID = context.id else {
            try await context.save(on: localStore.database)
            return context
        }

        if let existing = try await KeepTalkingContext.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, contextID)
        .first() {
            if let updatedAt = context.updatedAt {
                if let existingUpdatedAt = existing.updatedAt {
                    existing.updatedAt = max(existingUpdatedAt, updatedAt)
                } else {
                    existing.updatedAt = updatedAt
                }
                try await existing.save(on: localStore.database)
            }
            return existing
        }

        try await context.save(on: localStore.database)
        return context
    }

    private func filterNewMessages(
        _ messages: [KeepTalkingContextMessage]
    ) async throws -> [KeepTalkingContextMessage] {
        var seen = Set<UUID>()
        var uniqueMessages: [KeepTalkingContextMessage] = []
        var identifiedMessages: [UUID] = []

        for message in messages {
            guard let messageID = message.id else {
                uniqueMessages.append(message)
                continue
            }
            guard seen.insert(messageID).inserted else {
                continue
            }
            uniqueMessages.append(message)
            identifiedMessages.append(messageID)
        }

        guard !identifiedMessages.isEmpty else {
            return uniqueMessages
        }

        let existingIDs = Set(
            try await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$id ~~ identifiedMessages)
                .all()
                .compactMap(\.id)
        )

        return uniqueMessages.filter { message in
            guard let messageID = message.id else {
                return true
            }
            return !existingIDs.contains(messageID)
        }
    }

    private func ensureMessageSenderRelation(
        for message: KeepTalkingContextMessage
    ) async throws {
        let node = try await getCurrentNodeInstance()

        guard case .node(let nodeID) = message.sender, nodeID != config.node
        else {
            return
        }

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

        let relationExists =
            try await KeepTalkingNodeRelation
            .query(on: localStore.database)
            .filter(\.$from.$id, .equal, try node.requireID())
            .filter(\.$to.$id, .equal, nodeID)
            .count() > 0

        if !relationExists {
            let relationship = try KeepTalkingNodeRelation(
                from: node,
                to: senderNode,
                relationship: .pending
            )
            try await relationship.save(on: localStore.database)
        }
    }

    /// Returns the symmetric key for a context, creating one if needed.
    public func ensureGroupChatSecret(for contextID: UUID) async throws -> Data {
        if let existing = try await KeepTalkingContextGroupSecret.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, contextID)
        .first() {
            return existing.secret
        }

        _ = try await upsertContext(KeepTalkingContext(id: contextID))
        let key = SymmetricKey(size: .bits256)
        let secret = key.withUnsafeBytes { Data($0) }
        let contextSecret = KeepTalkingContextGroupSecret(
            contextID: contextID,
            secret: secret
        )
        try await contextSecret.save(on: localStore.database)
        return secret
    }

    /// Replaces the stored symmetric key for a conversation context.
    public func setGroupChatSecret(_ secret: Data, for contextID: UUID)
        async throws
    {
        guard !secret.isEmpty else {
            throw KeepTalkingKVServiceError.invalidStoredValue
        }

        _ = try await upsertContext(KeepTalkingContext(id: contextID))
        if let existing = try await KeepTalkingContextGroupSecret.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, contextID)
        .first() {
            existing.secret = secret
            try await existing.save(on: localStore.database)
            return
        }

        let contextSecret = KeepTalkingContextGroupSecret(
            contextID: contextID,
            secret: secret
        )
        try await contextSecret.save(on: localStore.database)
    }

    func loadGroupChatSecret(for contextID: UUID) async throws -> Data? {
        try await KeepTalkingContextGroupSecret.query(on: localStore.database)
            .filter(\.$id, .equal, contextID)
            .first()?
            .secret
    }

    private func pushWakePreview(
        for message: KeepTalkingContextMessage
    ) async -> KeepTalkingPushWakeMessagePreview? {
        let rawContent = message.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !rawContent.isEmpty else {
            return nil
        }

        let previewText = String(
            rawContent.prefix(Self.maxPushWakePreviewCharacters)
        )
        guard !previewText.isEmpty else {
            return nil
        }

        return KeepTalkingPushWakeMessagePreview(
            sender: message.sender,
            content: previewText,
            isTruncated: rawContent.count > previewText.count
        )
    }
}
