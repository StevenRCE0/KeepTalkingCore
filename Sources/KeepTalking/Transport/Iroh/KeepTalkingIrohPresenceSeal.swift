import Crypto
import Foundation

/// The presence blob a node publishes to the hub for one context: its node
/// UUID, its current (ephemeral) iroh endpoint id and, when it runs one, its
/// Bluetooth endpoint id — sealed with the context's group secret.
///
/// Peers dial the endpoint ids found *inside* the seal, never the one the hub
/// reports — the hub can relay or drop presence but cannot substitute its own
/// key, which is the anti-MITM rule of the iroh transport. The opener also
/// requires the sealed network id to match the hub-reported one, so a member
/// cannot replay someone else's blob under its own connection.
///
/// The Bluetooth id is announced while the hub is still reachable, so peers
/// already know it when they fall back to Bluetooth with the hub gone.
enum KeepTalkingIrohPresenceSeal {
    /// `ktp2 ‖ node(16) ‖ endpoint(32) [‖ bluetooth endpoint(32)]`;
    /// `ktp1` blobs (no Bluetooth id) still open.
    static let magic = Data("ktp2".utf8)
    static let legacyMagic = Data("ktp1".utf8)
    private static let salt = Data("KTIrohPresence".utf8)
    private static let aad = Data("keeptalking/iroh-presence/1".utf8)

    struct Presence: Equatable, Sendable {
        let nodeID: UUID
        let endpointID: Data
        /// The peer's Bluetooth-only endpoint, if it runs one.
        var bluetoothEndpointID: Data? = nil
    }

    static func seal(
        nodeID: UUID,
        endpointID: Data,
        bluetoothEndpointID: Data? = nil,
        contextID: UUID,
        secret: Data
    ) throws -> Data {
        var plaintext = magic
        plaintext.append(nodeID.rfc4122Bytes)
        plaintext.append(endpointID)
        if let bluetoothEndpointID { plaintext.append(bluetoothEndpointID) }
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
        let idLength = KeepTalkingIrohHubFrame.endpointIDLength
        guard
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(
                box,
                using: key(contextID: contextID, secret: secret),
                authenticating: aad
            ),
            plaintext.count >= 4
        else { return nil }
        let head = plaintext.prefix(4)
        let body = Data(plaintext.dropFirst(4))
        let base = 16 + idLength
        switch head {
            case legacyMagic where body.count == base,
                magic where body.count == base || body.count == base + idLength:
                return Presence(
                    nodeID: UUID(rfc4122Bytes: Data(body.prefix(16))),
                    endpointID: Data(body.dropFirst(16).prefix(idLength)),
                    bluetoothEndpointID: body.count == base + idLength ? Data(body.suffix(idLength)) : nil
                )
            default:
                return nil
        }
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
