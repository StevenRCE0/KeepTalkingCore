import Foundation

struct KeepTalkingEncryptedPacketTransportEnvelope: Codable, Sendable {
    static let kindValue = "keep-talking.encrypted-packet.v1"

    let kind: String
    let senderNodeID: UUID
    let contextID: UUID
    let keyIndex: UInt32
    let iv: Data
    let ciphertext: Data

    init(
        senderNodeID: UUID,
        contextID: UUID,
        keyIndex: UInt32,
        iv: Data,
        ciphertext: Data
    ) {
        kind = Self.kindValue
        self.senderNodeID = senderNodeID
        self.contextID = contextID
        self.keyIndex = keyIndex
        self.iv = iv
        self.ciphertext = ciphertext
    }
}

enum KeepTalkingPacketTransportCryptoError: LocalizedError {
    case missingContextSecret(UUID)
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedEnvelope

    var errorDescription: String? {
        switch self {
            case .missingContextSecret(let contextID):
                return "Missing context secret for context: \(contextID)"
            case .encryptionFailed:
                return "Failed to encrypt context message transport payload."
            case .decryptionFailed:
                return "Failed to decrypt context message transport payload."
            case .invalidEncryptedEnvelope:
                return "Encrypted context message transport payload did not decode to a supported chat envelope."
        }
    }
}

enum KeepTalkingPacketTransportCrypto {
    static func outboundPayload(
        for envelope: any KeepTalkingEnvelope,
        localNodeID: UUID,
        contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    ) throws -> Data {
        guard let contextID = encryptedContextID(for: envelope) else {
            return try JSONEncoder().encode(KeepTalkingEnvelopePacket(envelope))
        }
        guard
            let secret = try loadContextSecret(
                for: contextID,
                using: contextSecretProvider
            )
        else {
            throw
                KeepTalkingPacketTransportCryptoError
                .missingContextSecret(contextID)
        }

        let plaintext = try JSONEncoder().encode(KeepTalkingEnvelopePacket(envelope))
        let encrypted: (iv: Data, ciphertext: Data)
        do {
            encrypted = try KeepTalkingFrameTransportCrypto.seal(
                secret: secret,
                plaintext: plaintext
            )
        } catch {
            throw KeepTalkingPacketTransportCryptoError.encryptionFailed
        }

        let transportEnvelope =
            KeepTalkingEncryptedPacketTransportEnvelope(
                senderNodeID: localNodeID,
                contextID: contextID,
                keyIndex: 0,
                iv: encrypted.iv,
                ciphertext: encrypted.ciphertext
            )
        return try JSONEncoder().encode(transportEnvelope)
    }

    static func inboundEnvelope(
        from payload: Data,
        contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    ) throws -> (any KeepTalkingEnvelope)? {
        if let envelope = try? JSONDecoder().decode(
            KeepTalkingEnvelopePacket.self,
            from: payload
        ) {
            return envelope.envelope
        }

        guard
            let encryptedEnvelope = try? JSONDecoder().decode(
                KeepTalkingEncryptedPacketTransportEnvelope.self,
                from: payload
            ),
            encryptedEnvelope.kind
                == KeepTalkingEncryptedPacketTransportEnvelope.kindValue
        else {
            return nil
        }

        guard
            let secret = try loadContextSecret(
                for: encryptedEnvelope.contextID,
                using: contextSecretProvider
            )
        else {
            throw
                KeepTalkingPacketTransportCryptoError
                .missingContextSecret(encryptedEnvelope.contextID)
        }

        let plaintext: Data
        do {
            plaintext = try KeepTalkingFrameTransportCrypto.open(
                secret: secret,
                iv: encryptedEnvelope.iv,
                ciphertext: encryptedEnvelope.ciphertext
            )
        } catch {
            throw KeepTalkingPacketTransportCryptoError.decryptionFailed
        }

        let envelope = try JSONDecoder().decode(
            KeepTalkingEnvelopePacket.self,
            from: plaintext
        ).envelope
        guard
            let contextID = encryptedContextID(for: envelope),
            contextID == encryptedEnvelope.contextID
        else {
            throw KeepTalkingPacketTransportCryptoError
                .invalidEncryptedEnvelope
        }

        return envelope
    }

    private static func loadContextSecret(
        for contextID: UUID,
        using contextSecretProvider: KeepTalkingTransportContextSecretProvider?
    ) throws -> Data? {
        guard let contextSecretProvider else {
            return nil
        }
        return try blocking {
            try await contextSecretProvider(contextID)
        }
    }

    private static func encryptedContextID(for envelope: any KeepTalkingEnvelope)
        -> UUID?
    {
        envelope.transportContextID
    }
}
