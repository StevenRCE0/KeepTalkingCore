import Foundation

public enum KeepTalkingTrustedEnvelopeCryptorError: LocalizedError {
    case missingCryptor(KeepTalkingEnvelopeKind)
    case unsupportedEnvelope(KeepTalkingEnvelopeKind)
    case ownerUnavailable

    public var errorDescription: String? {
        switch self {
            case .missingCryptor(let kind):
                return "Missing trusted envelope cryptor for kind: \(kind.rawValue)"
            case .unsupportedEnvelope(let kind):
                return "Unsupported trusted envelope kind: \(kind.rawValue)"
            case .ownerUnavailable:
                return "Trusted envelope cryptor owner is unavailable."
        }
    }
}

public struct KeepTalkingTrustedEnvelopeCryptor: Sendable {
    public let encrypt:
        @Sendable (any KeepTalkingEnvelope) async throws
            -> any KeepTalkingEnvelope
    public let decrypt:
        @Sendable (any KeepTalkingEnvelope) async throws
            -> any KeepTalkingEnvelope

    public init(
        encrypt:
            @escaping @Sendable (any KeepTalkingEnvelope) async throws
            -> any KeepTalkingEnvelope,
        decrypt:
            @escaping @Sendable (any KeepTalkingEnvelope) async throws
            -> any KeepTalkingEnvelope
    ) {
        self.encrypt = encrypt
        self.decrypt = decrypt
    }
}

public typealias KeepTalkingTrustedEnvelopeCryptorSource =
    @Sendable (any KeepTalkingEnvelope) async throws -> KeepTalkingTrustedEnvelopeCryptor?
