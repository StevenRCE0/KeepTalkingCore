import CryptoKit
import Foundation

/// Reference to a one-time blob (OTB) transfer carried inside an action-call
/// request/result. The actual bytes stream over the blob channel as ephemeral
/// frames keyed by `transferID`; `sealedKey` is the per-transfer symmetric key
/// sealed to the recipient (Curve25519 → AES-GCM), so only the target node can
/// decrypt the streamed chunks. Unlike context attachments, an OTB is
/// point-to-point, never recorded, never broadcast, and discarded after use.
public struct KeepTalkingOneTimeBlobRef: Codable, Sendable {
    public let transferID: UUID
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let sealedKey: KeepTalkingAsymmetricCipherEnvelope

    public init(
        transferID: UUID,
        filename: String,
        mimeType: String,
        byteCount: Int,
        sealedKey: KeepTalkingAsymmetricCipherEnvelope
    ) {
        self.transferID = transferID
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sealedKey = sealedKey
    }
}

/// Symmetric crypto for OTB payloads. A fresh key is minted per transfer and
/// sealed to the recipient via the existing asym pathway; chunks are encrypted
/// with that key (AES-GCM, random nonce per chunk → integrity per chunk).
enum KeepTalkingOneTimeBlobCrypto {
    /// Plaintext chunk size. Ciphertext is slightly larger (nonce + tag), still
    /// well under the 32 KB SCTP-safe frame budget the blob transport uses.
    static let plaintextChunkSize = 24 * 1024

    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func key(from data: Data) -> SymmetricKey {
        SymmetricKey(data: data)
    }

    /// Authenticated-but-unencrypted data binding a chunk to its transfer and
    /// position, so a chunk decrypted at the wrong index, replayed into another
    /// slot, or moved between transfers fails the GCM tag even under the same key.
    static func chunkAAD(transferID: UUID, chunkIndex: Int) -> Data {
        var aad = Data()
        withUnsafeBytes(of: transferID.uuid) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(chunkIndex).littleEndian) { aad.append(contentsOf: $0) }
        return aad
    }

    /// Encrypts one plaintext chunk to a self-describing `combined` blob
    /// (nonce ‖ ciphertext ‖ tag), authenticating `aad`.
    static func sealChunk(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw KeepTalkingOneTimeBlobError.encryptionFailed
        }
        return combined
    }

    /// Decrypts a `combined` chunk produced by `sealChunk`, requiring the same `aad`.
    static func openChunk(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}

public enum KeepTalkingOneTimeBlobError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    /// Carries a self-describing diagnostic message (chunk sizes, hashes,
    /// declared vs decrypted bytes) so the cause is visible in the surfaced tool
    /// result even when device transport logs aren't accessible.
    case materializationFailed(String)
    case transferTimedOut(UUID)
    case sourceUnreadable(String)

    public var errorDescription: String? {
        switch self {
            case .encryptionFailed:
                return "Failed to encrypt one-time blob chunk."
            case .decryptionFailed:
                return "Failed to decrypt one-time blob chunk (wrong key or corrupt data)."
            case .materializationFailed(let detail):
                return detail
            case .transferTimedOut(let id):
                return "One-time blob transfer \(id.uuidString.lowercased()) timed out."
            case .sourceUnreadable(let path):
                return "Cannot read source file for one-time blob: \(path)"
        }
    }
}
