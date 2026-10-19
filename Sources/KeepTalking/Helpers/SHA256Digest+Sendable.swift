#if !canImport(CryptoKit)
import Crypto

/// CryptoKit's `SHA256Digest` is `Sendable`; swift-crypto's isn't, so a value
/// keyed by one — the image fitter's cache of re-encoded images — can't sit in
/// a lock off Apple platforms. It's an immutable 32-byte value that's only
/// ever read, which is what `Sendable` asks.
extension SHA256Digest: @unchecked @retroactive Sendable {}
#endif
