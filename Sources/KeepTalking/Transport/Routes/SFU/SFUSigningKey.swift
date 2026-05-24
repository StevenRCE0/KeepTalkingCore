import Crypto
import Foundation

/// Loads or creates the Ed25519 signing key used to authenticate this node
/// with a KeepTalkingSFU server. The key is keyed by the node's UUID in the
/// supplied `KeepTalkingKeychainStore` — losing it makes the SFU treat
/// this node as brand new on the next connect.
public enum KeepTalkingSFUSigningKey {
    /// Looks up the key for `nodeID`; mints a fresh one and persists it
    /// when none is stored.
    public static func loadOrCreate(
        nodeID: UUID,
        store: any KeepTalkingKeychainStore
    ) async throws -> Curve25519.Signing.PrivateKey {
        let keychainKey = KeepTalkingKeychainKey.sfuSigningKey(nodeID: nodeID)
        if let existing = try await store.get(keychainKey),
            existing.count == 32
        {
            // 32 bytes = raw Ed25519 private-key seed. `Curve25519.Signing
            // .PrivateKey(rawRepresentation:)` reconstructs the same key
            // pair, so the SFU sees the same peer ID across restarts.
            return try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
        }
        let fresh = Curve25519.Signing.PrivateKey()
        try await store.set(keychainKey, value: fresh.rawRepresentation)
        return fresh
    }

    /// Forgets the persisted key for `nodeID`. The next `loadOrCreate`
    /// call mints a new pair — i.e. this node will look like a different
    /// peer to the SFU.
    public static func forget(
        nodeID: UUID,
        store: any KeepTalkingKeychainStore
    ) async throws {
        try await store.delete(.sfuSigningKey(nodeID: nodeID))
    }
}
