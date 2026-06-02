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

            // Messages: the shared summary→tail→chunk reconcile (see runSyncReconcile).
            try await runSyncReconcile(
                KeepTalkingSyncReconcile(
                    localSummary: {
                        try await self.contextSyncSnapshot(for: contextID).summary
                    },
                    remoteSummary: {
                        try await self.dispatchContextSyncSummaryRequest(
                            to: node, in: context
                        ).summary
                    },
                    makeTail: { local, remote in
                        KeepTalkingContextSyncTailRequest(
                            context: contextID, requester: self.config.node,
                            recipient: node, local: local, remote: remote
                        )
                    },
                    dispatchTail: { try await self.dispatchContextSyncTailRequest($0) },
                    makeChunk: { local, remote in
                        KeepTalkingContextSyncChunkRequest(
                            context: contextID, requester: self.config.node,
                            recipient: node, local: local, remote: remote
                        )
                    },
                    dispatchChunk: { try await self.dispatchContextSyncChunkRequest($0) },
                    persist: { try await self.persistContextSyncMessagesResult($0) }
                )
            )

            // Side notes use full-sync semantics: pull the entire set from the
            // peer and merge by `(key, updatedAt)`. Transparently chunked at the
            // transport layer, so there's no chunking decision to make here.
            let sideNotesResult = try await dispatchContextSyncSideNotesRequest(
                to: node,
                contextID: contextID
            )
            try await mergeSideNotes(
                sideNotesResult.sideNotes,
                contextID: contextID
            )

            // Attachment recovery is no longer nested here — it's a first-class
            // ContextMaintenance task (`recoverAttachments`).

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
            // Requests: respond if addressed to us (execute + send wrapped result).
            case .summaryRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncSummaryRequest,
                    wrap: { .summaryResult($0) })
            case .tailRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncTailRequest,
                    wrap: { .messagesResult($0) })
            case .chunkRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncChunkRequest,
                    wrap: { .messagesResult($0) })
            case .attachmentRecordsRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncAttachmentRecordsRequest,
                    wrap: { .attachmentRecordsResult($0) })
            case .sideNotesRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncSideNotesRequest,
                    wrap: { .sideNotesResult($0) })
            case .transcriptSummaryRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncTranscriptSummaryRequest,
                    wrap: { .transcriptSummaryResult($0) })
            case .transcriptTailRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncTranscriptTailRequest,
                    wrap: { .transcriptLinesResult($0) })
            case .transcriptChunkRequest(let request):
                try await respond(
                    to: request, recipient: request.recipient,
                    execute: executeContextSyncTranscriptChunkRequest,
                    wrap: { .transcriptLinesResult($0) })

            // Results: hand off to the matching registry's waiter.
            case .summaryResult(let result):
                guard result.requester == config.node else { return }
                syncSummaries.resolve(result.request, with: result)
            case .messagesResult(let result):
                guard result.requester == config.node else { return }
                syncMessages.resolve(result.request, with: result)
            case .sideNotesResult(let result):
                guard result.requester == config.node else { return }
                syncSideNotes.resolve(result.request, with: result)
            case .transcriptSummaryResult(let result):
                guard result.requester == config.node else { return }
                syncTranscriptSummaries.resolve(result.request, with: result)
            case .transcriptLinesResult(let result):
                guard result.requester == config.node else { return }
                syncTranscriptLines.resolve(result.request, with: result)

            // Attachments don't follow the request→result-waiter shape: blob
            // requests are answered out-of-band, records results persist on arrival.
            case .attachmentRequest(let request):
                guard request.requester != config.node else { return }
                try await respondToContextSyncAttachmentRequest(request)
            case .attachmentRecordsResult(let result):
                guard result.requester == config.node else { return }
                try await persistContextSyncAttachmentRecordsResult(result)
        }
    }

    /// Responder boilerplate shared by every request arm: ignore requests not
    /// addressed to us, otherwise execute and send back the wrapped result.
    private func respond<Request, Result>(
        to request: Request,
        recipient: UUID,
        execute: (Request) async throws -> Result,
        wrap: (Result) -> KeepTalkingContextSyncEnvelope
    ) async throws {
        guard recipient == config.node else { return }
        try rtcClient.sendEnvelope(wrap(try await execute(request)))
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

        return try await syncSummaries.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
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

        return try await syncMessages.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
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
        return try await syncSideNotes.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
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

        return try await syncMessages.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.chunkRequest(request)
                )
            }
        )
    }

    /// Fail every in-flight sync request across all resources — on disconnect.
    func failAllPendingContextSync(error: Error) {
        syncSummaries.failAll(error: error)
        syncMessages.failAll(error: error)
        syncSideNotes.failAll(error: error)
        syncTranscriptSummaries.failAll(error: error)
        syncTranscriptLines.failAll(error: error)
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
        let messages = snapshot.items(after: request.senders)
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
        let messages = snapshot.items(in: request.chunks)
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
