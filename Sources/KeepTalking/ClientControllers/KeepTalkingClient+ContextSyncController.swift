import FluentKit
import Foundation

extension KeepTalkingClient {
    private static let contextSyncResultTimeoutSeconds: TimeInterval = 15

    func syncCurrentContext(with node: UUID) async {
        guard node != config.node else { return }

        do {
            let context = try await ensure(
                config.contextID,
                for: KeepTalkingContext.self,
                strict: true
            )
            let contextID = try context.requireID()
            let remoteSummary = try await dispatchContextSyncSummaryRequest(
                to: node,
                in: context
            )

            var localSummary = try await contextSyncSnapshot(
                for: contextID
            ).summary

            if let tailRequest = KeepTalkingContextSyncTailRequest(
                context: contextID,
                requester: config.node,
                recipient: node,
                local: localSummary,
                remote: remoteSummary.summary
            ) {
                let tailResult = try await dispatchContextSyncTailRequest(
                    tailRequest
                )
                try await persistContextSyncMessagesResult(tailResult)
            }

            localSummary = try await contextSyncSnapshot(
                for: contextID
            ).summary

            if let chunkRequest = KeepTalkingContextSyncChunkRequest(
                context: contextID,
                requester: config.node,
                recipient: node,
                local: localSummary,
                remote: remoteSummary.summary
            ) {
                let chunkResult = try await dispatchContextSyncChunkRequest(
                    chunkRequest
                )
                try await persistContextSyncMessagesResult(chunkResult)
            }

            // Side notes use full-sync semantics: pull the entire set from the
            // peer and merge by `(key, updatedAt)`. Transparently chunked at
            // the transport layer when payload exceeds the SCTP per-message
            // ceiling, so there's no chunking decision to make here.
            let sideNotesResult = try await dispatchContextSyncSideNotesRequest(
                to: node,
                contextID: contextID
            )
            try await mergeSideNotes(
                sideNotesResult.sideNotes,
                contextID: contextID
            )

            Task.detached(priority: .background) { [self] in
                if config.recentAttachmentSyncLookback > 0 {
                    let since = Date(
                        timeIntervalSinceNow: -config.recentAttachmentSyncLookback
                    )
                    // Recover missing attachment *records* first (creates rows
                    // for orphans), then missing blob *bytes* for records we
                    // hold. The records response itself kicks off blob fetches
                    // for anything it newly creates, so the two are complementary.
                    try await requestRecentMissingAttachmentRecords(
                        in: contextID,
                        since: since,
                        from: node
                    )
                    try await requestRecentMissingAttachmentBlobs(
                        in: contextID,
                        since: since
                    )
                }
            }

            rtcClient.debug(
                "context sync complete peer=\(node.uuidString.lowercased()) context=\(contextID.uuidString.lowercased())"
            )
            notifyContextDidSync(contextID)
        } catch {
            rtcClient.debug(
                "context sync failed peer=\(node.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
        }
    }

    func handleIncomingContextSyncEnvelope(
        _ envelope: KeepTalkingContextSyncEnvelope
    ) async throws {
        switch envelope {
            case .summaryRequest(let request):
                guard request.recipient == config.node else {
                    return
                }
                let result = try await executeContextSyncSummaryRequest(
                    request
                )
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.summaryResult(result)
                )
            case .summaryResult(let result):
                guard result.requester == config.node else {
                    return
                }
                _ = resolvePendingContextSyncSummary(result)
            case .tailRequest(let request):
                guard request.recipient == config.node else {
                    return
                }
                let result = try await executeContextSyncTailRequest(request)
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.messagesResult(result)
                )
            case .chunkRequest(let request):
                guard request.recipient == config.node else {
                    return
                }
                let result = try await executeContextSyncChunkRequest(request)
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.messagesResult(result)
                )
            case .messagesResult(let result):
                guard result.requester == config.node else {
                    return
                }
                _ = resolvePendingContextSyncMessages(result)
            case .attachmentRequest(let request):
                guard request.requester != config.node else {
                    return
                }
                try await respondToContextSyncAttachmentRequest(request)
            case .attachmentRecordsRequest(let request):
                guard request.recipient == config.node else {
                    return
                }
                let result = try await executeContextSyncAttachmentRecordsRequest(request)
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.attachmentRecordsResult(result)
                )
            case .attachmentRecordsResult(let result):
                guard result.requester == config.node else {
                    return
                }
                try await persistContextSyncAttachmentRecordsResult(result)
            case .sideNotesRequest(let request):
                guard request.recipient == config.node else {
                    return
                }
                let result = try await executeContextSyncSideNotesRequest(request)
                try rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.sideNotesResult(result)
                )
            case .sideNotesResult(let result):
                guard result.requester == config.node else {
                    return
                }
                _ = resolvePendingContextSyncSideNotes(result)
        }
    }

    func dispatchContextSyncSummaryRequest(
        to node: UUID,
        in context: KeepTalkingContext
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        let request = KeepTalkingContextSyncSummaryRequest(
            context: try context.requireID(),
            requester: config.node,
            recipient: node
        )

        if node == config.node {
            return try await executeContextSyncSummaryRequest(request)
        }

        return try await waitForContextSyncSummary(
            request: request.request,
            timeoutSeconds: Self.contextSyncResultTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.summaryRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncTailRequest(
        _ request: KeepTalkingContextSyncTailRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        if request.recipient == config.node {
            return try await executeContextSyncTailRequest(request)
        }

        return try await waitForContextSyncMessages(
            request: request.request,
            timeoutSeconds: Self.contextSyncResultTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.tailRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncSideNotesRequest(
        to node: UUID,
        contextID: UUID
    ) async throws -> KeepTalkingContextSyncSideNotesResult {
        let request = KeepTalkingContextSyncSideNotesRequest(
            context: contextID,
            requester: config.node,
            recipient: node
        )
        if node == config.node {
            return try await executeContextSyncSideNotesRequest(request)
        }
        return try await waitForContextSyncSideNotes(
            request: request.request,
            timeoutSeconds: Self.contextSyncResultTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.sideNotesRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncChunkRequest(
        _ request: KeepTalkingContextSyncChunkRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        if request.recipient == config.node {
            return try await executeContextSyncChunkRequest(request)
        }

        return try await waitForContextSyncMessages(
            request: request.request,
            timeoutSeconds: Self.contextSyncResultTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.chunkRequest(request)
                )
            }
        )
    }

    func waitForContextSyncSummary(
        request: UUID,
        timeoutSeconds: TimeInterval,
        send: @escaping @Sendable () throws -> Void = {}
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        try await withThrowingTaskGroup(
            of: KeepTalkingContextSyncSummaryResult.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.contextSyncTimeout(request)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingContextSyncSummaryResult, Error
                        >
                    ) in
                    do {
                        self.contextSyncQueue.sync {
                            self.pendingContextSyncSummaries[request] =
                                continuation
                        }
                        try send()
                    } catch {
                        self.failPendingContextSyncSummary(
                            request: request,
                            error: error
                        )
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingContextSyncSummary(
                    request: request,
                    error: KeepTalkingClientError.contextSyncTimeout(request)
                )
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }
            return first
        }
    }

    func waitForContextSyncMessages(
        request: UUID,
        timeoutSeconds: TimeInterval,
        send: @escaping @Sendable () throws -> Void = {}
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        try await withThrowingTaskGroup(
            of: KeepTalkingContextSyncMessagesResult.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.contextSyncTimeout(request)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingContextSyncMessagesResult, Error
                        >
                    ) in
                    do {
                        self.contextSyncQueue.sync {
                            self.pendingContextSyncMessages[request] =
                                continuation
                        }
                        try send()
                    } catch {
                        self.failPendingContextSyncMessages(
                            request: request,
                            error: error
                        )
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingContextSyncMessages(
                    request: request,
                    error: KeepTalkingClientError.contextSyncTimeout(request)
                )
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }
            return first
        }
    }

    func waitForContextSyncSideNotes(
        request: UUID,
        timeoutSeconds: TimeInterval,
        send: @escaping @Sendable () throws -> Void = {}
    ) async throws -> KeepTalkingContextSyncSideNotesResult {
        try await withThrowingTaskGroup(
            of: KeepTalkingContextSyncSideNotesResult.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw KeepTalkingClientError.contextSyncTimeout(request)
                }
                return try await withCheckedThrowingContinuation {
                    (
                        continuation: CheckedContinuation<
                            KeepTalkingContextSyncSideNotesResult, Error
                        >
                    ) in
                    do {
                        self.contextSyncQueue.sync {
                            self.pendingContextSyncSideNotes[request] =
                                continuation
                        }
                        try send()
                    } catch {
                        self.failPendingContextSyncSideNotes(
                            request: request,
                            error: error
                        )
                    }
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
                self?.failPendingContextSyncSideNotes(
                    request: request,
                    error: KeepTalkingClientError.contextSyncTimeout(request)
                )
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }

            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw KeepTalkingClientError.contextSyncTimeout(request)
            }
            return first
        }
    }

    func resolvePendingContextSyncSideNotes(
        _ result: KeepTalkingContextSyncSideNotesResult
    ) -> Bool {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncSideNotes.removeValue(
                    forKey: result.request
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingContextSyncSideNotes(request: UUID, error: Error) {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncSideNotes.removeValue(
                    forKey: request
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func resolvePendingContextSyncMessages(
        _ result: KeepTalkingContextSyncMessagesResult
    ) -> Bool {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncMessages.removeValue(
                    forKey: result.request
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func resolvePendingContextSyncSummary(
        _ result: KeepTalkingContextSyncSummaryResult
    ) -> Bool {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncSummaries.removeValue(
                    forKey: result.request
                )
            else {
                return false
            }
            continuation.resume(returning: result)
            return true
        }
    }

    func failPendingContextSyncSummary(request: UUID, error: Error) {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncSummaries.removeValue(
                    forKey: request
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func failPendingContextSyncMessages(request: UUID, error: Error) {
        contextSyncQueue.sync {
            guard
                let continuation = pendingContextSyncMessages.removeValue(
                    forKey: request
                )
            else {
                return
            }
            continuation.resume(throwing: error)
        }
    }

    func failAllPendingContextSync(error: Error) {
        contextSyncQueue.sync {
            let summaries = pendingContextSyncSummaries
            let messages = pendingContextSyncMessages
            let sideNotes = pendingContextSyncSideNotes
            pendingContextSyncSummaries.removeAll()
            pendingContextSyncMessages.removeAll()
            pendingContextSyncSideNotes.removeAll()
            for continuation in summaries.values {
                continuation.resume(throwing: error)
            }
            for continuation in messages.values {
                continuation.resume(throwing: error)
            }
            for continuation in sideNotes.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func executeContextSyncSummaryRequest(
        _ request: KeepTalkingContextSyncSummaryRequest
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        return KeepTalkingContextSyncSummaryResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            summary: snapshot.summary
        )
    }

    private func executeContextSyncTailRequest(
        _ request: KeepTalkingContextSyncTailRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        let messages = snapshot.messages(after: request.senders)
        return KeepTalkingContextSyncMessagesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            messages: messages,
            attachments: snapshot.attachments(for: messages)
        )
    }

    private func executeContextSyncChunkRequest(
        _ request: KeepTalkingContextSyncChunkRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        let messages = snapshot.messages(in: request.chunks)
        return KeepTalkingContextSyncMessagesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            messages: messages,
            attachments: snapshot.attachments(for: messages)
        )
    }

    /// Responder side: return every attachment DTO we hold for the requested
    /// message IDs. The requester filters out ones it already has, so it's
    /// safe to return all of them.
    private func executeContextSyncAttachmentRecordsRequest(
        _ request: KeepTalkingContextSyncAttachmentRecordsRequest
    ) async throws -> KeepTalkingContextSyncAttachmentRecordsResult {
        let dtos: [KeepTalkingContextAttachmentDTO]
        if request.messageIDs.isEmpty {
            dtos = []
        } else {
            let rows = try await KeepTalkingContextAttachment.query(
                on: localStore.database
            )
            .filter(\.$context.$id, .equal, request.context)
            .filter(\.$parentMessage.$id ~~ request.messageIDs)
            .all()
            dtos = rows.compactMap(KeepTalkingContextAttachmentDTO.init)
        }
        return KeepTalkingContextSyncAttachmentRecordsResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            attachments: dtos
        )
    }

    /// Requester side: persist recovered attachment records. `saveIncomingAttachments`
    /// dedups against what we already have and pulls blobs for the newly-linked
    /// ones, so this both creates missing records and kicks off their downloads.
    private func persistContextSyncAttachmentRecordsResult(
        _ result: KeepTalkingContextSyncAttachmentRecordsResult
    ) async throws {
        guard !result.attachments.isEmpty else { return }
        let savedAttachments = try await saveIncomingAttachments(result.attachments)
        if !savedAttachments.isEmpty {
            try await requestAttachmentBlobsIfNeeded(
                for: savedAttachments,
                in: result.context
            )
        }
    }

    private func executeContextSyncSideNotesRequest(
        _ request: KeepTalkingContextSyncSideNotesRequest
    ) async throws -> KeepTalkingContextSyncSideNotesResult {
        let sideNotes = try await allSideNoteDTOs(for: request.context)
        return KeepTalkingContextSyncSideNotesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            sideNotes: sideNotes
        )
    }

    private func allSideNoteDTOs(for contextID: UUID) async throws -> [KeepTalkingSideNoteDTO] {
        let context = try await ensure(contextID, for: KeepTalkingContext.self)
        return try await context.$sideNotes
            .query(on: localStore.database)
            .all()
            .compactMap { KeepTalkingSideNoteDTO($0) }
    }

    func mergeSideNotes(
        _ incoming: [KeepTalkingSideNoteDTO],
        contextID: UUID
    ) async throws {
        for dto in incoming {
            if let existing = try await KeepTalkingSideNote.query(on: localStore.database)
                .filter(\.$context.$id == contextID)
                .filter(\.$key == dto.key)
                .first()
            {
                let localUpdatedAt = existing.updatedAt ?? .distantPast
                let remoteUpdatedAt = dto.updatedAt ?? .distantPast
                guard remoteUpdatedAt > localUpdatedAt else { continue }
                existing.value = dto.value
                existing.isArchived = dto.isArchived
                try await existing.save(on: localStore.database)
            } else {
                let note = KeepTalkingSideNote(
                    id: dto.id,
                    contextID: contextID,
                    key: dto.key,
                    value: dto.value,
                    isArchived: dto.isArchived
                )
                try await note.save(on: localStore.database)
            }
        }
    }

    private func persistContextSyncMessagesResult(
        _ result: KeepTalkingContextSyncMessagesResult
    ) async throws {
        try await saveIncomingMessages(
            result.messages,
            in: result.context
        )
        let savedAttachments = try await saveIncomingAttachments(
            result.attachments
        )
        if !savedAttachments.isEmpty {
            try await requestAttachmentBlobsIfNeeded(
                for: savedAttachments,
                in: result.context
            )
        }
        // Apply any mark messages that arrived from remote nodes.
        try await consumePendingMarks(in: result.context)
    }
}
