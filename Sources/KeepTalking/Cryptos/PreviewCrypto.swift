import CryptoKit
import Foundation

public enum KeepTalkingPreviewCrypto {
    public static let encryptedPayloadPrefix = "ktenc:v1:"

    public static func encryptString(_ content: String, secret: Data) throws
        -> String
    {
        let key = SymmetricKey(data: secret)
        let plaintext = Data(content.utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            return content
        }
        return encryptedPayloadPrefix + combined.base64EncodedString()
    }

    public static func decryptStringIfNeeded(_ content: String, secret: Data) throws
        -> String
    {
        guard content.hasPrefix(encryptedPayloadPrefix) else {
            return content
        }

        let payload = String(content.dropFirst(encryptedPayloadPrefix.count))
        guard let combined = Data(base64Encoded: payload) else {
            return content
        }

        let key = SymmetricKey(data: secret)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealed, using: key)
        return String(decoding: decrypted, as: UTF8.self)
    }
}

public enum KeepTalkingContextMessageCrypto {
    public static let encryptedMessagePrefix =
        KeepTalkingPreviewCrypto.encryptedPayloadPrefix

    public static func encrypt(_ content: String, secret: Data) throws -> String {
        try KeepTalkingPreviewCrypto.encryptString(content, secret: secret)
    }

    public static func decryptIfNeeded(_ content: String, secret: Data) throws
        -> String
    {
        try KeepTalkingPreviewCrypto.decryptStringIfNeeded(
            content,
            secret: secret
        )
    }
}
