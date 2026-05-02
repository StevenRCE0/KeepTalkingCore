import CryptoKit
import Foundation

/// Pure cryptographic primitives for the bidirectional trust handshake.
///
/// The handshake runs on the signaling channel (never written to context
/// history) and exists to safely auto-exchange long-term identity public keys
/// between two nodes that share a `KeepTalkingContext`.
///
/// Algorithm: X25519 ECDH between fresh per-handshake ephemeral keypairs.
/// The DH-derived raw secret is fed through HKDF-SHA256 with the per-context
/// group secret as the salt and a transcript hash as the `info` parameter,
/// producing a transient AES-GCM session key. That key is used only to seal
/// the inner identity payloads of this handshake; both the ephemeral keys
/// and the session key are discarded once the handshake completes.
///
/// Binding the salt to `KeepTalkingContextGroupSecret.secret` is the
/// "derive p from the context secret" requirement: a captured handshake
/// envelope cannot be opened without that group secret.
public enum TrustHandshakeCrypto {

    public enum HandshakeError: LocalizedError {
        case invalidEphemeralPublicKey
        case sealFailed
        case openFailed

        public var errorDescription: String? {
            switch self {
                case .invalidEphemeralPublicKey:
                    return "Trust handshake: peer ephemeral public key is malformed."
                case .sealFailed:
                    return "Trust handshake: failed to seal identity payload."
                case .openFailed:
                    return
                        "Trust handshake: failed to open identity payload (wrong context secret, tampering, or replay)."
            }
        }
    }

    /// Domain separator embedded in every transcript hash.
    public static let domain: String = "kt.trust.v1"

    public struct Ephemeral {
        public let privateKey: Curve25519.KeyAgreement.PrivateKey
        public let publicKeyBytes: Data

        public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
            self.privateKey = privateKey
            self.publicKeyBytes = Data(privateKey.publicKey.rawRepresentation)
        }
    }

    public static func generateEphemeral() -> Ephemeral {
        Ephemeral(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Canonical transcript bytes for a handshake. Both peers MUST compute
    /// the same value: node ids are sorted lexicographically (by raw UUID
    /// bytes) so neither initiator nor responder is privileged in the input.
    public static func transcript(
        sessionID: UUID,
        contextID: UUID,
        initiatorNodeID: UUID,
        responderNodeID: UUID,
        initiatorEphemeralPub: Data,
        responderEphemeralPub: Data,
        scopeTag: String
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        hasher.update(data: sessionID.uuidString.lowercased().data(using: .utf8) ?? Data())
        hasher.update(data: contextID.uuidString.lowercased().data(using: .utf8) ?? Data())

        let (firstID, secondID) = canonicalNodeOrder(initiatorNodeID, responderNodeID)
        hasher.update(data: firstID.uuidString.lowercased().data(using: .utf8) ?? Data())
        hasher.update(data: secondID.uuidString.lowercased().data(using: .utf8) ?? Data())

        // Ephemeral keys are bound to the role, not the node order — that's
        // what authenticates each side's contribution.
        hasher.update(data: lengthPrefixed(initiatorEphemeralPub))
        hasher.update(data: lengthPrefixed(responderEphemeralPub))
        hasher.update(data: Data(scopeTag.utf8))

        return Data(hasher.finalize())
    }

    /// Derive the AES-GCM session key from a completed DH exchange.
    ///
    /// `contextSecret` is the per-context group secret
    /// (`KeepTalkingContextGroupSecret.secret`). It serves as the HKDF salt,
    /// binding the derived key to the specific shared context.
    public static func deriveSessionKey(
        localPrivate: Curve25519.KeyAgreement.PrivateKey,
        remotePublicBytes: Data,
        contextSecret: Data,
        transcript: Data
    ) throws -> SymmetricKey {
        let remotePublic: Curve25519.KeyAgreement.PublicKey
        do {
            remotePublic = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: remotePublicBytes
            )
        } catch {
            throw HandshakeError.invalidEphemeralPublicKey
        }

        let shared = try localPrivate.sharedSecretFromKeyAgreement(with: remotePublic)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: contextSecret,
            sharedInfo: Data(domain.utf8) + transcript,
            outputByteCount: 32
        )
    }

    public static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw HandshakeError.sealFailed
        }
        return combined
    }

    public static func open(_ ciphertext: Data, with key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw HandshakeError.openFailed
        }
    }

    // MARK: - Helpers

    private static func canonicalNodeOrder(_ a: UUID, _ b: UUID) -> (UUID, UUID) {
        let aBytes = withUnsafeBytes(of: a.uuid) { Data($0) }
        let bBytes = withUnsafeBytes(of: b.uuid) { Data($0) }
        return aBytes.lexicographicallyPrecedes(bBytes) ? (a, b) : (b, a)
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var len = UInt32(data.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
