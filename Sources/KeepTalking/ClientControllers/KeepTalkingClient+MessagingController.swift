import CryptoKit
import FluentKit
import Foundation
import UniformTypeIdentifiers

extension KeepTalkingClient {
    private static let maxPushWakePreviewCharacters = 160
    private static let blobChunkSize = 64 * 1024

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
        try await send(
            text,
            attachments: [],
            in: context,
            sender: sender,
            type: type,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    public func send(
        _ text: String,
        attachments: [KeepTalkingLocalAttachmentInput],
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)
        let sender = try sender ?? .node(node: node.requireID())

        let message = KeepTalkingContextMessage(
            context: persistedContext,
            sender: sender,
            content: text,
            type: type
        )
        persistedContext.updatedAt = message.timestamp

        try await message.save(on: localStore.database)
        let savedAttachments = try await persistOutgoingAttachments(
            attachments,
            in: persistedContext,
            parentMessage: message,
            sender: sender
        )
        try await persistedContext.refreshSyncMetadata(on: localStore.database)
        if emitLocalEnvelope {
            onEnvelope?(.message(message))
            savedAttachments.forEach { onEnvelope?(.attachment($0)) }
        }

        _ = try await ensureGroupChatSecret(for: persistedContext.requireID())
        try rtcClient.sendEnvelope(.message(message))
        for attachment in savedAttachments {
            try rtcClient.sendEnvelope(.attachment(attachment))
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
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            attachments: [],
            in: context,
            sender: sender,
            type: type,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    public func send(
        _ text: String,
        attachments: [KeepTalkingLocalAttachmentInput],
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
            attachments: attachments,
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

    func handleIncomingAttachment(_ attachment: KeepTalkingContextAttachment)
        async throws
    {
        try await saveIncomingAttachments(
            [attachment],
            in: attachment.$context.id
        )
    }

    func handleIncomingEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
            case .message(let message):
                try await handleIncomingMessage(message)
                rtcClient.debug("Message cast to envelope")
            case .attachment(let attachment):
                try await handleIncomingAttachment(attachment)
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
        _ attachments: [KeepTalkingContextAttachment],
        in contextID: UUID
    ) async throws {
        guard !attachments.isEmpty else {
            return
        }

        let newAttachments = try await filterNewAttachments(attachments)
        guard !newAttachments.isEmpty else {
            return
        }

        let latestTimestamp = newAttachments.map(\.createdAt).max() ?? Date()
        let persistedContext = try await upsertContext(
            KeepTalkingContext(
                id: contextID,
                updatedAt: latestTimestamp
            )
        )

        for attachment in newAttachments {
            attachment.$context.id = try persistedContext.requireID()
            attachment.$context.value = persistedContext
            try await attachment.save(on: localStore.database)
            try await ensureSenderRelation(for: attachment.sender)
            try await ensureBlobRecordPlaceholder(for: attachment)
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

    private func ensureSenderRelation(
        for sender: KeepTalkingContextMessage.Sender
    ) async throws {
        let node = try await getCurrentNodeInstance()

        guard case .node(let nodeID) = sender, nodeID != config.node else {
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

    private func persistOutgoingAttachments(
        _ attachments: [KeepTalkingLocalAttachmentInput],
        in context: KeepTalkingContext,
        parentMessage: KeepTalkingContextMessage,
        sender: KeepTalkingContextMessage.Sender
    ) async throws -> [KeepTalkingContextAttachment] {
        guard !attachments.isEmpty else {
            return []
        }

        var saved: [KeepTalkingContextAttachment] = []
        saved.reserveCapacity(attachments.count)

        for (index, attachmentInput) in attachments.enumerated() {
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

            let attachment = KeepTalkingContextAttachment(
                context: context,
                parentMessageID: parentMessage.id,
                sender: sender,
                blobID: blobID,
                filename: filename,
                mimeType: mimeType,
                byteCount: data.count,
                createdAt: parentMessage.timestamp,
                sortIndex: index,
                metadata: derivedAttachmentMetadata(
                    for: data,
                    mimeType: mimeType,
                    filename: filename
                )
            )
            try await attachment.save(on: localStore.database)
            saved.append(attachment)
        }

        return saved
    }

    func upsertBlobRecord(
        blobID: String,
        relativePath: String?,
        availability: KeepTalkingBlobAvailability,
        mimeType: String,
        byteCount: Int,
        receivedBytes: Int
    ) async throws {
        if let existing = try await KeepTalkingBlobRecord.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, blobID)
        .first() {
            existing.relativePath = relativePath ?? existing.relativePath
            existing.availability = availability
            existing.mimeType = mimeType
            existing.byteCount = byteCount
            existing.receivedBytes = max(existing.receivedBytes, receivedBytes)
            existing.lastAccessedAt = Date()
            try await existing.save(on: localStore.database)
            return
        }

        let record = KeepTalkingBlobRecord(
            blobID: blobID,
            relativePath: relativePath,
            availability: availability,
            mimeType: mimeType,
            byteCount: byteCount,
            receivedBytes: receivedBytes,
            lastAccessedAt: Date()
        )
        try await record.save(on: localStore.database)
    }

    private func ensureBlobRecordPlaceholder(
        for attachment: KeepTalkingContextAttachment
    ) async throws {
        let blobID = attachment.blobID
        guard
            try await KeepTalkingBlobRecord.query(on: localStore.database)
                .filter(\.$id, .equal, blobID)
                .first() == nil
        else {
            return
        }

        let record = KeepTalkingBlobRecord(
            blobID: blobID,
            relativePath: nil,
            availability: .missing,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            receivedBytes: 0
        )
        try await record.save(on: localStore.database)
    }

    private func scheduleOutgoingBlobTransfers(
        for attachments: [KeepTalkingContextAttachment]
    ) {
        guard !attachments.isEmpty else {
            return
        }

        let uniqueAttachments = Dictionary(
            attachments.map { ($0.blobID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortIndex < $1.sortIndex
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            for attachment in uniqueAttachments {
                do {
                    try await self.sendBlobFrames(
                        blobID: attachment.blobID,
                        mimeType: attachment.mimeType,
                        pathExtension: self.pathExtension(for: attachment),
                        expectedByteCount: attachment.byteCount,
                        recipientNodeID: nil
                    )
                } catch {
                    self.rtcClient.debug(
                        "blob push failed blob=\(attachment.blobID) error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func handleIncomingBlobFrameData(_ data: Data) async throws {
        let frame = try KeepTalkingBlobTransferCodec.decode(data)
        switch frame.header.kind {
            case .request:
                try await handleIncomingBlobRequest(frame.header)
            case .chunk:
                try await handleIncomingBlobChunk(frame)
            case .complete:
                try await handleIncomingBlobComplete(frame.header)
        }
    }

    func requestRecentMissingBlobs(from node: UUID, in contextID: UUID) async throws {
        guard config.recentAttachmentSyncLookback > 0 else {
            return
        }

        let cutoff = Date(
            timeIntervalSinceNow: -config.recentAttachmentSyncLookback
        )
        let attachments = try await recentAttachments(
            in: contextID,
            since: cutoff
        )
        var requestedBlobIDs = Set<String>()

        for attachment in attachments {
            guard requestedBlobIDs.insert(attachment.blobID).inserted else {
                continue
            }
            guard try await isBlobReady(blobID: attachment.blobID) == false else {
                continue
            }
            try sendBlobRequest(for: attachment, to: node)
        }
    }

    private func handleIncomingBlobRequest(
        _ header: KeepTalkingBlobTransferHeader
    ) async throws {
        guard header.recipientNodeID == config.node else {
            return
        }

        try await sendBlobFrames(
            blobID: header.blobID,
            mimeType: header.mimeType ?? "application/octet-stream",
            pathExtension: normalizedPathExtension(header.pathExtension),
            expectedByteCount: header.byteCount ?? 0,
            recipientNodeID: header.senderNodeID
        )
    }

    private func handleIncomingBlobChunk(
        _ frame: KeepTalkingBlobTransferFrame
    ) async throws {
        let header = frame.header
        guard shouldAcceptBlobFrame(header) else {
            return
        }
        guard try await isBlobReady(blobID: header.blobID) == false else {
            return
        }

        let byteCount = max(header.byteCount ?? frame.payload.count, 0)
        let receivedBytes = try blobStore.appendPartial(
            data: frame.payload,
            blobID: header.blobID,
            reset: header.chunkIndex == 0
        )
        try await upsertBlobRecord(
            blobID: header.blobID,
            relativePath: nil,
            availability: .partial,
            mimeType: header.mimeType ?? "application/octet-stream",
            byteCount: byteCount,
            receivedBytes: receivedBytes
        )
    }

    private func handleIncomingBlobComplete(
        _ header: KeepTalkingBlobTransferHeader
    ) async throws {
        guard shouldAcceptBlobFrame(header) else {
            return
        }
        guard try await isBlobReady(blobID: header.blobID) == false else {
            return
        }

        let byteCount = max(header.byteCount ?? 0, 0)
        let mimeType = header.mimeType ?? "application/octet-stream"
        let pathExtension = normalizedPathExtension(header.pathExtension)

        if byteCount == 0 {
            let stored = try blobStore.put(
                data: Data(),
                blobID: header.blobID,
                pathExtension: pathExtension
            )
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: stored.relativePath,
                availability: .ready,
                mimeType: mimeType,
                byteCount: 0,
                receivedBytes: 0
            )
            notifyBlobAvailabilityChange(
                contextID: config.contextID,
                blobID: header.blobID
            )
            return
        }

        let partialData = try blobStore.partialData(blobID: header.blobID)
        guard partialData.count == byteCount else {
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: nil,
                availability: .partial,
                mimeType: mimeType,
                byteCount: byteCount,
                receivedBytes: partialData.count
            )
            rtcClient.debug(
                "blob complete deferred blob=\(header.blobID) expected=\(byteCount) received=\(partialData.count)"
            )
            return
        }

        guard hexDigest(for: partialData) == header.blobID else {
            try? blobStore.removePartial(blobID: header.blobID)
            try await upsertBlobRecord(
                blobID: header.blobID,
                relativePath: nil,
                availability: .missing,
                mimeType: mimeType,
                byteCount: byteCount,
                receivedBytes: 0
            )
            rtcClient.debug("blob digest mismatch blob=\(header.blobID)")
            return
        }

        let stored = try blobStore.promotePartial(
            blobID: header.blobID,
            pathExtension: pathExtension
        )
        try await upsertBlobRecord(
            blobID: header.blobID,
            relativePath: stored.relativePath,
            availability: .ready,
            mimeType: mimeType,
            byteCount: byteCount,
            receivedBytes: byteCount
        )
        notifyBlobAvailabilityChange(
            contextID: config.contextID,
            blobID: header.blobID
        )
    }

    private func sendBlobFrames(
        blobID: String,
        mimeType: String,
        pathExtension: String?,
        expectedByteCount: Int,
        recipientNodeID: UUID?
    ) async throws {
        guard let blobRecord = try await blobRecord(for: blobID),
            blobRecord.availability == .ready,
            let relativePath = blobRecord.relativePath
        else {
            throw KeepTalkingBlobStoreError.blobNotFound(blobID)
        }

        let fileURL = blobStore.fileURL(forRelativePath: relativePath)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let fileByteCount =
            (fileAttributes[.size] as? NSNumber)?.intValue ?? expectedByteCount
        let byteCount = max(fileByteCount, expectedByteCount)
        let chunkCount =
            byteCount == 0
            ? 0
            : (byteCount + Self.blobChunkSize - 1) / Self.blobChunkSize

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var chunkIndex = 0
        while true {
            let chunk = handle.readData(ofLength: Self.blobChunkSize)
            guard !chunk.isEmpty else {
                break
            }

            let header = KeepTalkingBlobTransferHeader(
                kind: .chunk,
                senderNodeID: config.node,
                recipientNodeID: recipientNodeID,
                blobID: blobID,
                mimeType: mimeType,
                pathExtension: pathExtension,
                byteCount: byteCount,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                chunkByteCount: chunk.count
            )
            try rtcClient.sendBlobData(
                try KeepTalkingBlobTransferCodec.encode(
                    KeepTalkingBlobTransferFrame(
                        header: header,
                        payload: chunk
                    )
                )
            )
            chunkIndex += 1
        }

        let completionHeader = KeepTalkingBlobTransferHeader(
            kind: .complete,
            senderNodeID: config.node,
            recipientNodeID: recipientNodeID,
            blobID: blobID,
            mimeType: mimeType,
            pathExtension: pathExtension,
            byteCount: byteCount,
            chunkIndex: nil,
            chunkCount: chunkCount,
            chunkByteCount: nil
        )
        try rtcClient.sendBlobData(
            try KeepTalkingBlobTransferCodec.encode(
                KeepTalkingBlobTransferFrame(
                    header: completionHeader,
                    payload: Data()
                )
            )
        )
    }

    private func sendBlobRequest(
        for attachment: KeepTalkingContextAttachment,
        to node: UUID
    ) throws {
        let header = KeepTalkingBlobTransferHeader(
            kind: .request,
            senderNodeID: config.node,
            recipientNodeID: node,
            blobID: attachment.blobID,
            mimeType: attachment.mimeType,
            pathExtension: pathExtension(for: attachment),
            byteCount: attachment.byteCount,
            chunkIndex: nil,
            chunkCount: nil,
            chunkByteCount: nil
        )
        try rtcClient.sendBlobData(
            try KeepTalkingBlobTransferCodec.encode(
                KeepTalkingBlobTransferFrame(
                    header: header,
                    payload: Data()
                )
            )
        )
    }

    private func recentAttachments(
        in contextID: UUID,
        since: Date
    ) async throws -> [KeepTalkingContextAttachment] {
        let attachments = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
            .filter(\.$context.$id, .equal, contextID)
            .all()
        return attachments
            .filter { $0.createdAt >= since }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
    }

    private func blobRecord(for blobID: String) async throws -> KeepTalkingBlobRecord? {
        try await KeepTalkingBlobRecord.query(on: localStore.database)
            .filter(\.$id, .equal, blobID)
            .first()
    }

    private func isBlobReady(blobID: String) async throws -> Bool {
        guard let blobRecord = try await blobRecord(for: blobID),
            blobRecord.availability == .ready
        else {
            return false
        }

        do {
            _ = try blobStore.read(
                relativePath: blobRecord.relativePath,
                blobID: blobID
            )
            return true
        } catch {
            return false
        }
    }

    private func shouldAcceptBlobFrame(
        _ header: KeepTalkingBlobTransferHeader
    ) -> Bool {
        switch header.kind {
            case .request:
                return header.recipientNodeID == config.node
            case .chunk, .complete:
                guard let recipientNodeID = header.recipientNodeID else {
                    return true
                }
                return recipientNodeID == config.node
        }
    }

    private func pathExtension(
        for attachment: KeepTalkingContextAttachment
    ) -> String? {
        normalizedPathExtension(
            URL(fileURLWithPath: attachment.filename).pathExtension
        )
    }

    private func normalizedPathExtension(_ pathExtension: String?) -> String? {
        guard let pathExtension = pathExtension?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !pathExtension.isEmpty else {
            return nil
        }
        return pathExtension
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

        let pathExtension = resolvedAttachmentPathExtension(
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

    private func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
