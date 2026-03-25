import Foundation

typealias KeepTalkingTransportContextSecretProvider = @Sendable (UUID) async throws -> Data?
typealias KeepTalkingTransportBlobDataHandler = @Sendable (Data) -> Void

enum KeepTalkingTransportRoute: String, Sendable {
    case sfu
    case p2p
}

protocol KeepTalkingTransportClient: AnyObject {
    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)? { get set }
    var onBlobData: KeepTalkingTransportBlobDataHandler? { get set }
    var onRawMessage: (@Sendable (String) -> Void)? { get set }
    var onPeerConnect: (@Sendable (UUID) -> Void)? { get set }
    var onLog: (@Sendable (String) -> Void)? { get set }
    var contextSecretProvider: KeepTalkingTransportContextSecretProvider? { get set }

    func start() async throws
    func stop()
    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws
    func sendBlobData(
        _ data: Data,
        via route: KeepTalkingTransportRoute?
    ) throws
    func currentRoute() -> KeepTalkingTransportRoute
    func runtimeStats() -> KeepTalkingRuntimeStats
    func requestP2PTrial()
    func preferReliableRoute(reason: String)
    func debug(_ message: String)
}
