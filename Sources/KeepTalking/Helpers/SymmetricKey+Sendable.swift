#if !canImport(CryptoKit)
import Crypto

/// CryptoKit's `SymmetricKey` is `Sendable`; swift-crypto's isn't, so the value
/// types that carry one (topics, presence seals, the one-time blob outbox)
/// don't compile off Apple platforms. It's an immutable value over
/// copy-on-write storage that's only ever read, which is what `Sendable` asks.
extension SymmetricKey: @unchecked @retroactive Sendable {}
#endif
