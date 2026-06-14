import Foundation
import MCP

/// The result ferried back through a continuation response. A blocking /
/// wake-assisted action (iOS forces blocking for all actions) can't use the
/// direct result path, so the continuation must carry EVERYTHING that path does:
/// the content PLUS the unified produced resources and any private output
/// transfers. Without this, a remote ask-for-file delivered only its text content
/// and the produced file's handle/identity was silently dropped.
struct KeepTalkingContinuationResult: Codable, Sendable {
    let content: [Tool.Content]
    let producedResources: [KTResourceManifest.AgentResource]?
    let outputTransfers: [KeepTalkingOneTimeBlobRef]?
}

/// Emitted the moment an agent turn suspends to wait on an out-of-band
/// continuation (a remote node's response, a local authorization bubble, an
/// ask-for-file pick). Lets a driver that can't block — e.g. the voice bridge —
/// detach: acknowledge now and let the turn finish in the background, with its
/// answer landing in the conversation as a normal message.
public struct KeepTalkingAgentTurnSuspension: Sendable {
    public let agentTurnID: UUID
    public let contextID: UUID
    /// The action kind that triggered the suspension (e.g. a primitive action
    /// raw value, "mcp", "skill", or the raw action id).
    public let kind: String
    /// The node that must respond before the turn can resume.
    public let targetNodeID: UUID

    public init(agentTurnID: UUID, contextID: UUID, kind: String, targetNodeID: UUID) {
        self.agentTurnID = agentTurnID
        self.contextID = contextID
        self.kind = kind
        self.targetNodeID = targetNodeID
    }
}

/// Emitted when a previously suspended agent turn resumes — its continuation was
/// answered (fulfilled or rejected) or an early response was already waiting.
/// Symmetric with `KeepTalkingAgentTurnSuspension`: a driver that detached on
/// suspend uses this to flip the run from "waiting" back to "running".
public struct KeepTalkingAgentTurnResumption: Sendable {
    public let agentTurnID: UUID
    public let contextID: UUID

    public init(agentTurnID: UUID, contextID: UUID) {
        self.agentTurnID = agentTurnID
        self.contextID = contextID
    }
}

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
        await agentCoordinator.deliverContinuationResponse(response)
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
            guard
                case .agentTurnContinuation(
                    let toolCallID, let actionID, let targetNodeID, let kind,
                    let encryptedPayload, let state
                ) = message.type, state == .pending
            else { continue }

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
        guard
            let messages = try? await KeepTalkingContextMessage.query(on: localStore.database)
                .all()
        else { return }

        for message in messages {
            guard
                case .agentTurnContinuation(
                    let toolCallID, let actionID, let targetNodeID, let kind,
                    let encryptedPayload, let state
                ) = message.type,
                state == .pending,
                case .node(let senderID) = message.sender,
                senderID == config.node,
                let turnID = message.agentTurnID
            else { continue }

            let isActive = await agentCoordinator.hasActiveTurn(agentTurnID: turnID)
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
        resultContent: [Tool.Content] = [],
        producedResources: [KTResourceManifest.AgentResource]? = nil,
        outputTransfers: [KeepTalkingOneTimeBlobRef]? = nil
    ) async throws {
        // Carry the FULL result (content + produced resources + output transfers)
        // so a blocking action delivers everything the direct path does.
        let encodedContent = try JSONEncoder().encode(
            KeepTalkingContinuationResult(
                content: resultContent,
                producedResources: producedResources,
                outputTransfers: outputTransfers))
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

    /// Fulfils a pending continuation by executing its original action call locally.
    /// This is used when a user approves a blocking authorisation bubble in the chat.
    public func fulfilAgentTurnContinuation(
        continuationMessageID: UUID
    ) async throws {
        // 1. Find the message
        guard
            let message = try await KeepTalkingContextMessage.query(on: localStore.database)
                .filter(\.$id, .equal, continuationMessageID)
                .first(),
            case .agentTurnContinuation(
                _, _, let targetNodeID,
                _, let encryptedPayload, let state
            ) = message.type,
            state == .pending
        else {
            throw KeepTalkingClientError.invalidContinuationMessage
        }

        let selfNodeID = config.node
        guard targetNodeID == selfNodeID, let originNodeID = message.sender.nodeID else {
            throw KeepTalkingClientError.notAuthorized
        }

        // Mark fulfilled immediately on the local node so the UI reflects the
        // response without waiting for decrypt + execute to complete.
        await updateContinuationMessageState(
            continuationMessageID: continuationMessageID,
            state: .fulfilled
        )

        // 2. Decrypt ActionCallRequest
        let cipher = KeepTalkingAsymmetricCipherEnvelope(
            senderNodeID: originNodeID,
            recipientNodeID: selfNodeID,
            ciphertext: encryptedPayload
        )
        let request = try await decryptActionCallRequestEnvelope(cipher)

        // 3. Execute locally
        // Load the correct context instance from our client state
        let contextID = request.contextID
        let context = try await upsertContext(KeepTalkingContext(id: contextID))
        let result = await executeActionCallRequest(request, context: context)
        await runPrimitiveActionPostResultHookIfNeeded(
            actionID: request.call.action,
            call: request.call,
            result: result
        )

        // 4. Respond back to origin
        try await respondToAgentTurnContinuation(
            continuationMessageID: continuationMessageID,
            agentTurnID: message.agentTurnID ?? UUID(),
            originNodeID: originNodeID,
            state: result.isError ? .rejected : .fulfilled,
            resultContent: result.content,
            producedResources: result.producedResources,
            outputTransfers: result.outputTransfers
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
    ) async throws -> KeepTalkingContinuationResult {
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

        // Tell any non-blocking driver (e.g. the voice bridge) that this turn is
        // now parked on an external response, so it can acknowledge and detach
        // instead of waiting out the whole continuation on a possibly-doomed
        // voice session.
        onAgentTurnSuspended?(
            KeepTalkingAgentTurnSuspension(
                agentTurnID: agentTurnID,
                contextID: contextID,
                kind: kind,
                targetNodeID: targetNodeID
            )
        )

        let response = try await agentCoordinator.awaitContinuation(
            agentTurnID: agentTurnID,
            contextID: contextID
        )

        // Mirror `onAgentTurnSuspended`: the turn is no longer parked — it is
        // running again regardless of whether the continuation was fulfilled or
        // rejected. A detached driver flips its run's UI back to "running" here.
        // (Cancellation throws out of `awaitContinuation` above, so this only
        // fires on a genuine resume — the cancelled task unwinds separately.)
        onAgentTurnResumed?(
            KeepTalkingAgentTurnResumption(
                agentTurnID: agentTurnID,
                contextID: contextID
            )
        )

        guard response.state == .fulfilled else {
            return KeepTalkingContinuationResult(
                content: [], producedResources: nil, outputTransfers: nil)
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
        return try JSONDecoder().decode(
            KeepTalkingContinuationResult.self, from: decryptedData)
    }
}
