import Crypto
import Foundation

enum KeepTalkingFrameTransportCryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
            case .encryptionFailed:
                return "Failed to encrypt transport payload."
            case .decryptionFailed:
                return "Failed to decrypt transport payload."
        }
    }
}

enum KeepTalkingFrameTransportCrypto {
    static let keyDerivationSalt = Data("LKFrameEncryptionKey".utf8)
    static let derivedKeyByteCount = 16

    static func deriveKey(secret: Data) -> SymmetricKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: keyDerivationSalt,
            outputByteCount: derivedKeyByteCount
        )
        return derived
    }

    static func seal(secret: Data, plaintext: Data) throws -> (iv: Data, ciphertext: Data) {
        let key = deriveKey(secret: secret)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            let iv = Data(sealed.nonce)
            let ciphertext = sealed.ciphertext + sealed.tag
            return (iv, ciphertext)
        } catch {
            throw KeepTalkingFrameTransportCryptoError.encryptionFailed
        }
    }

    static func open(secret: Data, iv: Data, ciphertext: Data) throws -> Data {
        let key = deriveKey(secret: secret)
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealed = try AES.GCM.SealedBox(combined: Data(nonce) + ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw KeepTalkingFrameTransportCryptoError.decryptionFailed
        }
    }
}

// MARK: - Voice frame encryption

extension KeepTalkingFrameTransportCrypto {
    /// Separate salt so voice and chat keys are domain-separated even if they
    /// share the same group secret.
    static let voiceKeyDerivationSalt = Data("LKVoiceFrameEncryptionKey".utf8)
    /// AES-GCM nonce size (bytes).
    static let voiceNonceSize = 12

    /// `sessionID` is used as HKDF info, so each voice session derives a
    /// distinct key even when two sessions share the same group secret.
    static func deriveVoiceKey(secret: Data, sessionID: UUID) -> SymmetricKey {
        var sid = sessionID.uuid
        let info = withUnsafeBytes(of: &sid) { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: voiceKeyDerivationSalt,
            info: info,
            outputByteCount: derivedKeyByteCount
        )
    }

    /// Returns `nonce12 || ciphertext || tag` (28 bytes of overhead).
    /// `nonce12` must be exactly 12 bytes; the caller constructs it from a
    /// per-sender monotonic counter so it's never reused under the same key.
    static func sealVoiceFrame(secret: Data, sessionID: UUID, nonce12: Data, plaintext: Data) throws -> Data {
        precondition(nonce12.count == voiceNonceSize)
        let key = deriveVoiceKey(secret: secret, sessionID: sessionID)
        do {
            let nonce = try AES.GCM.Nonce(data: nonce12)
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            return nonce12 + sealed.ciphertext + sealed.tag
        } catch {
            throw KeepTalkingFrameTransportCryptoError.encryptionFailed
        }
    }

    /// Input must be the output of `sealVoiceFrame`: `nonce12 || ciphertext || tag`.
    static func openVoiceFrame(secret: Data, sessionID: UUID, data: Data) throws -> Data {
        guard data.count > voiceNonceSize + 16 else {
            throw KeepTalkingFrameTransportCryptoError.decryptionFailed
        }
        let key = deriveVoiceKey(secret: secret, sessionID: sessionID)
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw KeepTalkingFrameTransportCryptoError.decryptionFailed
        }
    }
}
