import Crypto
import FluentKit
import Foundation

extension KeepTalkingClient {
    private static let maxPushWakePreviewCharacters = 160

    // MARK: - Outgoing messages

    /// Saves a message locally, then schedules and attempts delivery to peers.
    ///
    /// Local persistence defines whether the message exists. The outbox only
    /// tracks whether that persisted message still needs an active transport
    /// push; transport failure never rolls back the local message.
    public func send(
        _ text: String,
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await persistAndBroadcastMessage(
            text,
            preparedAttachments: [],
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Convenience overload that resolves the target context by identifier.
    public func send(
        _ text: String,
        in contextID: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            in: try await outgoingMessageContext(for: contextID),
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Saves a message with attachments sourced from local files.
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

        try await persistAndBroadcastMessage(
            text,
            preparedAttachments: preparedAttachments,
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Convenience overload that resolves the target context by identifier.
    public func send(
        _ text: String,
        attachments: [KeepTalkingLocalAttachmentInput],
        in contextID: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            attachments: attachments,
            in: try await outgoingMessageContext(for: contextID),
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Sends a message that attaches blobs already written to the local
    /// blob store and `kt_blob_records` table — e.g. by the share extension
    /// before handing control to the app. Skips the file-read + hash + upsert
    /// pass that `send(_:attachments:in:)` performs, so the caller must
    /// guarantee each blob row exists with availability `.ready`.
    public func send(
        _ text: String,
        existingBlobs: [KeepTalkingExistingBlobReference],
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let prepared = try await preparedAttachments(from: existingBlobs)

        try await persistAndBroadcastMessage(
            text,
            preparedAttachments: prepared,
            in: context,
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    /// Convenience overload that resolves the target context by identifier.
    public func send(
        _ text: String,
        existingBlobs: [KeepTalkingExistingBlobReference],
        in contextID: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        try await send(
            text,
            existingBlobs: existingBlobs,
            in: try await outgoingMessageContext(for: contextID),
            sender: sender,
            type: type,
            agentTurnID: agentTurnID,
            emitLocalEnvelope: emitLocalEnvelope
        )
    }

    // MARK: - Outgoing message pipeline

    /// Canonical local-first path after attachment preparation.
    ///
    /// The message and attachment rows are persisted before delivery is
    /// attempted. The outbox is a retry ledger for that persisted message, not
    /// a second message store. A thrown persistence, metadata, or key error may
    /// occur after the message row is saved; transport errors are retained on
    /// the outbox and do not escape this method.
    func persistAndBroadcastMessage(
        _ text: String,
        preparedAttachments: [KeepTalkingPreparedAttachment],
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil,
        type: KeepTalkingContextMessage.MessageType = .message,
        agentTurnID: UUID? = nil,
        id: UUID? = nil,
        emitLocalEnvelope: Bool = false
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)
        let sender = try sender ?? .node(node: node.requireID())

        let message = KeepTalkingContextMessage(
            id: id ?? UUID.v7(),
            context: persistedContext,
            sender: sender,
            content: text,
            type: type,
            agentTurnID: agentTurnID
        )

        // updatedAt is advanced by the touch middleware when the message saves.
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

        try await ensureGroupChatSecret(for: persistedContext.requireID())

        // From here on, transport failures don't throw — the message is
        // already persisted locally, so we enqueue it on the outbox and
        // let it drain later when channels open. Context sync will also
        // eventually replicate it through normal sync if the outbox row
        // is dismissed by the user. See `KeepTalkingClient+OutboxController`.
        let messageID = try message.requireID()
        await enqueueOutboxEntry(
            contextMessage: message,
            context: persistedContext
        )
        do {
            try rtcClient.sendEnvelope(message)
            for attachment in savedAttachments {
                guard let attachmentDTO = KeepTalkingContextAttachmentDTO(attachment) else {
                    continue
                }
                try rtcClient.sendEnvelope(attachmentDTO)
            }
            scheduleOutgoingBlobTransfers(for: savedAttachments)
            await clearOutboxEntry(contextMessageID: messageID)
        } catch {
            await recordOutboxFailure(contextMessageID: messageID, error: error)
            onLog?(
                "[client/send] initial transport push failed messageID=\(messageID.uuidString.lowercased()) error=\(error.localizedDescription) — left in outbox"
            )
        }
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

    private func outgoingMessageContext(
        for contextID: UUID
    ) async throws -> KeepTalkingContext {
        try await ensure(contextID, for: KeepTalkingContext.self)
    }

    private func preparedAttachments(
        from references: [KeepTalkingExistingBlobReference]
    ) async throws -> [KeepTalkingPreparedAttachment] {
        guard !references.isEmpty else { return [] }
        let records = try await blobRecordsByBlobID(references.map(\.blobID))
        return try references.map { reference in
            guard let record = records[reference.blobID] else {
                throw KeepTalkingBlobStoreError.blobNotFound(reference.blobID)
            }
            return KeepTalkingPreparedAttachment(
                blobID: reference.blobID,
                filename: reference.filename,
                mimeType: reference.mimeType,
                byteCount: record.byteCount
            )
        }
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
        // A message may have arrived after attachment DTOs that referenced it
        // (separate envelopes, separate Tasks). Re-drive any that were parked
        // waiting for this parent.
        if let messageID = message.id {
            try await flushOrphanAttachments(forParentMessageID: messageID)
        }
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

        // updatedAt is advanced by the touch middleware on each child save below.
        for message in newMessages {
            message.$context.id = try persistedContext.requireID()
            message.$context.value = persistedContext
            try await message.save(on: localStore.database)
        }

        for attachment in newAttachments {
            attachment.$context.id = try persistedContext.requireID()
            attachment.$context.value = persistedContext
            try await attachment.save(on: localStore.database)
            try await ensureSenderRelation(for: attachment.sender)
            try await ensureBlobRecordPlaceholder(for: attachment)
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
        // upsertContext advances updatedAt to max(existing, latestTimestamp) — that
        // IS the batch path's context touch (the bulk insert below bypasses the
        // touch middleware, so nothing double-fires).
        let persistedContext = try await upsertContext(
            KeepTalkingContext(
                id: contextID,
                updatedAt: latestTimestamp
            )
        )
        let resolvedContextID = try persistedContext.requireID()

        // Ensure each DISTINCT non-self sender once (was a per-row query+save).
        for sender in Set(newMessages.map(\.sender)) {
            try await ensureSenderRelation(for: sender)
        }

        // One transaction for the whole batch: `Collection.create(on:)` is a bulk
        // insert (one round-trip, one commit) instead of N autocommitting saves.
        try await localStore.database.transaction { db in
            for message in newMessages {
                message.$context.id = resolvedContextID
                message.$context.value = persistedContext
            }
            try await newMessages.create(on: db)
        }

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
            Set(newAttachments.compactMap(\.parentMessageID))
        )
        let parentMessages =
            parentMessageIDs.isEmpty
            ? []
            : try await KeepTalkingContextMessage.query(on: localStore.database)
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
            if let parentMessageID = attachment.parentMessageID {
                guard let parentMessage = parentMessagesByID[parentMessageID]
                else {
                    // Parent message hasn't been persisted yet — the attachment
                    // envelope beat the message envelope. Park it; it's re-driven
                    // by `flushOrphanAttachments` once the parent message saves.
                    bufferOrphanAttachment(attachment)
                    rtcClient.debug(
                        "buffered orphan attachment dto pending parent message attachment=\(attachment.id.uuidString.lowercased()) parent=\(parentMessageID.uuidString.lowercased())"
                    )
                    continue
                }
                let parentContextID = parentMessage.$context.id
                guard parentContextID == attachment.contextID else {
                    rtcClient.debug(
                        "ignored attachment dto context mismatch attachment=\(attachment.id.uuidString.lowercased()) parent=\(parentMessageID.uuidString.lowercased())"
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
                continue
            }

            guard let sender = attachment.sender else {
                rtcClient.debug(
                    "ignored parentless attachment dto missing sender attachment=\(attachment.id.uuidString.lowercased())"
                )
                continue
            }
            let contextTimestamp = attachment.createdAt ?? Date()
            let persistedContext: KeepTalkingContext
            if let existing = contextsByID[attachment.contextID] {
                persistedContext = existing
            } else {
                let context = try await upsertContext(
                    KeepTalkingContext(
                        id: attachment.contextID,
                        updatedAt: contextTimestamp
                    )
                )
                contextsByID[attachment.contextID] = context
                persistedContext = context
            }
            guard let model = attachment.makeParentlessModel(in: persistedContext) else {
                continue
            }
            try await model.save(on: localStore.database)
            try await ensureSenderRelation(for: sender)
            try await ensureBlobRecordPlaceholder(for: model)
            savedAttachments.append(model)
        }
        return savedAttachments
    }

    // MARK: - Orphan attachment buffering

    /// Park an attachment DTO whose parent message hasn't arrived yet, keyed by
    /// `parentMessageID`. Deduplicates by attachment id so a redelivery doesn't
    /// stack duplicates.
    private func bufferOrphanAttachment(
        _ attachment: KeepTalkingContextAttachmentDTO
    ) {
        guard let parentMessageID = attachment.parentMessageID else { return }
        orphanAttachmentLock.lock()
        defer { orphanAttachmentLock.unlock() }
        var parked = orphanAttachmentsByParentMessageID[parentMessageID] ?? []
        guard !parked.contains(where: { $0.id == attachment.id }) else { return }
        parked.append(attachment)
        orphanAttachmentsByParentMessageID[parentMessageID] = parked
    }

    /// Re-drive any attachment DTOs parked for `parentMessageID` now that the
    /// parent message exists. Called from `handleIncomingMessage` after the
    /// message is persisted.
    private func flushOrphanAttachments(
        forParentMessageID parentMessageID: UUID
    ) async throws {
        let parked: [KeepTalkingContextAttachmentDTO] = {
            orphanAttachmentLock.lock()
            defer { orphanAttachmentLock.unlock() }
            return
                orphanAttachmentsByParentMessageID
                .removeValue(forKey: parentMessageID) ?? []
        }()
        guard !parked.isEmpty else { return }

        let savedAttachments = try await saveIncomingAttachments(parked)
        guard !savedAttachments.isEmpty else { return }
        // Match the live path: pull blobs for the now-linked attachments.
        try await requestAttachmentBlobsIfNeeded(
            for: savedAttachments,
            in: parked[0].contextID
        )
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

    /// Summons NEW immutable context attachment(s) directly from local file(s):
    /// an action OUTPUT becoming a durable, synced attachment. Stores the bytes
    /// content-addressed (so the value is immutable), persists a carrier
    /// `.message` row per attachment (so the output is visible in chat and
    /// replays to the agent), parents the attachment to that message, then
    /// broadcasts each message + attachment DTO and schedules the blob transfer
    /// so participants receive it — exactly like a user-authored file message,
    /// minus user authorship. Returns the saved rows.
    @discardableResult
    func summonContextAttachments(
        _ inputs: [KeepTalkingLocalAttachmentInput],
        in contextID: UUID,
        sender: KeepTalkingContextMessage.Sender? = nil
    ) async throws -> [KeepTalkingContextAttachment] {
        guard !inputs.isEmpty else { return [] }
        guard
            let context = try await KeepTalkingContext.find(
                contextID, on: localStore.database)
        else {
            onLog?(
                "[io/summon] context \(contextID.uuidString.prefix(8)) not found — "
                    + "skipped \(inputs.count) output(s)")
            return []
        }
        let node = try await getCurrentNodeInstance()
        let resolvedSender = try sender ?? .node(node: node.requireID())
        let prepared = try await prepareLocalAttachments(inputs)
        let blobRecords = try await blobRecordsByBlobID(prepared.map(\.blobID))

        // Emit ONE carrier `.message` row for the whole batch so the output is
        // visible in chat and replays to the agent (only `.message` rows are
        // included in agent context). The message body is a short summary; each
        // attachment is parented to it so the UI groups them. This replaces the
        // parentless row — action-produced, but no longer invisible.
        let summary = prepared.enumerated().map { index, input in
            "\(index + 1). \(input.filename) (\(input.byteCount) bytes)"
        }.joined(separator: "\n")
        let message = KeepTalkingContextMessage(
            context: context,
            sender: resolvedSender,
            content: summary,
            type: .message
        )
        try await message.save(on: localStore.database)
        let parentMessageID = try message.requireID()

        var saved: [KeepTalkingContextAttachment] = []
        saved.reserveCapacity(prepared.count)
        for (index, attachmentInput) in prepared.enumerated() {
            let attachment = KeepTalkingContextAttachment(
                context: context,
                parentMessageID: parentMessageID,
                sender: resolvedSender,
                blobID: attachmentInput.blobID,
                filename: attachmentInput.filename,
                mimeType: attachmentInput.mimeType,
                byteCount: attachmentInput.byteCount,
                createdAt: message.timestamp,
                sortIndex: index,
                metadata: .init()
            )
            if let blobRecord = blobRecords[attachmentInput.blobID],
                let data = try? blobStore.read(
                    relativePath: blobRecord.relativePath,
                    blobID: attachmentInput.blobID)
            {
                attachment.metadata = derivedAttachmentMetadata(
                    for: data,
                    mimeType: attachmentInput.mimeType,
                    filename: attachmentInput.filename)
            }
            try await attachment.save(on: localStore.database)
            saved.append(attachment)
        }
        try await context.refreshSyncMetadata(on: localStore.database)

        // Broadcast the carrier message + each attachment DTO and schedule the
        // blob transfers so participants receive the summoned outputs (transport
        // failures are non-fatal — the rows are persisted locally and replicate
        // via normal sync). Summon is for DURABLE, SHARED outputs only; private
        // (.otb) outputs never become attachments — they use the staged-file
        // store instead, so they are never broadcast/synced.
        await enqueueOutboxEntry(contextMessage: message, context: context)
        do {
            try rtcClient.sendEnvelope(message)
            for attachment in saved {
                if let dto = KeepTalkingContextAttachmentDTO(attachment) {
                    try rtcClient.sendEnvelope(dto)
                }
            }
            await clearOutboxEntry(contextMessageID: parentMessageID)
        } catch {
            await recordOutboxFailure(contextMessageID: parentMessageID, error: error)
            onLog?(
                "[io/summon] transport push failed messageID=\(parentMessageID.uuidString.lowercased()) "
                    + "error=\(error.localizedDescription) — left in outbox")
        }
        scheduleOutgoingBlobTransfers(for: saved)
        onLog?(
            "[io/summon] context=\(contextID.uuidString.prefix(8)) "
                + "summoned=\(saved.count) attachment(s) on carrier message=\(parentMessageID.uuidString.prefix(8))")
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

        return MIMEType.inferredMIMEType(
            forFileAt: attachmentInput.sourceURL,
            filename: filename,
            explicit: attachmentInput.mimeType)
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
    @discardableResult
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
