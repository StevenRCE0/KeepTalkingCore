import Foundation
import MCP

extension KeepTalkingClient {

    // MARK: - Incoming (A receives response from B)

    func handleIncomingAgentTurnContinuationResponse(
        _ response: KeepTalkingAgentTurnContinuationResponse
    ) async {
        guard response.originNodeID == config.node else { return }
        onLog?(
            "[continuation] received agentTurnID=\(response.agentTurnID.uuidString.lowercased()) state=\(response.state.rawValue) responder=\(response.responderNodeID.uuidString.lowercased())"
        )
        await updateContinuationMessageState(
            continuationMessageID: response.continuationMessageID,
            state: response.state
        )
        await agentRunQueue.deliverContinuationResponse(response)
    }

    private func updateContinuationMessageState(
        continuationMessageID: UUID,
        state: KeepTalkingContextMessage.AgentTurnContinuationState
    ) async {
        guard
            let message = try? await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$id, .equal, continuationMessageID)
                .first(),
            case .agentTurnContinuation(
                let toolCallID, let actionID, let targetNodeID, let kind, let encryptedPayload, _
            ) = message.type
        else { return }
        message.type = .agentTurnContinuation(
            toolCallID: toolCallID,
            actionID: actionID,
            targetNodeID: targetNodeID,
            kind: kind,
            encryptedPayload: encryptedPayload,
            state: state
        )
        try? await message.save(on: localStore.database)
        // Fire the local envelope sink so the UI refreshes from the updated DB row.
        // Each node updates its own copy independently — we don't broadcast, because
        // the message-sync dedup filter would drop the update on the remote side.
        onEnvelope?(message)
    }

    // MARK: - Blob sync wait

    /// For ask-for-file continuations, waits until all referenced blobs are locally
    /// available so the agent can immediately read files when its turn resumes.
    func waitForContinuationBlobs(
        from content: [Tool.Content],
        in contextID: UUID,
        timeout: Duration = .seconds(60)
    ) async {
        let blobIDs = blobIDsFromAskForFileContent(content)
        guard !blobIDs.isEmpty else { return }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let attachments = (try? await contextAttachments(in: contextID)) ?? []
            let matches = attachments.filter { blobIDs.contains($0.blobID) }
            if !matches.isEmpty {
                try? await requestAttachmentBlobsIfNeeded(for: matches, in: contextID)
            }
            let records = (try? await blobRecordsByBlobID(blobIDs)) ?? [:]
            if blobIDs.allSatisfy({ records[$0]?.availability == .ready }) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func blobIDsFromAskForFileContent(_ content: [Tool.Content]) -> [String] {
        for item in content {
            guard case .text(let text, _, _) = item,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "sent_to_context",
                  let attachments = json["attachments"] as? [[String: Any]]
            else { continue }
            return attachments.compactMap { $0["blob_id"] as? String }
        }
        return []
    }

    // MARK: - Stale continuation invalidation

    /// Marks all pending continuation messages for a specific turn as cancelled.
    /// Called when an agent run finishes (normally or via cancellation).
    func cancelStaleContinuations(agentTurnID: UUID, in contextID: UUID) async {
        guard
            let messages = try? await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$agentTurnID, .equal, agentTurnID)
                .all()
        else { return }

        for message in messages {
            guard message.$context.id == contextID else { continue }
            guard case .agentTurnContinuation(
                let toolCallID, let actionID, let targetNodeID, let kind,
                let encryptedPayload, let state
            ) = message.type, state == .pending else { continue }

            message.type = .agentTurnContinuation(
                toolCallID: toolCallID,
                actionID: actionID,
                targetNodeID: targetNodeID,
                kind: kind,
                encryptedPayload: encryptedPayload,
                state: .cancelled
            )
            try? await message.save(on: localStore.database)
            try? rtcClient.sendEnvelope(message)
        }
    }

    /// On connect, finds all pending continuation messages sent by this node
    /// and cancels any whose agent turn is no longer active in the queue.
    public func reconcileStaleContinuations() async {
        guard let messages = try? await KeepTalkingContextMessage.query(on: localStore.database)
            .all()
        else { return }

        for message in messages {
            guard case .agentTurnContinuation(
                let toolCallID, let actionID, let targetNodeID, let kind,
                let encryptedPayload, let state
            ) = message.type,
                state == .pending,
                case .node(let senderID) = message.sender,
                senderID == config.node,
                let turnID = message.agentTurnID
            else { continue }

            let isActive = await agentRunQueue.hasActiveTurn(agentTurnID: turnID)
            guard !isActive else { continue }

            message.type = .agentTurnContinuation(
                toolCallID: toolCallID,
                actionID: actionID,
                targetNodeID: targetNodeID,
                kind: kind,
                encryptedPayload: encryptedPayload,
                state: .cancelled
            )
            try? await message.save(on: localStore.database)
            try? rtcClient.sendEnvelope(message)
        }
    }

    // MARK: - Outgoing (B responds to A)

    /// Called by the app when the local user fulfils or rejects a continuation
    /// visible in the conversation.  `resultContent` is empty on rejection.
    public func respondToAgentTurnContinuation(
        continuationMessageID: UUID,
        agentTurnID: UUID,
        originNodeID: UUID,
        state: KeepTalkingContextMessage.AgentTurnContinuationState,
        resultContent: [Tool.Content] = []
    ) async throws {
        // Encrypt [Tool.Content] directly — no wrapper needed.
        let encodedContent = try JSONEncoder().encode(resultContent)
        let encryptedContent = try await encryptAsymmetricPayload(
            encodedContent,
            recipientNodeID: originNodeID,
            purpose: "agent-turn-continuation-result"
        )

        let response = KeepTalkingAgentTurnContinuationResponse(
            continuationMessageID: continuationMessageID,
            agentTurnID: agentTurnID,
            contextID: config.contextID,
            responderNodeID: config.node,
            originNodeID: originNodeID,
            state: state,
            encryptedPayload: encryptedContent.ciphertext
        )

        onLog?(
            "[continuation] sending response agentTurnID=\(agentTurnID.uuidString.lowercased()) state=\(state.rawValue) origin=\(originNodeID.uuidString.lowercased())"
        )

        // Update our own copy of the continuation message immediately so B's UI
        // reflects the new state without waiting for A to respond.
        await updateContinuationMessageState(
            continuationMessageID: continuationMessageID,
            state: state
        )

        try await rtcClient.sendTrustedEnvelope(
            response,
            cryptorSource: trustedEnvelopeCryptorSource()
        )
    }

    // MARK: - Suspension helper (called from dispatchActionCall)

    /// Posts the in-chat continuation message then suspends the agent turn until
    /// B's user responds.  Returns the decrypted `[Tool.Content]` from B.
    func suspendAgentTurnForContinuation(
        agentTurnID: UUID,
        toolCallID: String,
        actionID: UUID,
        targetNodeID: UUID,
        kind: String,
        encryptedPayload: Data,
        context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender
    ) async throws -> [Tool.Content] {
        let contextID = try context.requireID()

        let continuationMessage = KeepTalkingContextMessage(
            context: context,
            sender: sender,
            content: kind,
            type: .agentTurnContinuation(
                toolCallID: toolCallID,
                actionID: actionID,
                targetNodeID: targetNodeID,
                kind: kind,
                encryptedPayload: encryptedPayload,
                state: .pending
            ),
            agentTurnID: agentTurnID
        )
        try await continuationMessage.save(on: localStore.database)
        try rtcClient.sendEnvelope(continuationMessage)

        onLog?(
            "[continuation] suspended agentTurnID=\(agentTurnID.uuidString.lowercased()) action=\(actionID.uuidString.lowercased()) target=\(targetNodeID.uuidString.lowercased()) context=\(contextID.uuidString.lowercased())"
        )

        let response = try await agentRunQueue.awaitContinuation(agentTurnID: agentTurnID)

        guard response.state == .fulfilled else {
            return []
        }

        let cipher = KeepTalkingAsymmetricCipherEnvelope(
            senderNodeID: response.responderNodeID,
            recipientNodeID: config.node,
            ciphertext: response.encryptedPayload
        )
        let decryptedData = try await decryptAsymmetricPayload(
            cipher,
            expectedSenderNodeID: response.responderNodeID,
            purpose: "agent-turn-continuation-result"
        )
        return try JSONDecoder().decode([Tool.Content].self, from: decryptedData)
    }
}
