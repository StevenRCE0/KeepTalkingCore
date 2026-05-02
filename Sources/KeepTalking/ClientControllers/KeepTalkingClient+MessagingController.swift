import CryptoKit
import FluentKit
import Foundation
import UniformTypeIdentifiers

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
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            preparedAttachments: [],
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    public func send(
        _ text: String,
        attachments: [KeepTalkingLocalAttachmentInput],
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let preparedAttachments = try await prepareLocalAttachments(
            attachments
        )
        try await send(
            text,
            preparedAttachments: preparedAttachments,
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    func send(
        _ text: String,
        preparedAttachments: [KeepTalkingPreparedAttachment],
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)
        let sender = try sender ?? .node(node: node.requireID())

        let message = KeepTalkingContextMessage(
            context: persistedContext,
            sender: sender,
            content: text,
            type: type,
            agentTurnID: agentTurnID
        )
        persistedContext.updatedAt = message.timestamp

        try await message.save(on: localStore.database)
        let savedAttachments = try await persistOutgoingAttachments(
            preparedAttachments,
            in: persistedContext,
            parentMessage: message,
            sender: sender
        )
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
        if emitLocalEnvelope {
            onEnvelope?(message)
            for attachment in savedAttachments {
                if let attachmentDTO = KeepTalkingContextAttachmentDTO(attachment) {
                    onEnvelope?(attachmentDTO)
                }
            }
        }

        _ = try await ensureGroupChatSecret(for: persistedContext.requireID())
        try rtcClient.sendEnvelope(message)
        for attachment in savedAttachments {
            guard let attachmentDTO = KeepTalkingContextAttachmentDTO(attachment) else {
                continue
            }
            try rtcClient.sendEnvelope(attachmentDTO)
        }
        scheduleOutgoingBlobTransfers(for: savedAttachments)
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
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            preparedAttachments: [],
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    public func send(
        _ text: String,
        attachments: [KeepTalkingLocalAttachmentInput],
        in context: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let targetContext = try await ensure(
            context,
            for: KeepTalkingContext.self
        )

        try await send(
            text,
            attachments: attachments,
            in: targetContext,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    func send(
        _ text: String,
        preparedAttachments: [KeepTalkingPreparedAttachment],
        in context: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let targetContext = try await ensure(
            context,
            for: KeepTalkingContext.self
        )

        try await send(
            text,
            preparedAttachments: preparedAttachments,
            in: targetContext,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Shares the full conversation context with connected peers.
    public func sendConversationContext(
        _ context: KeepTalkingConversationContext
    ) async throws {
        try await saveContext(context)
        try rtcClient.sendEnvelope(context)
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

    func handleIncomingAttachment(_ attachment: KeepTalkingContextAttachmentDTO)
        async throws
    {
        let savedAttachments = try await saveIncomingAttachments(
            [attachment]
        )
        guard !savedAttachments.isEmpty else {
            return
        }
        try await requestAttachmentBlobsIfNeeded(
            for: savedAttachments,
            in: attachment.contextID
        )
    }

    func saveContext(_ context: KeepTalkingContext) async throws {
        let persistedContext = try await upsertContext(context)
        let newMessages = try await filterNewMessages(context.messages)
        let newAttachments = try await filterNewAttachments(context.attachments)

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

        for attachment in newAttachments {
            attachment.$context.id = try persistedContext.requireID()
            attachment.$context.value = persistedContext
            try await attachment.save(on: localStore.database)
            try await ensureSenderRelation(for: attachment.sender)
            try await ensureBlobRecordPlaceholder(for: attachment)
            if let updatedAt = persistedContext.updatedAt {
                persistedContext.updatedAt = max(updatedAt, attachment.createdAt)
            } else {
                persistedContext.updatedAt = attachment.createdAt
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

        // Continuation messages use replacing sync: if a non-pending state arrives
        // for a message we already have, update it in place (the dedup filter would
        // otherwise drop it as a duplicate).
        await replaceContinuationStatesIfNeeded(messages)

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
            try await ensureSenderRelation(for: message.sender)
        }

        persistedContext.updatedAt = max(
            persistedContext.updatedAt ?? latestTimestamp,
            latestTimestamp
        )
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
    }

    func saveIncomingAttachments(
        _ attachments: [KeepTalkingContextAttachmentDTO]
    ) async throws -> [KeepTalkingContextAttachment] {
        guard !attachments.isEmpty else {
            return []
        }

        let newAttachments = try await filterNewAttachmentDTOs(attachments)
        guard !newAttachments.isEmpty else {
            return []
        }

        let parentMessageIDs = Array(
            Set(newAttachments.map(\.parentMessageID))
        )
        let parentMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$id ~~ parentMessageIDs)
        .all()

        var parentMessagesByID: [UUID: KeepTalkingContextMessage] = [:]
        for parentMessage in parentMessages {
            guard let messageID = parentMessage.id else {
                continue
            }
            parentMessagesByID[messageID] = parentMessage
        }
        var contextsByID: [UUID: KeepTalkingContext] = [:]
        var savedAttachments: [KeepTalkingContextAttachment] = []

        for attachment in newAttachments {
            guard let parentMessage = parentMessagesByID[attachment.parentMessageID]
            else {
                rtcClient.debug(
                    "ignored attachment dto missing parent message attachment=\(attachment.id.uuidString.lowercased()) parent=\(attachment.parentMessageID.uuidString.lowercased())"
                )
                continue
            }
            let parentContextID = parentMessage.$context.id
            guard parentContextID == attachment.contextID else {
                rtcClient.debug(
                    "ignored attachment dto context mismatch attachment=\(attachment.id.uuidString.lowercased()) parent=\(attachment.parentMessageID.uuidString.lowercased())"
                )
                continue
            }

            let persistedContext: KeepTalkingContext
            if let existing = contextsByID[parentContextID] {
                persistedContext = existing
            } else {
                let context = try await upsertContext(
                    KeepTalkingContext(
                        id: parentContextID,
                        updatedAt: parentMessage.timestamp
                    )
                )
                contextsByID[parentContextID] = context
                persistedContext = context
            }

            let model = attachment.makeModel(
                in: persistedContext,
                parentMessage: parentMessage
            )
            try await model.save(on: localStore.database)
            try await ensureSenderRelation(for: model.sender)
            try await ensureBlobRecordPlaceholder(for: model)
            savedAttachments.append(model)
        }
        return savedAttachments
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

    private func filterNewAttachments(
        _ attachments: [KeepTalkingContextAttachment]
    ) async throws -> [KeepTalkingContextAttachment] {
        var seen = Set<UUID>()
        var uniqueAttachments: [KeepTalkingContextAttachment] = []
        var identifiedAttachments: [UUID] = []

        for attachment in attachments {
            guard let attachmentID = attachment.id else {
                uniqueAttachments.append(attachment)
                continue
            }
            guard seen.insert(attachmentID).inserted else {
                continue
            }
            uniqueAttachments.append(attachment)
            identifiedAttachments.append(attachmentID)
        }

        guard !identifiedAttachments.isEmpty else {
            return uniqueAttachments
        }

        let existingIDs = Set(
            try await KeepTalkingContextAttachment.query(on: localStore.database)
                .filter(\.$id ~~ identifiedAttachments)
                .all()
                .compactMap(\.id)
        )

        return uniqueAttachments.filter { attachment in
            guard let attachmentID = attachment.id else {
                return true
            }
            return !existingIDs.contains(attachmentID)
        }
    }

    private func filterNewAttachmentDTOs(
        _ attachments: [KeepTalkingContextAttachmentDTO]
    ) async throws -> [KeepTalkingContextAttachmentDTO] {
        var seen = Set<UUID>()
        var uniqueAttachments: [KeepTalkingContextAttachmentDTO] = []
        var identifiedAttachments: [UUID] = []

        for attachment in attachments {
            let attachmentID = attachment.id
            guard seen.insert(attachmentID).inserted else {
                continue
            }
            uniqueAttachments.append(attachment)
            identifiedAttachments.append(attachmentID)
        }

        guard !identifiedAttachments.isEmpty else {
            return uniqueAttachments
        }

        let existingIDs = Set(
            try await KeepTalkingContextAttachment.query(on: localStore.database)
                .filter(\.$id ~~ identifiedAttachments)
                .all()
                .compactMap(\.id)
        )

        return uniqueAttachments.filter { attachment in
            !existingIDs.contains(attachment.id)
        }
    }

    private func ensureSenderRelation(
        for sender: KeepTalkingContextMessage.Sender
    ) async throws {
        let node = try await getCurrentNodeInstance()

        guard case .node(let nodeID) = sender, nodeID != config.node else {
            return
        }

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

    func prepareLocalAttachments(
        _ attachments: [KeepTalkingLocalAttachmentInput]
    ) async throws -> [KeepTalkingPreparedAttachment] {
        guard !attachments.isEmpty else {
            return []
        }

        var prepared: [KeepTalkingPreparedAttachment] = []
        prepared.reserveCapacity(attachments.count)

        for attachmentInput in attachments {
            let data = try Data(contentsOf: attachmentInput.sourceURL)
            let blobID = hexDigest(for: data)
            let filename = resolvedAttachmentFilename(attachmentInput)
            let mimeType = resolvedAttachmentMimeType(
                attachmentInput,
                filename: filename
            )
            let pathExtension = resolvedAttachmentPathExtension(
                attachmentInput,
                filename: filename
            )
            let stored = try blobStore.put(
                data: data,
                blobID: blobID,
                pathExtension: pathExtension
            )

            try await upsertBlobRecord(
                blobID: blobID,
                relativePath: stored.relativePath,
                availability: .ready,
                mimeType: mimeType,
                byteCount: data.count,
                receivedBytes: data.count
            )

            prepared.append(
                KeepTalkingPreparedAttachment(
                    blobID: blobID,
                    filename: filename,
                    mimeType: mimeType,
                    byteCount: data.count
                )
            )
        }

        return prepared
    }

    func persistOutgoingAttachments(
        _ attachments: [KeepTalkingPreparedAttachment],
        in context: KeepTalkingContext,
        parentMessage: KeepTalkingContextMessage,
        sender: KeepTalkingContextMessage.Sender
    ) async throws -> [KeepTalkingContextAttachment] {
        guard !attachments.isEmpty else {
            return []
        }

        var saved: [KeepTalkingContextAttachment] = []
        saved.reserveCapacity(attachments.count)
        let blobRecords = try await blobRecordsByBlobID(attachments.map(\.blobID))

        for (index, attachmentInput) in attachments.enumerated() {
            let attachment = KeepTalkingContextAttachment(
                context: context,
                parentMessageID: parentMessage.id,
                sender: sender,
                blobID: attachmentInput.blobID,
                filename: attachmentInput.filename,
                mimeType: attachmentInput.mimeType,
                byteCount: attachmentInput.byteCount,
                createdAt: parentMessage.timestamp,
                sortIndex: index,
                metadata: .init()
            )

            if let blobRecord = blobRecords[attachmentInput.blobID],
                let data = try? blobStore.read(
                    relativePath: blobRecord.relativePath,
                    blobID: attachmentInput.blobID
                )
            {
                attachment.metadata = derivedAttachmentMetadata(
                    for: data,
                    mimeType: attachmentInput.mimeType,
                    filename: attachmentInput.filename
                )
            }
            try await attachment.save(on: localStore.database)
            saved.append(attachment)
        }

        return saved
    }

    private func resolvedAttachmentFilename(
        _ attachmentInput: KeepTalkingLocalAttachmentInput
    ) -> String {
        let filename = attachmentInput.filename?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let filename, !filename.isEmpty {
            return filename
        }
        return attachmentInput.sourceURL.lastPathComponent
    }

    private func resolvedAttachmentPathExtension(
        _ attachmentInput: KeepTalkingLocalAttachmentInput,
        filename: String
    ) -> String? {
        let explicitExtension = attachmentInput.sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitExtension.isEmpty {
            return explicitExtension
        }

        let fallbackExtension = URL(fileURLWithPath: filename).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackExtension.isEmpty ? nil : fallbackExtension
    }

    private func resolvedAttachmentMimeType(
        _ attachmentInput: KeepTalkingLocalAttachmentInput,
        filename: String
    ) -> String {
        if let mimeType = attachmentInput.mimeType?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !mimeType.isEmpty {
            return mimeType
        }

        let pathExtension =
            resolvedAttachmentPathExtension(
                attachmentInput,
                filename: filename
            ) ?? ""
        if let type = UTType(filenameExtension: pathExtension),
            let mimeType = type.preferredMIMEType
        {
            return mimeType
        }
        return "application/octet-stream"
    }

    private func derivedAttachmentMetadata(
        for data: Data,
        mimeType: String,
        filename: String
    ) -> KeepTalkingContextAttachmentMetadata {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension
            .lowercased()
        let textPreview = textPreviewIfAvailable(
            from: data,
            mimeType: mimeType,
            pathExtension: pathExtension
        )
        return KeepTalkingContextAttachmentMetadata(
            textPreview: textPreview
        )
    }

    private func textPreviewIfAvailable(
        from data: Data,
        mimeType: String,
        pathExtension: String
    ) -> String? {
        let knownTextExtensions: Set<String> = [
            "c", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
            "js", "json", "log", "md", "mjs", "py", "sh", "sql",
            "svelte", "swift", "toml", "ts", "txt", "xml", "yaml",
            "yml",
        ]
        let isTextLike =
            mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType == "application/xml"
            || knownTextExtensions.contains(pathExtension)

        guard isTextLike else {
            return nil
        }

        let preview = String(decoding: data.prefix(4_000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    /// Returns the symmetric key for a context, creating one if needed.
    public func ensureGroupChatSecret(for contextID: UUID) async throws -> Data {
        if let existing = try await keychain.get(.groupSecret(contextID: contextID)) {
            return existing
        }

        _ = try await upsertContext(KeepTalkingContext(id: contextID))
        let key = SymmetricKey(size: .bits256)
        let secret = key.withUnsafeBytes { Data($0) }
        try await keychain.set(.groupSecret(contextID: contextID), value: secret)
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
        try await keychain.set(.groupSecret(contextID: contextID), value: secret)
    }

    func loadGroupChatSecret(for contextID: UUID) async throws -> Data? {
        try await keychain.get(.groupSecret(contextID: contextID))
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

    /// Replacing sync for continuation messages: when a non-pending state arrives
    /// for a message that already exists locally, update it in place and fire the
    /// local envelope sink so the UI refreshes immediately.
    private func replaceContinuationStatesIfNeeded(
        _ messages: [KeepTalkingContextMessage]
    ) async {
        let candidates = messages.compactMap { msg -> (UUID, KeepTalkingContextMessage.AgentTurnContinuationState)? in
            guard let id = msg.id,
                case .agentTurnContinuation(_, _, _, _, _, let state) = msg.type,
                state != .pending
            else { return nil }
            return (id, state)
        }
        guard !candidates.isEmpty else { return }

        let candidateIDs = candidates.map(\.0)
        let existing =
            (try? await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$id ~~ candidateIDs)
                .all()) ?? []

        for existing in existing {
            guard let id = existing.id,
                case .agentTurnContinuation(
                    let toolCallID, let actionID, let targetNodeID, let kind, let payload, let currentState) = existing
                    .type,
                currentState == .pending,
                let newState = candidates.first(where: { $0.0 == id })?.1
            else { continue }

            existing.type = .agentTurnContinuation(
                toolCallID: toolCallID,
                actionID: actionID,
                targetNodeID: targetNodeID,
                kind: kind,
                encryptedPayload: payload,
                state: newState
            )
            try? await existing.save(on: localStore.database)
            onEnvelope?(existing)
        }
    }
}
