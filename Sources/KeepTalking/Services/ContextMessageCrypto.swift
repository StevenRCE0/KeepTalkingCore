import CryptoKit
import Foundation

public enum KeepTalkingContextMessageCrypto {
    public static let encryptedMessagePrefix = "ktenc:v1:"

    public static func encrypt(_ content: String, secret: Data) throws -> String {
        let key = SymmetricKey(data: secret)
        let plaintext = Data(content.utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            return content
        }
        return encryptedMessagePrefix + combined.base64EncodedString()
    }

    public static func decryptIfNeeded(_ content: String, secret: Data) throws
        -> String
    {
        guard content.hasPrefix(encryptedMessagePrefix) else {
            return content
        }

        let payload = String(content.dropFirst(encryptedMessagePrefix.count))
        guard let combined = Data(base64Encoded: payload) else {
            return content
        }

        let key = SymmetricKey(data: secret)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealed, using: key)
        return String(decoding: decrypted, as: UTF8.self)
    }
}
