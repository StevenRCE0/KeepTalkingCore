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

            Task.detached(priority: .background) { [self] in
                if config.recentAttachmentSyncLookback > 0 {
                    try await requestRecentMissingAttachmentBlobs(
                        in: contextID,
                        since: Date(
                            timeIntervalSinceNow: -config
                                .recentAttachmentSyncLookback
                        )
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
            pendingContextSyncSummaries.removeAll()
            pendingContextSyncMessages.removeAll()
            for continuation in summaries.values {
                continuation.resume(throwing: error)
            }
            for continuation in messages.values {
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
        guard !savedAttachments.isEmpty else {
            return
        }
        try await requestAttachmentBlobsIfNeeded(
            for: savedAttachments,
            in: result.context
        )
    }
}
