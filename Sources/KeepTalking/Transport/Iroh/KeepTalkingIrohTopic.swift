import Crypto
import Foundation

/// A context's identity on the iroh transport, derived from its group secret:
///
/// - **topic** — the 32-byte routing key. Hub rooms, peer frames and
///   datagrams carry it instead of the context id, so the hub and any
///   non-member on a link see opaque bytes.
/// - **payload key** — seals everything published to the topic (envelopes
///   and blob frames). It replaces `KeepTalkingPacketTransportCrypto`'s
///   wrapper on iroh links, whose context and sender ids travel in the clear.
///
/// Both come from HKDF over the secret with separate salts, so knowing the
/// topic reveals nothing about the key. Rotating a context's secret moves
/// its topic too.
struct KeepTalkingIrohTopic: Sendable {
    private static let topicSalt = Data("KTIrohTopic".utf8)
    private static let payloadSalt = Data("KTIrohPayload".utf8)

    let contextID: UUID
    let topic: Data
    private let payloadKey: SymmetricKey

    init(contextID: UUID, secret: Data) {
        let ikm = SymmetricKey(data: secret)
        let info = contextID.rfc4122Bytes
        self.contextID = contextID
        self.topic = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Self.topicSalt,
            info: info,
            outputByteCount: KeepTalkingIrohHubFrame.topicLength
        ).withUnsafeBytes { Data($0) }
        self.payloadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Self.payloadSalt,
            info: info,
            outputByteCount: 32
        )
    }

    /// `nonce ‖ ciphertext ‖ tag`, bound to the topic.
    func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: payloadKey, authenticating: topic).combined
        else { throw KeepTalkingFrameTransportCryptoError.encryptionFailed }
        return combined
    }

    /// Nil for anything this topic's key did not seal.
    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: payloadKey, authenticating: topic)
    }
}
