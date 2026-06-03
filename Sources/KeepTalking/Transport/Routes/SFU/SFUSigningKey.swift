import Crypto
import Foundation

/// Creates the Ed25519 signing key used to authenticate one SFU session.
///
/// SFU peer identity is intentionally process-local and disposable. A fresh
/// key per connection lets multiple per-context clients from the same
/// KeepTalking node coexist at the SFU, because the SFU routes by signing
/// pubkey rather than by the higher-level node UUID.
public enum KeepTalkingSFUSigningKey {
    public static func ephemeral() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }
}
