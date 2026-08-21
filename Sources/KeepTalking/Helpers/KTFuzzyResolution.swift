import Foundation

/// What a caller-supplied token turned out to mean — the ONE outcome shape for
/// every resolver that matches typed-back identifiers against the candidates
/// that actually exist (`UUIDFriendlyName.resolve` for word names,
/// `KTResourceManifest.resolveAgentHandle(_:among:)` for hex handles). Sharing
/// the shape keeps the repair disciplines aligned: exact wins, a single typo is
/// repaired to the only candidate it can have meant, and anything less certain
/// is refused rather than guessed.
public enum KTFuzzyResolution<ID> {
    /// Matched exactly one candidate.
    case resolved(ID)
    /// A mistyped token, repaired to exactly one candidate.
    case corrected(ID, from: String, to: String)
    /// Matched more than one candidate; the caller must disambiguate.
    case ambiguous([ID])
    /// Nothing matched closely enough to guess.
    case unknown
}

extension KTFuzzyResolution: Equatable where ID: Equatable {}
extension KTFuzzyResolution: Sendable where ID: Sendable {}
