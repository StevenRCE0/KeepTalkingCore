import FluentKit
import Foundation

extension KeepTalkingClient {
    /// Ids per revocation push; 48 seal to roughly 2.8 KB of payload, well
    /// under APNs' 4 KB cap.
    private static let maxPushWakeRevocationMessageIDs = 48

    func sendContextWakeNotificationsIfNeeded(
        for context: KeepTalkingContext,
        messagePreview: KeepTalkingPushWakeMessagePreview?
    ) async {
        guard
            let kvService = kvService as? KeepTalkingPassKVService,
            let messagePreview,
            let envelope = try? await encryptedContextWakeEnvelope(
                contextID: try context.requireID(),
                sealing: messagePreview
            )
        else {
            return
        }

        for (nodeID, handle) in await contextWakeHandles(for: context) {
            do {
                _ = try await kvService.sendPushWake(
                    handle: handle,
                    wake: .context(envelope: envelope)
                )
            } catch {
                onLog?(
                    "[push-wake][context] failed node=\(nodeID.uuidString.lowercased()) error=\(error.localizedDescription)"
                )
            }
        }
    }

    /// Takes back, on peers' devices, the notifications `messageIDs` raised.
    ///
    /// Only the deleting node sends it — nodes merging the tombstones don't —
    /// and it goes to every context wake handle, since this node can't know
    /// which devices a message's sender woke. The push is silent; the app
    /// removes whichever delivered notification names one of the ids. Best
    /// effort: a device that misses it clears the notification once the
    /// tombstones sync in.
    func sendContextWakeRevocationsIfNeeded(
        in contextID: UUID,
        messageIDs: [UUID]
    ) async {
        guard
            let kvService = kvService as? KeepTalkingPassKVService,
            !messageIDs.isEmpty,
            let context = try? await KeepTalkingContext.find(
                contextID,
                on: localStore.database
            )
        else {
            return
        }
        let handles = await contextWakeHandles(for: context)
        guard !handles.isEmpty else { return }

        for start in stride(
            from: 0,
            to: messageIDs.count,
            by: Self.maxPushWakeRevocationMessageIDs
        ) {
            let batch = Array(
                messageIDs[
                    start..<min(
                        start + Self.maxPushWakeRevocationMessageIDs,
                        messageIDs.count
                    )
                ]
            )
            guard
                let envelope = try? await encryptedContextWakeEnvelope(
                    contextID: contextID,
                    sealing: KeepTalkingPushWakeRevocation(messageIDs: batch)
                )
            else {
                // One batch failing to seal is no reason to drop the rest.
                onLog?(
                    "[push-wake][revoke] failed to seal context=\(contextID.uuidString.lowercased()) batch=\(start / Self.maxPushWakeRevocationMessageIDs)"
                )
                continue
            }
            for (nodeID, handle) in handles {
                do {
                    _ = try await kvService.sendPushWake(
                        handle: handle,
                        wake: .revocation(envelope: envelope)
                    )
                } catch {
                    onLog?(
                        "[push-wake][revoke] failed node=\(nodeID.uuidString.lowercased()) error=\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Every other node's wake handle for `context`, over relations that
    /// admit it.
    private func contextWakeHandles(
        for context: KeepTalkingContext
    ) async -> [(nodeID: UUID, handle: KeepTalkingPushWakeHandle)] {
        let relations =
            (try? await KeepTalkingNodeRelation.query(
                on: localStore.database
            )
            .filter(\.$from.$id, .equal, config.node)
            .all()) ?? []

        var targets: [(nodeID: UUID, handle: KeepTalkingPushWakeHandle)] = []
        for relation in relations where relation.relationship.allows(context: context) {
            let nodeID = relation.$to.id
            guard nodeID != config.node else {
                continue
            }
            guard
                let remoteNode = try? await KeepTalkingNode.query(
                    on: localStore.database
                )
                .filter(\.$id, .equal, nodeID)
                .first(),
                let handles = remoteNode.contextWakeHandles
            else {
                continue
            }
            targets +=
                handles
                .filter {
                    $0.purpose == .contextMessage
                        && $0.contextID == context.id
                }
                .map { (nodeID, $0) }
        }
        return targets
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
        .filter(\.$from.$id, .equal, actionOwner)
        .filter(\.$to.$id, .equal, config.node)
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
            let envelope = try? await encryptPushWakeActionPayload(
                payload,
                recipientNodeID: actionOwner
            )
        else {
            return
        }

        for handle in wakeHandles {
            do {
                _ = try await kvService.sendPushWake(
                    handle: handle,
                    wake: .action(envelope: envelope)
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
        sealing payload: some Encodable
    ) async throws -> KeepTalkingPushWakeContextEnvelope {
        let secret = try await ensureGroupChatSecret(for: contextID)
        let encoded = try JSONEncoder().encode(payload)
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
        _ payload: KeepTalkingPushWakeActionPayload,
        recipientNodeID: UUID
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(payload)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: recipientNodeID,
            purpose: "push-wake-action"
        )
    }

    public func decryptPushWakeActionPayload(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingPushWakeActionPayload {
        try await Self.decryptPushWakeActionPayload(
            envelope,
            localNodeID: config.node,
            remoteNodeID: envelope.senderNodeID,
            on: localStore.database,
            keychain: keychain
        )
    }

    public static func decryptPushWakeActionPayload(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope,
        localNodeID: UUID,
        remoteNodeID: UUID,
        on database: any Database,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> KeepTalkingPushWakeActionPayload {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: remoteNodeID,
            localNodeID: localNodeID,
            remoteNodeID: remoteNodeID,
            on: database,
            keychain: keychain,
            purpose: "push-wake-action"
        )
        return try JSONDecoder().decode(
            KeepTalkingPushWakeActionPayload.self,
            from: payload
        )
    }
}
