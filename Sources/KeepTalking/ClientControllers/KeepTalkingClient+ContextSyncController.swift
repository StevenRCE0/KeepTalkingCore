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
                        // Tombstones first: they delete rows, and the cursors
                        // below are computed from what is left.
                        try await self.absorbSummarySets(
                            result,
                            pages: .remote(self, generation: generation)
                        )
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

            try await threadAfterSync(in: persistedContextID)

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

    /// What a completed sync does to threading.
    ///
    /// Every page has landed, so this node now holds every turning point the
    /// peer holds and every message those name, plus any it marked itself
    /// that the peer hasn't pulled yet. Re-threading from that is at least as
    /// informed as the peer's own threading; taking the peer's word instead
    /// reopened the thread a newer local mark had closed.
    func threadAfterSync(in contextID: UUID) async throws {
        try await applyLocalTurningPointMarkThreading(in: contextID)
        try await consumePendingMarks(in: contextID)
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
            // Tombstone push: broadcast, so ignore our own echo.
            case .messageDeletionsPush(let push):
                guard push.origin != config.node else { return }
                try await mergeMessageDeletions(push.tombstones, contextID: push.context)

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
            case .sideNotesPageRequest(let request):
                try await respond(
                    to: request,
                    execute: executeSideNotesPageRequest,
                    wrap: { .sideNotesPageResult($0) })
            case .messageDeletionsPageRequest(let request):
                try await respond(
                    to: request,
                    execute: executeMessageDeletionsPageRequest,
                    wrap: { .messageDeletionsPageResult($0) })

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
            case .sideNotesPageResult(let result):
                guard result.requester == config.node else { return }
                syncSideNotePages.resolve(result.request, with: result)
            case .messageDeletionsPageResult(let result):
                guard result.requester == config.node else { return }
                syncMessageDeletionPages.resolve(result.request, with: result)
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
                    syncSideNotePages.fail(result.request, error: error),
                    syncMessageDeletionPages.fail(result.request, error: error),
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
            // forget them and silently disable side-note or deletion sync.
            sideNoteDigest: try await sideNoteDigest(in: contextID),
            messageDeletionDigest: try await messageDeletionDigest(in: contextID)
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
        syncSideNotePages.open(generation: generation)
        syncMessageDeletionPages.open(generation: generation)
        contextSyncSingleFlight.open(generation: generation)
    }

    /// Close registration and fail every in-flight request — on disconnect.
    func failAllPendingContextSync(error: Error) {
        contextSyncSingleFlight.cancelAll()
        syncSummaries.close(error: error)
        syncMessages.close(error: error)
        syncTranscriptSummaries.close(error: error)
        syncTranscriptLines.close(error: error)
        syncSideNotePages.close(error: error)
        syncMessageDeletionPages.close(error: error)
    }

    func executeContextSyncSummaryRequest(
        _ request: KeepTalkingContextSyncSummaryRequest
    ) async throws -> KeepTalkingContextSyncSummaryResult {
        let snapshot = try await contextSyncSnapshot(for: request.context)
        // Side notes and tombstones ride the summary exchange: send our whole
        // set only when the requester's digest disagrees with ours, so matching
        // digests cost nothing beyond the 32 bytes already in the request. The
        // set goes out paged — the first page here, the rest on request — since
        // transport never fragments an envelope.
        var sideNotes: (items: [KeepTalkingSideNoteDTO], nextBefore: KeepTalkingSideNotePageKey?)?
        if request.sideNoteDigest != (try await sideNoteDigest(in: request.context)) {
            sideNotes = try await sideNotesPage(in: request.context, before: nil)
        }
        let deletionDigest = try await messageDeletionDigest(in: request.context)
        var messageDeletions: (items: [KeepTalkingMessageTombstone], nextBefore: KeepTalkingContextSyncPageKey?)?
        if request.messageDeletionDigest != deletionDigest {
            messageDeletions = try await messageDeletionsPage(in: request.context, before: nil)
        }
        return KeepTalkingContextSyncSummaryResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            summary: snapshot.summary,
            sideNotes: sideNotes?.items,
            sideNotesNextBefore: sideNotes?.nextBefore,
            messageDeletions: messageDeletions?.items,
            messageDeletionsNextBefore: messageDeletions?.nextBefore,
            messageDeletionDigest: deletionDigest
        )
    }

    // MARK: - Whole-set pages

    private func sideNotesPage(
        in contextID: UUID,
        before: KeepTalkingSideNotePageKey?
    ) async throws -> (items: [KeepTalkingSideNoteDTO], nextBefore: KeepTalkingSideNotePageKey?) {
        KeepTalkingContextSyncPage.newestFirst(
            KeepTalkingSideNoteDigest.canonicallyOrdered(
                try await allSideNoteDTOs(in: contextID)),
            before: before,
            key: KeepTalkingSideNotePageKey.init
        )
    }

    private func messageDeletionsPage(
        in contextID: UUID,
        before: KeepTalkingContextSyncPageKey?
    ) async throws -> (items: [KeepTalkingMessageTombstone], nextBefore: KeepTalkingContextSyncPageKey?) {
        KeepTalkingContextSyncPage.newestFirst(
            try await messageTombstones(in: contextID).sorted { $0.pageKey < $1.pageKey },
            before: before,
            key: \.pageKey
        )
    }

    func executeSideNotesPageRequest(
        _ request: KeepTalkingContextSyncSideNotesPageRequest
    ) async throws -> KeepTalkingContextSyncSideNotesPageResult {
        let page = try await sideNotesPage(in: request.context, before: request.before)
        return .init(
            request: request.request, context: request.context,
            requester: request.requester, responder: config.node,
            items: page.items, nextBefore: page.nextBefore
        )
    }

    func executeMessageDeletionsPageRequest(
        _ request: KeepTalkingContextSyncMessageDeletionsPageRequest
    ) async throws -> KeepTalkingContextSyncMessageDeletionsPageResult {
        let page = try await messageDeletionsPage(in: request.context, before: request.before)
        return .init(
            request: request.request, context: request.context,
            requester: request.requester, responder: config.node,
            items: page.items, nextBefore: page.nextBefore
        )
    }

    fileprivate func setPageRequest<Cursor: Codable & Sendable & Comparable>(
        for result: KeepTalkingContextSyncSummaryResult,
        before: Cursor
    ) -> KeepTalkingContextSyncSetPageRequest<Cursor> {
        KeepTalkingContextSyncSetPageRequest(
            context: result.context,
            requester: config.node,
            recipient: result.responder,
            before: before
        )
    }

    func dispatchSideNotesPageRequest(
        _ request: KeepTalkingContextSyncSideNotesPageRequest,
        generation: UInt64? = nil
    ) async throws -> KeepTalkingContextSyncSideNotesPageResult {
        try await dispatchSetPageRequest(
            request, registry: syncSideNotePages, generation: generation,
            execute: executeSideNotesPageRequest,
            wrap: { .sideNotesPageRequest($0) })
    }

    func dispatchMessageDeletionsPageRequest(
        _ request: KeepTalkingContextSyncMessageDeletionsPageRequest,
        generation: UInt64? = nil
    ) async throws -> KeepTalkingContextSyncMessageDeletionsPageResult {
        try await dispatchSetPageRequest(
            request, registry: syncMessageDeletionPages, generation: generation,
            execute: executeMessageDeletionsPageRequest,
            wrap: { .messageDeletionsPageRequest($0) })
    }

    private func dispatchSetPageRequest<Cursor, Result: Sendable>(
        _ request: KeepTalkingContextSyncSetPageRequest<Cursor>,
        registry: KeepTalkingSyncResponseRegistry<Result>,
        generation: UInt64?,
        execute: (KeepTalkingContextSyncSetPageRequest<Cursor>) async throws -> Result,
        wrap: @escaping @Sendable (KeepTalkingContextSyncSetPageRequest<Cursor>) -> KeepTalkingContextSyncEnvelope
    ) async throws -> Result {
        if request.recipient == config.node {
            return try await execute(request)
        }
        guard let generation else {
            throw KeepTalkingClientError.clientDisconnected
        }
        return try await registry.response(
            for: request.request,
            timeout: Self.contextSyncResultTimeoutSeconds,
            generation: generation,
            send: { [weak self] in
                try self?.rtcClient.sendEnvelope(wrap(request))
            }
        )
    }

    /// Requester side: reassemble every whole set a summary result carried.
    ///
    /// Tombstones and side notes are merged here, each once and whole.
    func absorbSummarySets(
        _ result: KeepTalkingContextSyncSummaryResult,
        pages: KeepTalkingContextSyncSetPages
    ) async throws {
        if let firstPage = result.messageDeletions {
            let remote = try await collectSyncSetPages(
                firstPage: firstPage,
                nextBefore: result.messageDeletionsNextBefore,
                request: { self.setPageRequest(for: result, before: $0) },
                dispatch: pages.messageDeletions
            )
            try await mergeMessageDeletions(remote, contextID: result.context)

            // The responder sent its whole set, so whatever we hold beyond it is
            // exactly what it lacks. Push that now, so it stops serving those
            // rows back to us this round rather than one heartbeat later.
            if let responderDigest = result.messageDeletionDigest,
                responderDigest != (try await messageDeletionDigest(in: result.context))
            {
                let remoteIDs = Set(remote.map(\.messageID))
                let missing = try await messageTombstones(in: result.context)
                    .filter { !remoteIDs.contains($0.messageID) }
                publishMessageDeletions(missing, in: result.context)
            }
        }

        if let firstPage = result.sideNotes {
            let notes = try await collectSyncSetPages(
                firstPage: firstPage,
                nextBefore: result.sideNotesNextBefore,
                request: { self.setPageRequest(for: result, before: $0) },
                dispatch: pages.sideNotes
            )
            if try await mergeSideNotes(notes, contextID: result.context) {
                await notifySideNotesChanged(result.context)
            }
        }
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
        let attachmentDTOs: [KeepTalkingContextAttachmentDTO]
        if request.messageIDs.isEmpty {
            attachmentDTOs = []
        } else {
            let rows = try await KeepTalkingContextAttachment.query(
                on: localStore.database
            )
            .filter(\.$context.$id, .equal, request.context)
            .filter(\.$parentMessage.$id ~~ request.messageIDs)
            .all()
            attachmentDTOs = rows.compactMap(KeepTalkingContextAttachmentDTO.init)
        }
        return KeepTalkingContextSyncAttachmentRecordsResult(
            request: request.request,
            context: request.context,
            requester: request.requester,
            responder: config.node,
            attachments: attachmentDTOs
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
        // Marks are deliberately NOT consumed here. Pages arrive newest-first,
        // so mid-sync the local message list is a suffix of the context and the
        // spans between turning points would be wrong. The driver consumes once,
        // on completion.
    }
}

/// Where a requester fetches the pages after a whole set's first one.
///
/// `remote` goes over the transport to the summary's responder; tests point
/// these straight at another client's page executors instead.
struct KeepTalkingContextSyncSetPages: Sendable {
    let sideNotes:
        @Sendable (KeepTalkingContextSyncSideNotesPageRequest) async throws ->
            KeepTalkingContextSyncSideNotesPageResult
    let messageDeletions:
        @Sendable (KeepTalkingContextSyncMessageDeletionsPageRequest) async throws ->
            KeepTalkingContextSyncMessageDeletionsPageResult

    static func remote(_ client: KeepTalkingClient, generation: UInt64?) -> Self {
        Self(
            sideNotes: { try await client.dispatchSideNotesPageRequest($0, generation: generation) },
            messageDeletions: {
                try await client.dispatchMessageDeletionsPageRequest($0, generation: generation)
            }
        )
    }
}
