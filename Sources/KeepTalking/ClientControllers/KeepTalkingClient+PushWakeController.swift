import FluentKit
import Foundation

extension KeepTalkingClient {
    func sendContextWakeNotificationsIfNeeded(
        for context: KeepTalkingContext,
        messagePreview: KeepTalkingPushWakeMessagePreview?
    ) async {
        guard
            let kvService = kvService as? KeepTalkingPassKVService,
            let messagePreview,
            let envelope = try? await encryptedContextWakeEnvelope(
                contextID: try context.requireID(),
                preview: messagePreview
            )
        else {
            return
        }

        let relations =
            (try? await KeepTalkingNodeRelation.query(
                on: localStore.database
            )
            .filter(\.$from.$id, .equal, config.node)
            .all()) ?? []

        for relation in relations where relation.relationship.allows(context: context) {
            let nodeID = relation.$to.id
            guard nodeID != config.node, !isNodeOnline(nodeID) else {
                continue
            }
            guard
                let remoteNode = try? await KeepTalkingNode.query(
                    on: localStore.database
                )
                .filter(\.$id, .equal, nodeID)
                .first(),
                let handles = remoteNode.contextWakeHandles?
                    .filter({
                        $0.purpose == .contextMessage
                            && $0.contextID == context.id
                    }),
                !handles.isEmpty
            else {
                continue
            }

            for handle in handles {
                do {
                    _ = try await kvService.sendPushWake(
                        handle: handle,
                        contextEnvelope: envelope
                    )
                } catch {
                    onLog?(
                        "[push-wake][context] failed node=\(nodeID.uuidString.lowercased()) error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func sendActionWakeIfNeeded(
        actionOwner: UUID,
        call: KeepTalkingActionCall,
        context: KeepTalkingContext
    ) async {
        guard let kvService = kvService as? KeepTalkingPassKVService else {
            return
        }

        //        guard !isNodeOnline(actionOwner) else {
        //            return
        //        }

        guard
            let action = try? await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$id, .equal, call.action)
                .first(),
            action.blockingAuthorisation == true
        else {
            return
        }

        let relation = try? await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$to.$id, .equal, actionOwner)
        .first()
        guard let relationID = relation?.id else {
            return
        }

        guard
            let relationAction =
                try? await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$relation.$id, .equal, relationID)
                .filter(\.$action.$id, .equal, call.action)
                .first(),
            let wakeHandles = relationAction.wakeHandles,
            !wakeHandles.isEmpty
        else {
            return
        }

        let payload = KeepTalkingPushWakeActionPayload(
            contextID: (try? context.requireID()) ?? context.id ?? UUID(),
            senderNodeID: config.node,
            actionID: call.action
        )
        guard
            let envelope = try? await encryptPushWakeActionPayload(payload)
        else {
            return
        }

        for handle in wakeHandles {
            do {
                _ = try await kvService.sendPushWake(
                    handle: handle,
                    actionEnvelope: envelope
                )
            } catch {
                onLog?(
                    "[push-wake][action] failed node=\(actionOwner.uuidString.lowercased()) action=\(call.action.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    func waitForNodeToComeOnline(
        _ nodeID: UUID,
        timeoutSeconds: TimeInterval = 60
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !isNodeOnline(nodeID) && Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func encryptedContextWakeEnvelope(
        contextID: UUID,
        preview: KeepTalkingPushWakeMessagePreview
    ) async throws -> KeepTalkingPushWakeContextEnvelope {
        let secret = try await ensureGroupChatSecret(for: contextID)
        let encoded = try JSONEncoder().encode(preview)
        let ciphertext = try KeepTalkingPreviewCrypto.encryptString(
            String(decoding: encoded, as: UTF8.self),
            secret: secret
        )
        return KeepTalkingPushWakeContextEnvelope(
            contextID: contextID,
            ciphertext: ciphertext
        )
    }

    func encryptPushWakeActionPayload(
        _ payload: KeepTalkingPushWakeActionPayload
    ) async throws -> KeepTalkingPushWakeActionEnvelope {
        let secret = try await ensureGroupChatSecret(for: payload.contextID)
        return try KeepTalkingPushWakeActionEnvelope.encrypt(
            payload,
            secret: secret
        )
    }

    public func decryptPushWakeActionPayload(
        _ envelope: KeepTalkingPushWakeActionEnvelope
    ) async throws -> KeepTalkingPushWakeActionPayload {
        guard let secret = try await loadGroupChatSecret(for: envelope.contextID)
        else {
            throw KeepTalkingClientError.missingContextSecret(envelope.contextID)
        }
        return try envelope.decrypt(secret: secret)
    }
}
