import CryptoKit
import FluentKit
import Foundation

extension KeepTalkingClient {
    private static let encryptedMessagePrefix = "ktenc:v1:"

    public func send(
        _ text: String,
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)

        let message = KeepTalkingContextMessage(
            context: persistedContext,
            sender: try sender ?? .node(node: node.requireID()),
            content: text
        )
        persistedContext.updatedAt = message.timestamp
        _ = try await persistedContext.$messages.get(on: localStore.database)

        try await message.save(on: localStore.database)
        try await persistedContext.save(on: localStore.database)

        let encryptedMessage = try await encryptedOutboundMessage(message)
        try rtcClient.sendEnvelope(.message(encryptedMessage))
    }

    public func send(
        _ text: String,
        in context: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil
    ) async throws {
        let targetContext = try await ensure(
            context,
            for: KeepTalkingContext.self
        )

        try await send(text, in: targetContext, sender: sender)
    }

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
        let contextID = message.$context.id
        message.content = await decryptedContentIfNeeded(
            message.content,
            contextID: contextID
        )

        Task {
            try? await message.save(on: localStore.database)
        }

        let node = try await getCurrentNodeInstance()

        if case .node(let nodeID) = message.sender, nodeID != config.node {
            let senderNode: KeepTalkingNode
            if let existingSenderNode =
                try await KeepTalkingNode
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
                let status = try await decryptNodeStatusEnvelope(envelope)
                try await mergeDiscoveredNodeStatus(status)
            case .context(let context):
                mergeContext(context)
            case .actionCallRequest(let request):
                if request.targetNodeID == config.node {
                    Task { [weak self] in
                        try await self?.handleIncomingActionCallRequest(request)
                    }
                }
            case .actionCallResult(let result):
                _ = resolvePendingActionCall(result)
            case .encryptedActionCallRequest(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let request = try await decryptActionCallRequestEnvelope(envelope)
                Task { [weak self] in
                    try await self?.handleIncomingActionCallRequest(request)
                }
            case .encryptedActionCallResult(let envelope):
                guard envelope.recipientNodeID == config.node else {
                    break
                }
                let result = try await decryptActionCallResultEnvelope(envelope)
                _ = resolvePendingActionCall(result)
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
        for message in context.messages {
            message.context = persistedContext
            try await message.save(on: localStore.database)
        }
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

    private func encryptedOutboundMessage(
        _ message: KeepTalkingContextMessage
    ) async throws -> KeepTalkingContextMessage {
        let contextID = message.$context.id
        let encryptedContent = try await encryptContent(
            message.content,
            contextID: contextID
        )
        let outbound = KeepTalkingContextMessage(
            id: message.id ?? UUID(),
            context: KeepTalkingContext(id: contextID),
            sender: message.sender,
            content: encryptedContent,
            timestamp: message.timestamp
        )
        return outbound
    }

    private func encryptContent(_ content: String, contextID: UUID) async throws
        -> String
    {
        let secret = try await ensureGroupChatSecret(for: contextID)
        let key = SymmetricKey(data: secret)
        let plaintext = Data(content.utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            return content
        }
        return Self.encryptedMessagePrefix + combined.base64EncodedString()
    }

    private func decryptedContentIfNeeded(_ content: String, contextID: UUID)
        async -> String
    {
        guard content.hasPrefix(Self.encryptedMessagePrefix) else {
            return content
        }
        let secret: Data?
        do {
            secret = try await loadGroupChatSecret(for: contextID)
        } catch {
            rtcClient.debug(
                "loading group secret failed for context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            return content
        }
        guard let secret else {
            rtcClient.debug(
                "encrypted message received but no group secret found for context=\(contextID.uuidString.lowercased())"
            )
            return content
        }
        let payload = String(
            content.dropFirst(Self.encryptedMessagePrefix.count)
        )
        guard let combined = Data(base64Encoded: payload) else {
            return content
        }

        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let key = SymmetricKey(data: secret)
            let decrypted = try AES.GCM.open(sealed, using: key)
            return String(decoding: decrypted, as: UTF8.self)
        } catch {
            rtcClient.debug(
                "failed to decrypt message for context=\(contextID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            return content
        }
    }

    private func loadGroupChatSecret(for contextID: UUID) async throws -> Data? {
        try await KeepTalkingContextGroupSecret.query(on: localStore.database)
            .filter(\.$id, .equal, contextID)
            .first()?
            .secret
    }
}
