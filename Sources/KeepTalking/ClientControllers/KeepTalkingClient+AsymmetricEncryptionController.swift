import CryptoKit
import FluentKit
import Foundation

extension KeepTalkingClient {
    private struct LocalKeyAgreementMaterial {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let privateKeyBase64: String
        let publicKeyBase64: String
    }

    private struct RemotePublicKeyCandidate {
        let relationID: UUID
        let createdAt: Date
        let publicKeyBase64: String
        let publicKey: Curve25519.KeyAgreement.PublicKey
    }

    func encryptActionCallRequestEnvelope(
        _ request: KeepTalkingActionCallRequest
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(request)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: request.targetNodeID,
            purpose: "action-call-request"
        )
    }

    func decryptActionCallRequestEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingActionCallRequest {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "action-call-request"
        )
        let request = try JSONDecoder().decode(
            KeepTalkingActionCallRequest.self,
            from: payload
        )
        guard
            request.callerNodeID == envelope.senderNodeID,
            request.targetNodeID == envelope.recipientNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        return request
    }

    func encryptActionCallResultEnvelope(
        _ result: KeepTalkingActionCallResult
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(result)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: result.callerNodeID,
            purpose: "action-call-result"
        )
    }

    func decryptActionCallResultEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingActionCallResult {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "action-call-result"
        )
        let result = try JSONDecoder().decode(
            KeepTalkingActionCallResult.self,
            from: payload
        )
        guard
            result.callerNodeID == envelope.recipientNodeID,
            result.targetNodeID == envelope.senderNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        return result
    }

    func asymmetricPublicKeysForRecipient(nodeID: UUID) async throws
        -> (localPublicKey: String, remotePublicKey: String, relationID: UUID)?
    {
        let localKeyMaterial = try await localKeyAgreementMaterial()
        guard let remoteCandidate = try await remoteKeyAgreementPublicKeys(
            nodeID: nodeID
        ).first else {
            return nil
        }
        return (
            localPublicKey: localKeyMaterial.publicKeyBase64,
            remotePublicKey: remoteCandidate.publicKeyBase64,
            relationID: remoteCandidate.relationID
        )
    }

    func encryptAsymmetricPayload(
        _ payload: Data,
        recipientNodeID: UUID,
        purpose: String
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let localKeyMaterial = try await localKeyAgreementMaterial()
        let recipientCandidate = try await remoteKeyAgreementPublicKeys(
            nodeID: recipientNodeID
        ).first
        guard let recipientCandidate else {
            throw KeepTalkingClientError.remoteIdentityPublicKeyMissing(
                recipientNodeID
            )
        }

        rtcClient.debug(
            "[asym.encrypt] purpose=\(purpose) sender=\(config.node.uuidString.lowercased()) recipient=\(recipientNodeID.uuidString.lowercased()) localPublicKey=\(localKeyMaterial.publicKeyBase64) localPrivateKey=\(localKeyMaterial.privateKeyBase64) remotePublicKey=\(recipientCandidate.publicKeyBase64) relation=\(recipientCandidate.relationID.uuidString.lowercased()) payloadBytes=\(payload.count)"
        )

        let sharedSecret = try localKeyMaterial.privateKey.sharedSecretFromKeyAgreement(
            with: recipientCandidate.publicKey
        )
        let symmetricKey = asymmetricEnvelopeSymmetricKey(from: sharedSecret)
        let sealed = try AES.GCM.seal(payload, using: symmetricKey)
        guard let ciphertext = sealed.combined else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        return KeepTalkingAsymmetricCipherEnvelope(
            senderNodeID: config.node,
            recipientNodeID: recipientNodeID,
            ciphertext: ciphertext
        )
    }

    func decryptAsymmetricPayload(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope,
        expectedSenderNodeID: UUID,
        purpose: String
    ) async throws -> Data {
        guard envelope.recipientNodeID == config.node else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        guard envelope.senderNodeID == expectedSenderNodeID else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }

        let localKeyMaterial = try await localKeyAgreementMaterial()
        let senderPublicKeys = try await remoteKeyAgreementPublicKeys(
            nodeID: envelope.senderNodeID
        )
        let sealed = try AES.GCM.SealedBox(combined: envelope.ciphertext)

        for (index, senderCandidate) in senderPublicKeys.enumerated() {
            rtcClient.debug(
                "[asym.decrypt] purpose=\(purpose) sender=\(envelope.senderNodeID.uuidString.lowercased()) recipient=\(envelope.recipientNodeID.uuidString.lowercased()) localPublicKey=\(localKeyMaterial.publicKeyBase64) localPrivateKey=\(localKeyMaterial.privateKeyBase64) remotePublicKey=\(senderCandidate.publicKeyBase64) relation=\(senderCandidate.relationID.uuidString.lowercased()) candidate=\(index + 1)/\(senderPublicKeys.count) cipherBytes=\(envelope.ciphertext.count)"
            )

            let sharedSecret = try localKeyMaterial.privateKey.sharedSecretFromKeyAgreement(
                with: senderCandidate.publicKey
            )
            let symmetricKey = asymmetricEnvelopeSymmetricKey(from: sharedSecret)
            if let decrypted = try? AES.GCM.open(sealed, using: symmetricKey) {
                rtcClient.debug(
                    "[asym.decrypt] success purpose=\(purpose) sender=\(envelope.senderNodeID.uuidString.lowercased()) relation=\(senderCandidate.relationID.uuidString.lowercased())"
                )
                return decrypted
            }
        }

        throw KeepTalkingClientError.remoteIdentityPublicKeyInvalid(
            envelope.senderNodeID
        )
    }

    private func asymmetricEnvelopeSymmetricKey(
        from sharedSecret: SharedSecret
    ) -> SymmetricKey {
        let salt = "kt-asym-envelope-v1".data(using: .utf8) ?? Data()
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    private func localKeyAgreementMaterial() async throws
        -> LocalKeyAgreementMaterial
    {
        let localIdentity = try await ensureLocalNodeSigningKeypair()
        guard
            let privateKeyData = localIdentity.privateKey,
            !privateKeyData.isEmpty
        else {
            throw KeepTalkingClientError.localIdentityPrivateKeyMissing
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: privateKeyData
        )
        let privateKeyBase64 = privateKeyData.base64EncodedString()
        let derivedPublicKeyBase64 = Data(privateKey.publicKey.rawRepresentation)
            .base64EncodedString()
        return LocalKeyAgreementMaterial(
            privateKey: privateKey,
            privateKeyBase64: privateKeyBase64,
            publicKeyBase64: derivedPublicKeyBase64
        )
    }

    private func remoteKeyAgreementPublicKeys(nodeID: UUID) async throws
        -> [RemotePublicKeyCandidate]
    {
        let relations = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$to.$id, .equal, nodeID)
        .all()
        let relationIDs = relations.compactMap(\.id)
        guard !relationIDs.isEmpty else {
            throw KeepTalkingClientError.remoteIdentityPublicKeyMissing(nodeID)
        }

        var orderedCandidates: [RemotePublicKeyCandidate] = []

        for relationID in relationIDs {
            let keys = try await KeepTalkingNodeIdentityKey.query(
                on: localStore.database
            )
            .filter(\.$relation.$id, .equal, relationID)
            .sort(\.$createdAt, .descending)
            .all()
            for key in keys {
                let privateKeyData = key.privateKey ?? Data()
                guard privateKeyData.isEmpty else {
                    continue
                }
                guard let publicKeyData = Data(base64Encoded: key.publicKey) else {
                    continue
                }
                if let publicKey = try? Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: publicKeyData
                ) {
                    orderedCandidates.append(
                        RemotePublicKeyCandidate(
                            relationID: relationID,
                            createdAt: key.createdAt ?? .distantPast,
                            publicKeyBase64: key.publicKey,
                            publicKey: publicKey
                        )
                    )
                }
            }
        }

        let sorted = orderedCandidates.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
        if sorted.isEmpty {
            throw KeepTalkingClientError.remoteIdentityPublicKeyInvalid(nodeID)
        }
        return sorted
    }
}
