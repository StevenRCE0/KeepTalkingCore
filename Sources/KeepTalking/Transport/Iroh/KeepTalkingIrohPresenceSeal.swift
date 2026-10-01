import Crypto
import Foundation

/// The presence blob a node publishes to the hub for one context: its node
/// UUID and its current (ephemeral) iroh endpoint id, sealed with the
/// context's group secret.
///
/// Peers dial the endpoint id found *inside* the seal, never the one the hub
/// reports — the hub can relay or drop presence but cannot substitute its own
/// key, which is the anti-MITM rule of the iroh transport. The opener also
/// requires the sealed id to match the hub-reported one, so a member cannot
/// replay someone else's blob under its own connection.
enum KeepTalkingIrohPresenceSeal {
    static let magic = Data("ktp1".utf8)
    private static let salt = Data("KTIrohPresence".utf8)
    private static let aad = Data("keeptalking/iroh-presence/1".utf8)

    struct Presence: Equatable, Sendable {
        let nodeID: UUID
        let endpointID: Data
    }

    static func seal(
        nodeID: UUID,
        endpointID: Data,
        contextID: UUID,
        secret: Data
    ) throws -> Data {
        var plaintext = magic
        plaintext.append(nodeID.rfc4122Bytes)
        plaintext.append(endpointID)
        let box = try AES.GCM.seal(
            plaintext,
            using: key(contextID: contextID, secret: secret),
            authenticating: aad
        )
        guard let combined = box.combined else {
            throw KeepTalkingFrameTransportCryptoError.encryptionFailed
        }
        return combined
    }

    /// Returns nil for blobs this context's secret does not open, or whose
    /// contents are malformed.
    static func open(_ blob: Data, contextID: UUID, secret: Data) -> Presence? {
        guard
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(
                box,
                using: key(contextID: contextID, secret: secret),
                authenticating: aad
            ),
            plaintext.count
                == magic.count + 16 + KeepTalkingIrohPresenceFrame.endpointIDLength,
            plaintext.prefix(magic.count) == magic
        else { return nil }
        let body = plaintext.dropFirst(magic.count)
        return Presence(
            nodeID: UUID(rfc4122Bytes: Data(body.prefix(16))),
            endpointID: Data(body.dropFirst(16))
        )
    }

    private static func key(contextID: UUID, secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: contextID.rfc4122Bytes,
            outputByteCount: 32
        )
    }
}
