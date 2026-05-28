import CryptoKit
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
