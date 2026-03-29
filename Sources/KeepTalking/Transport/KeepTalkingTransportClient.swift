import Foundation

typealias KeepTalkingTransportContextSecretProvider = @Sendable (UUID) async throws -> Data?
typealias KeepTalkingTransportBlobDataHandler = @Sendable (Data) -> Void

protocol KeepTalkingTransportClient: AnyObject {
    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)? { get set }
    var onBlobData: KeepTalkingTransportBlobDataHandler? { get set }
    var onRawMessage: (@Sendable (String) -> Void)? { get set }
    var onPeerConnect: (@Sendable (UUID) -> Void)? { get set }
    var onLog: (@Sendable (String) -> Void)? { get set }
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? { get set }

    func start() async throws
    func stop()
    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws
    func sendBlobData(
        _ data: Data,
        targetPeerNodeID: UUID?
    ) throws
    func currentRoute() -> KeepTalkingTransportRoute
    func runtimeStats() -> KeepTalkingRuntimeStats
    func requestP2PTrial()
    func preferReliableRoute(reason: String)
    func debug(_ message: String)
}

extension KeepTalkingTransportClient {
    func sendTrustedEnvelope(
        _ envelope: any KeepTalkingEnvelope,
        cryptorSource: KeepTalkingTrustedEnvelopeCryptorSource
    ) async throws {
        guard let cryptor = try await cryptorSource(envelope) else {
            throw
                KeepTalkingTrustedEnvelopeCryptorError
                .missingCryptor(envelope.kind)
        }
        try sendEnvelope(try await cryptor.encrypt(envelope))
    }
}
