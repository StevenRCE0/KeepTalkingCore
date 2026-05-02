import CryptoKit
import FluentKit
import Foundation

extension KeepTalkingClient {
    struct LocalKeyAgreementMaterial {
        let relationID: UUID
        let createdAt: Date
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let privateKeyBase64: String
        let publicKeyBase64: String
    }

    struct RemotePublicKeyCandidate {
        let relationID: UUID
        let createdAt: Date
        let publicKeyBase64: String
        let publicKey: Curve25519.KeyAgreement.PublicKey
    }

    func trustedEnvelopeCryptorSource() -> KeepTalkingTrustedEnvelopeCryptorSource {
        { [weak self] envelope in
            guard let self else {
                throw KeepTalkingTrustedEnvelopeCryptorError.ownerUnavailable
            }
            return self.trustedEnvelopeCryptor(for: envelope)
        }
    }

    func trustedEnvelopeCryptor(for envelope: any KeepTalkingEnvelope)
        -> KeepTalkingTrustedEnvelopeCryptor?
    {
        switch envelope.kind {
            case .actionCallRequest, .encryptedActionCallRequest:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.actionCallRequest },
                    encrypted: { $0.encryptedActionCallRequest },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedActionCallRequestEnvelope.init,
                    encrypt: { [weak self] request in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .encryptActionCallRequestEnvelope(request)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .decryptActionCallRequestEnvelope(envelope)
                    }
                )
            case .requestAck, .encryptedRequestAck:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.requestAck },
                    encrypted: { $0.encryptedRequestAck },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedRequestAckEnvelope.init,
                    encrypt: { [weak self] acknowledgement in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .encryptRequestAckEnvelope(acknowledgement)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return try await self.decryptRequestAckEnvelope(envelope)
                    }
                )
            case .actionCallResult, .encryptedActionCallResult:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.actionCallResult },
                    encrypted: { $0.encryptedActionCallResult },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedActionCallResultEnvelope.init,
                    encrypt: { [weak self] result in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .encryptActionCallResultEnvelope(result)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .decryptActionCallResultEnvelope(envelope)
                    }
                )
            case .actionCatalogRequest, .encryptedActionCatalogRequest:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.actionCatalogRequest },
                    encrypted: { $0.encryptedActionCatalogRequest },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedActionCatalogRequestEnvelope.init,
                    encrypt: { [weak self] request in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .encryptActionCatalogRequestEnvelope(request)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .decryptActionCatalogRequestEnvelope(envelope)
                    }
                )
            case .actionCatalogResult, .encryptedActionCatalogResult:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.actionCatalogResult },
                    encrypted: { $0.encryptedActionCatalogResult },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedActionCatalogResultEnvelope.init,
                    encrypt: { [weak self] result in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .encryptActionCatalogResultEnvelope(result)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError
                                .ownerUnavailable
                        }
                        return
                            try await self
                            .decryptActionCatalogResultEnvelope(envelope)
                    }
                )
            case .encryptedAgentTurnContinuationResponse:
                return makeTrustedEnvelopeCryptor(
                    plaintext: { $0.agentTurnContinuationResponse },
                    encrypted: { $0.encryptedAgentTurnContinuationResponse },
                    wrapPlaintext: { $0 },
                    wrapEncrypted: KeepTalkingEncryptedAgentTurnContinuationResponseEnvelope.init,
                    encrypt: { [weak self] response in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError.ownerUnavailable
                        }
                        return try await self.encryptAgentTurnContinuationResponseEnvelope(response)
                    },
                    decrypt: { [weak self] envelope in
                        guard let self else {
                            throw KeepTalkingTrustedEnvelopeCryptorError.ownerUnavailable
                        }
                        return try await self.decryptAgentTurnContinuationResponseEnvelope(envelope)
                    }
                )
            default:
                return nil
        }
    }

    func decryptTrustedEnvelope(
        _ envelope: any KeepTalkingEnvelope
    ) async throws -> any KeepTalkingEnvelope {
        guard let cryptor = trustedEnvelopeCryptor(for: envelope) else {
            throw
                KeepTalkingTrustedEnvelopeCryptorError
                .missingCryptor(envelope.kind)
        }
        return try await cryptor.decrypt(envelope)
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

    func encryptRequestAckEnvelope(
        _ acknowledgement: KeepTalkingRequestAck
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(acknowledgement)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: acknowledgement.callerNodeID,
            purpose: "request-ack"
        )
    }

    func decryptRequestAckEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingRequestAck {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "request-ack"
        )
        let acknowledgement = try JSONDecoder().decode(
            KeepTalkingRequestAck.self,
            from: payload
        )
        guard
            acknowledgement.callerNodeID == envelope.recipientNodeID,
            acknowledgement.targetNodeID == envelope.senderNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedRequestAck
        }
        return acknowledgement
    }

    func encryptActionCatalogRequestEnvelope(
        _ request: KeepTalkingActionCatalogRequest
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(request)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: request.targetNodeID,
            purpose: "action-catalog-request"
        )
    }

    func decryptActionCatalogRequestEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingActionCatalogRequest {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "action-catalog-request"
        )
        let request = try JSONDecoder().decode(
            KeepTalkingActionCatalogRequest.self,
            from: payload
        )
        guard
            request.callerNodeID == envelope.senderNodeID,
            request.targetNodeID == envelope.recipientNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCatalog
        }
        return request
    }

    func encryptActionCatalogResultEnvelope(
        _ result: KeepTalkingActionCatalogResult
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(result)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: result.callerNodeID,
            purpose: "action-catalog-result"
        )
    }

    func decryptActionCatalogResultEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingActionCatalogResult {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "action-catalog-result"
        )
        let result = try JSONDecoder().decode(
            KeepTalkingActionCatalogResult.self,
            from: payload
        )
        guard
            result.callerNodeID == envelope.recipientNodeID,
            result.targetNodeID == envelope.senderNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCatalog
        }
        return result
    }

    func encryptAgentTurnContinuationResponseEnvelope(
        _ response: KeepTalkingAgentTurnContinuationResponse
    ) async throws -> KeepTalkingAsymmetricCipherEnvelope {
        let encoded = try JSONEncoder().encode(response)
        return try await encryptAsymmetricPayload(
            encoded,
            recipientNodeID: response.originNodeID,
            purpose: "agent-turn-continuation-response"
        )
    }

    func decryptAgentTurnContinuationResponseEnvelope(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope
    ) async throws -> KeepTalkingAgentTurnContinuationResponse {
        let payload = try await decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: envelope.senderNodeID,
            purpose: "agent-turn-continuation-response"
        )
        let response = try JSONDecoder().decode(
            KeepTalkingAgentTurnContinuationResponse.self,
            from: payload
        )
        guard
            response.responderNodeID == envelope.senderNodeID,
            response.originNodeID == envelope.recipientNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        return response
    }

    func asymmetricPublicKeysForRecipient(nodeID: UUID) async throws
        -> (localPublicKey: String, remotePublicKey: String, relationID: UUID)?
    {
        let node = try await ensure(nodeID, for: KeepTalkingNode.self)

        let localKeyMaterial = try await localKeyAgreementMaterial(to: node)
        guard
            let remoteCandidate = try await remoteKeyAgreementPublicKeys(
                nodeID: nodeID
            ).first
        else {
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
        let node = try await ensure(recipientNodeID, for: KeepTalkingNode.self)

        let localKeyMaterial = try await localKeyAgreementMaterial(to: node)
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
        let symmetricKey = Self.asymmetricEnvelopeSymmetricKey(
            from: sharedSecret
        )
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
        try await Self.decryptAsymmetricPayload(
            envelope,
            expectedSenderNodeID: expectedSenderNodeID,
            localNodeID: config.node,
            remoteNodeID: envelope.senderNodeID,
            on: localStore.database,
            keychain: keychain,
            purpose: purpose,
            debug: { [rtcClient] message in
                rtcClient.debug(message)
            }
        )
    }

    static func decryptAsymmetricPayload(
        _ envelope: KeepTalkingAsymmetricCipherEnvelope,
        expectedSenderNodeID: UUID,
        localNodeID: UUID,
        remoteNodeID: UUID,
        on database: any Database,
        keychain: any KeepTalkingKeychainStore,
        purpose: String,
        debug: ((String) -> Void)? = nil
    ) async throws -> Data {
        guard envelope.recipientNodeID == localNodeID else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }
        guard
            envelope.senderNodeID == expectedSenderNodeID,
            envelope.senderNodeID == remoteNodeID
        else {
            throw KeepTalkingClientError.malformedEncryptedActionCall
        }

        let localKeyMaterial = try await localKeyAgreementMaterial(
            localNodeID: localNodeID,
            remoteNodeID: remoteNodeID,
            on: database,
            keychain: keychain
        )
        let senderPublicKeys = try await remoteKeyAgreementPublicKeys(
            nodeID: remoteNodeID,
            localNodeID: localNodeID,
            on: database
        )
        let sealed = try AES.GCM.SealedBox(combined: envelope.ciphertext)

        for (index, senderCandidate) in senderPublicKeys.enumerated() {
            debug?(
                "[asym.decrypt] purpose=\(purpose) sender=\(envelope.senderNodeID.uuidString.lowercased()) recipient=\(envelope.recipientNodeID.uuidString.lowercased()) localPublicKey=\(localKeyMaterial.publicKeyBase64) localPrivateKey=\(localKeyMaterial.privateKeyBase64) remotePublicKey=\(senderCandidate.publicKeyBase64) relation=\(senderCandidate.relationID.uuidString.lowercased()) candidate=\(index + 1)/\(senderPublicKeys.count) cipherBytes=\(envelope.ciphertext.count)"
            )

            let sharedSecret = try localKeyMaterial.privateKey
                .sharedSecretFromKeyAgreement(with: senderCandidate.publicKey)
            let symmetricKey = asymmetricEnvelopeSymmetricKey(
                from: sharedSecret
            )
            if let decrypted = try? AES.GCM.open(sealed, using: symmetricKey) {
                debug?(
                    "[asym.decrypt] success purpose=\(purpose) sender=\(envelope.senderNodeID.uuidString.lowercased()) relation=\(senderCandidate.relationID.uuidString.lowercased())"
                )
                return decrypted
            }
        }

        throw KeepTalkingClientError.remoteIdentityPublicKeyInvalid(remoteNodeID)
    }

    private static func asymmetricEnvelopeSymmetricKey(
        from sharedSecret: SharedSecret
    ) -> SymmetricKey {
        derivedSymmetricKey(
            from: sharedSecret,
            salt: "kt-asym-envelope-v1".data(using: .utf8) ?? Data(),
            sharedInfo: Data()
        )
    }

    static func derivedSymmetricKey(
        from sharedSecret: SharedSecret,
        salt: Data,
        sharedInfo: Data
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )
    }

    func localKeyAgreementMaterial(to node: KeepTalkingNode) async throws
        -> LocalKeyAgreementMaterial
    {
        guard let nodeID = node.id else {
            throw KeepTalkingClientError.missingNode
        }
        return try await Self.localKeyAgreementMaterial(
            localNodeID: config.node,
            remoteNodeID: nodeID,
            on: localStore.database,
            keychain: keychain
        )
    }

    func localKeyAgreementMaterials(to node: KeepTalkingNode) async throws
        -> [LocalKeyAgreementMaterial]
    {
        guard let nodeID = node.id else {
            throw KeepTalkingClientError.missingNode
        }
        return try await Self.localKeyAgreementMaterials(
            localNodeID: config.node,
            remoteNodeID: nodeID,
            on: localStore.database,
            keychain: keychain
        )
    }

    static func localKeyAgreementMaterial(
        localNodeID: UUID,
        remoteNodeID: UUID,
        on database: any Database,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> LocalKeyAgreementMaterial {
        guard
            let material = try await localKeyAgreementMaterials(
                localNodeID: localNodeID,
                remoteNodeID: remoteNodeID,
                on: database,
                keychain: keychain
            ).first
        else {
            throw KeepTalkingClientError.localIdentityPrivateKeyMissing
        }
        return material
    }

    func remoteKeyAgreementPublicKeys(nodeID: UUID) async throws
        -> [RemotePublicKeyCandidate]
    {
        try await Self.remoteKeyAgreementPublicKeys(
            nodeID: nodeID,
            localNodeID: config.node,
            on: localStore.database
        )
    }

    static func localKeyAgreementMaterials(
        localNodeID: UUID,
        remoteNodeID: UUID,
        on database: any Database,
        keychain: any KeepTalkingKeychainStore
    ) async throws -> [LocalKeyAgreementMaterial] {
        let relations = try await KeepTalkingNodeRelation.query(on: database)
            .filter(\.$from.$id, .equal, localNodeID)
            .filter(\.$to.$id, .equal, remoteNodeID)
            .all()

        guard !relations.isEmpty else {
            throw KeepTalkingClientError.missingRelation
        }

        var materials: [LocalKeyAgreementMaterial] = []
        for relation in relations {
            guard let relationID = relation.id else {
                continue
            }
            let keypairs = try await KeepTalkingNodeIdentityKey.query(on: database)
                .filter(\.$relation.$id, .equal, relationID)
                .sort(\.$createdAt, .descending)
                .all()

            for key in keypairs {
                guard
                    let privateKeyData = try await keychain.get(
                        .nodeIdentityPriv(relationID: relationID)
                    ),
                    !privateKeyData.isEmpty
                else {
                    continue
                }
                let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: privateKeyData
                )
                let privateKeyBase64 = privateKeyData.base64EncodedString()
                let derivedPublicKeyBase64 = Data(
                    privateKey.publicKey.rawRepresentation
                ).base64EncodedString()
                materials.append(
                    LocalKeyAgreementMaterial(
                        relationID: relationID,
                        createdAt: key.createdAt ?? .distantPast,
                        privateKey: privateKey,
                        privateKeyBase64: privateKeyBase64,
                        publicKeyBase64: derivedPublicKeyBase64
                    )
                )
            }
        }

        materials.sort { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }

        guard !materials.isEmpty else {
            throw KeepTalkingClientError.localIdentityPrivateKeyMissing
        }
        return materials
    }

    static func remoteKeyAgreementPublicKeys(
        nodeID: UUID,
        localNodeID: UUID,
        on database: any Database
    ) async throws -> [RemotePublicKeyCandidate] {
        let relations = try await KeepTalkingNodeRelation.query(on: database)
            .filter(\.$from.$id, .equal, nodeID)
            .filter(\.$to.$id, .equal, localNodeID)
            .all()
        let relationIDs = relations.compactMap(\.id)
        guard !relationIDs.isEmpty else {
            throw KeepTalkingClientError.remoteIdentityPublicKeyMissing(nodeID)
        }

        var orderedCandidates: [RemotePublicKeyCandidate] = []

        for relationID in relationIDs {
            let keys = try await KeepTalkingNodeIdentityKey.query(on: database)
                .filter(\.$relation.$id, .equal, relationID)
                .sort(\.$createdAt, .descending)
                .all()
            for key in keys {
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

    private func makeTrustedEnvelopeCryptor<Plaintext: KeepTalkingEnvelope>(
        plaintext: @escaping @Sendable (any KeepTalkingEnvelope) -> Plaintext?,
        encrypted: @escaping @Sendable (any KeepTalkingEnvelope) -> KeepTalkingAsymmetricCipherEnvelope?,
        wrapPlaintext: @escaping @Sendable (Plaintext) -> any KeepTalkingEnvelope,
        wrapEncrypted: @escaping @Sendable (KeepTalkingAsymmetricCipherEnvelope) -> any KeepTalkingEnvelope,
        encrypt: @escaping @Sendable (Plaintext) async throws -> KeepTalkingAsymmetricCipherEnvelope,
        decrypt: @escaping @Sendable (KeepTalkingAsymmetricCipherEnvelope) async throws -> Plaintext
    ) -> KeepTalkingTrustedEnvelopeCryptor {
        KeepTalkingTrustedEnvelopeCryptor(
            encrypt: { envelope in
                guard let payload = plaintext(envelope) else {
                    throw
                        KeepTalkingTrustedEnvelopeCryptorError
                        .unsupportedEnvelope(envelope.kind)
                }
                return wrapEncrypted(try await encrypt(payload))
            },
            decrypt: { envelope in
                guard let payload = encrypted(envelope) else {
                    throw
                        KeepTalkingTrustedEnvelopeCryptorError
                        .unsupportedEnvelope(envelope.kind)
                }
                return wrapPlaintext(try await decrypt(payload))
            }
        )
    }
}
