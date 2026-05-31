import Foundation

typealias KeepTalkingTransportContextSecretProvider = @Sendable (UUID) async throws -> Data?
typealias KeepTalkingTransportBlobDataHandler = @Sendable (Data) -> Void
typealias KeepTalkingTransportRealtimeDataHandler = @Sendable (Data) -> Void

protocol KeepTalkingTransportClient: AnyObject {
    var onEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)? { get set }
    var onTrustEnvelope: (@Sendable (any KeepTalkingEnvelope) -> Void)? { get set }
    var onBlobData: KeepTalkingTransportBlobDataHandler? { get set }
    var onRealtimeData: KeepTalkingTransportRealtimeDataHandler? { get set }
    var onRawMessage: (@Sendable (String) -> Void)? { get set }
    var onPeerConnect: (@Sendable (UUID) -> Void)? { get set }
    /// Fires when the broadcast (SFU) channel transitions to a state
    /// capable of accepting `sendEnvelope`. The outbox controller uses
    /// this to drain queued messages as soon as a route opens.
    var onBroadcastReady: (@Sendable () -> Void)? { get set }
    var onLog: (@Sendable (String) -> Void)? { get set }
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? { get set }

    func start() async throws
    func stop()
    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws
    func sendBlobData(
        _ data: Data,
        targetPeerNodeID: UUID?
    ) throws
    /// Send blob data directly through the SFU broadcast channel,
    /// bypassing the routing strategy.
    func sendBlobDataViaBroadcast(_ data: Data) throws
    /// Send realtime data directly through the SFU realtime channel.
    func sendRealtimeDataViaBroadcast(_ data: Data) throws
    func currentRoute() -> KeepTalkingTransportRoute
    func runtimeStats() -> KeepTalkingRuntimeStats
    func requestP2PTrial()
    func preferReliableRoute(reason: String)
    func debug(_ message: String)
}

extension KeepTalkingTransportClient {
    /// Default: falls back to `sendBlobData` with no target peer.
    /// `ContextTransport` overrides to go straight to the SFU broadcast
    /// channel, bypassing the routing strategy.
    func sendBlobDataViaBroadcast(_ data: Data) throws {
        try sendBlobData(data, targetPeerNodeID: nil)
    }

    func sendRealtimeDataViaBroadcast(_ data: Data) throws {
        try sendBlobDataViaBroadcast(data)
    }

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
