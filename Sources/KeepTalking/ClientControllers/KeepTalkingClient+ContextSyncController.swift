import FluentKit
import Foundation

extension KeepTalkingClient {
    private static let contextSyncResultTimeoutSeconds: TimeInterval = 15

    func syncCurrentContext(with node: UUID, generation: UInt64) async {
        guard
            node != config.node,
            isConnectionLifecycleActive(generation)
        else { return }
        await contextSyncSingleFlight.run(
            for: node,
            generation: generation
        ) { [weak self] in
            guard self?.isConnectionLifecycleActive(generation) == true else {
                return
            }
            await self?.performContextSync(
                with: node,
                generation: generation
            )
        }
    }

    private func performContextSync(
        with node: UUID,
        generation: UInt64
    ) async {
        let syncID = UUID()
        let contextID = config.contextID
        await notifyContextSync(
            KeepTalkingContextSyncEvent(
                syncID: syncID,
                contextID: contextID,
                peerID: node,
                phase: .started
            )
        )
        do {
            let context = try await ensure(
                contextID,
                for: KeepTalkingContext.self,
                strict: true
            )
            let persistedContextID = try context.requireID()

            // Messages: the shared summary→tail→chunk reconcile (see runSyncReconcile).
            try await runSyncReconcile(
                KeepTalkingSyncReconcile(
                    localSummary: {
                        try await self.contextSyncSnapshot(for: persistedContextID).summary
                    },
                    remoteSummary: {
                        let result = try await self.dispatchContextSyncSummaryRequest(
                            to: node,
                            in: context,
                            generation: generation
                        )
                        if let notes = result.sideNotes,
                            try await self.mergeSideNotes(
                                notes, contextID: persistedContextID)
                        {
                            await self.notifySideNotesChanged(persistedContextID)
                        }
                        return result.summary
                    },
                    makeTail: { local, remote in
                        KeepTalkingContextSyncTailRequest(
                            context: persistedContextID, requester: self.config.node,
                            recipient: node, local: local,
                            remote: remote
                        )
                    },
                    dispatchTail: {
                        try await self.dispatchContextSyncTailRequest(
                            $0,
                            generation: generation
                        )
                    },
                    makeChunk: { local, remote in
                        KeepTalkingContextSyncChunkRequest(
                            context: persistedContextID, requester: self.config.node,
                            recipient: node, local: local,
                            remote: remote
                        )
                    },
                    dispatchChunk: {
                        try await self.dispatchContextSyncChunkRequest(
                            $0,
                            generation: generation
                        )
                    },
                    persist: { result in
                        try await self.persistContextSyncMessagesResult(result)
                        let messageIDs = result.messages.compactMap(\.id)
                        guard !messageIDs.isEmpty else { return }
                        await self.notifyContextSync(
                            KeepTalkingContextSyncEvent(
                                syncID: syncID,
                                contextID: persistedContextID,
                                peerID: node,
                                phase: .messagesApplied(messageIDs)
                            )
                        )
                    }
                )
            )

            // Attachment recovery is no longer nested here — it's a first-class
            // ContextMaintenance task (`recoverAttachments`).

            guard isConnectionLifecycleActive(generation) else {
                throw KeepTalkingClientError.clientDisconnected
            }
            rtcClient.debug(
                "context sync complete peer=\(node.uuidString.lowercased()) context=\(persistedContextID.uuidString.lowercased())"
            )
            await notifyContextSync(
                KeepTalkingContextSyncEvent(
                    syncID: syncID,
                    contextID: persistedContextID,
                    peerID: node,
                    phase: .completed
                )
            )
        } catch {
            rtcClient.debug(
                "context sync failed peer=\(node.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            await notifyContextSync(
                KeepTalkingContextSyncEvent(
                    syncID: syncID,
                    contextID: contextID,
                    peerID: node,
                    phase: .failed(error.localizedDescription)
                )
            )
        }
    }

    func handleIncomingContextSyncEnvelope(
        _ envelope: KeepTalkingContextSyncEnvelope
    ) async throws {
        switch envelope {
            // Side-note push: broadcast, so ignore our own echo.
            case .sideNotesPush(let push):
                guard push.origin != config.node else { return }
                if try await mergeSideNotes(
                    push.sideNotes, contextID: push.context)
                {
                    await notifySideNotesChanged(push.context)
                }

            // Requests: respond if addressed to us (execute + send wrapped result).
            case .summaryRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncSummaryRequest,
                    wrap: { .summaryResult($0) })
            case .tailRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncTailRequest,
                    wrap: { .messagesResult($0) })
            case .chunkRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncChunkRequest,
                    wrap: { .messagesResult($0) })
            case .attachmentRecordsRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncAttachmentRecordsRequest,
                    wrap: { .attachmentRecordsResult($0) })
            case .transcriptSummaryRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncTranscriptSummaryRequest,
                    wrap: { .transcriptSummaryResult($0) })
            case .transcriptTailRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncTranscriptTailRequest,
                    wrap: { .transcriptLinesResult($0) })
            case .transcriptChunkRequest(let request):
                try await respond(
                    to: request,
                    execute: executeContextSyncTranscriptChunkRequest,
                    wrap: { .transcriptLinesResult($0) })

            // Results: hand off to the matching registry's waiter.
            case .summaryResult(let result):
                guard result.requester == config.node else { return }
                syncSummaries.resolve(result.request, with: result)
            case .messagesResult(let result):
                guard result.requester == config.node else { return }
                syncMessages.resolve(result.request, with: result)
            case .transcriptSummaryResult(let result):
                guard result.requester == config.node else { return }
                syncTranscriptSummaries.resolve(result.request, with: result)
            case .transcriptLinesResult(let result):
                guard result.requester == config.node else { return }
                syncTranscriptLines.resolve(result.request, with: result)
            case .failureResult(let result):
                guard result.requester == config.node else { return }
                let error = KeepTalkingClientError.contextSyncRemoteFailure(
                    requestID: result.request,
                    responder: result.responder,
                    message: result.message
                )
                let handled = [
                    syncSummaries.fail(result.request, error: error),
                    syncMessages.fail(result.request, error: error),
                    syncTranscriptSummaries.fail(result.request, error: error),
                    syncTranscriptLines.fail(result.request, error: error),
                ].contains(true)
                guard !handled else { return }
                rtcClient.debug(
                    "unmatched context sync failure request=\(result.request.uuidString.lowercased()) peer=\(result.responder.uuidString.lowercased()) error=\(result.message)"
                )

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
    private func respond<Request: KeepTalkingContextSyncDirectedRequest, Result>(
        to request: Request,
        execute: (Request) async throws -> Result,
        wrap: (Result) -> KeepTalkingContextSyncEnvelope
    ) async throws {
        guard request.recipient == config.node else { return }
        do {
            try rtcClient.sendEnvelope(wrap(try await execute(request)))
        } catch {
            try rtcClient.sendEnvelope(
                KeepTalkingContextSyncEnvelope.failureResult(
                    KeepTalkingContextSyncFailureResult(
                        request: request.request,
                        context: request.context,
                        requester: request.requester,
                        responder: config.node,
                        message: error.localizedDescription
                    )
                )
            )
        }
    }

    func dispatchContextSyncSummaryRequest(
        to node: UUID,
        in context: KeepTalkingContext,
        generation: UInt64? = nil
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        let contextID = try context.requireID()
        let request = KeepTalkingContextSyncSummaryRequest(
            context: contextID,
            requester: config.node,
            recipient: node,
            // Computed here rather than by the caller so no dispatch site can
            // forget it and silently disable side-note sync.
            sideNoteDigest: try await sideNoteDigest(in: contextID)
        )

        if node == config.node {
            return try await executeContextSyncSummaryRequest(request)
        }
        guard let generation else {
            throw KeepTalkingClientError.clientDisconnected
        }

        return try await syncSummaries.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
            generation: generation,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.summaryRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncTailRequest(
        _ request: KeepTalkingContextSyncTailRequest,
        generation: UInt64? = nil
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        if request.recipient == config.node {
            return try await executeContextSyncTailRequest(request)
        }
        guard let generation else {
            throw KeepTalkingClientError.clientDisconnected
        }

        return try await syncMessages.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
            generation: generation,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.tailRequest(request)
                )
            }
        )
    }

    func dispatchContextSyncChunkRequest(
        _ request: KeepTalkingContextSyncChunkRequest,
        generation: UInt64? = nil
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        if request.recipient == config.node {
            return try await executeContextSyncChunkRequest(request)
        }
        guard let generation else {
            throw KeepTalkingClientError.clientDisconnected
        }

        return try await syncMessages.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
            generation: generation,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(
                    KeepTalkingContextSyncEnvelope.chunkRequest(request)
                )
            }
        )
    }

    func openContextSyncRequests(generation: UInt64) {
        syncSummaries.open(generation: generation)
        syncMessages.open(generation: generation)
        syncTranscriptSummaries.open(generation: generation)
        syncTranscriptLines.open(generation: generation)
        contextSyncSingleFlight.open(generation: generation)
    }

    /// Close registration and fail every in-flight request — on disconnect.
    func failAllPendingContextSync(error: Error) {
        contextSyncSingleFlight.cancelAll()
        syncSummaries.close(error: error)
        syncMessages.close(error: error)
        syncTranscriptSummaries.close(error: error)
        syncTranscriptLines.close(error: error)
    }

    private func executeContextSyncSummaryRequest(
        _ request: KeepTalkingContextSyncSummaryRequest
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        // Side notes ride the summary exchange: attach our whole set only when
        // the requester's digest disagrees with ours. Matching digests cost
        // nothing beyond the 32 bytes already in the request.
        var sideNotes: [KeepTalkingSideNoteDTO]?
        let localDigest = try await sideNoteDigest(in: request.context)
        if request.sideNoteDigest != localDigest {
            let notes = try await allSideNoteDTOs(in: request.context)
            let encoded = (try? JSONEncoder().encode(notes))?.count ?? 0
            if encoded <= KeepTalkingSideNoteLimits.maximumEncodedBytes {
                sideNotes = notes
            } else {
                // Locally-originated writes cannot get here — they are bounded
                // by value, key and live count, with tombstones pruned to fit.
                // A peer on different limits can still push us over, though, so
                // this is a real branch rather than an impossible one, and it
                // must not assert on what is ultimately external input.
                //
                // Refusing still beats pushing the summary result past the
                // transport limit and breaking MESSAGE sync for this peer too.
                // But it is worth shouting about: the requester cannot tell "no
                // notes because we agree" from "no notes because I refused", so
                // side notes simply stop converging with no other signal.
                onLog?(
                    "[sync] BUG: side-note set is \(encoded)B, over the \(KeepTalkingSideNoteLimits.maximumEncodedBytes)B budget; not attaching — side notes will not converge for this peer"
                )
            }
        }
        return KeepTalkingContextSyncSummaryResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            summary: snapshot.summary,
            sideNotes: sideNotes
        )
    }

    private func executeContextSyncTailRequest(
        _ request: KeepTalkingContextSyncTailRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        let page = snapshot.items(
            after: request.senders,
            before: request.before
        )
        return KeepTalkingContextSyncMessagesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            messages: page.items,
            attachments: snapshot.attachments(for: page.items),
            nextBefore: page.nextBefore
        )
    }

    private func executeContextSyncChunkRequest(
        _ request: KeepTalkingContextSyncChunkRequest
    ) async throws -> KeepTalkingContextSyncMessagesResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        let page = snapshot.items(
            in: request.chunks,
            before: request.before
        )
        return KeepTalkingContextSyncMessagesResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            messages: page.items,
            attachments: snapshot.attachments(for: page.items),
            nextBefore: page.nextBefore
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
