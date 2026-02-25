import Foundation

protocol KeepTalkingTransportClient: AnyObject {
    var onEnvelope: (@Sendable (KeepTalkingP2PEnvelope) -> Void)? { get set }
    var onRawMessage: (@Sendable (String) -> Void)? { get set }
    var onPeerConnect: (@Sendable (UUID) -> Void)? { get set }
    var onLog: (@Sendable (String) -> Void)? { get set }

    func start() async throws
    func stop()
    func sendEnvelope(_ envelope: KeepTalkingP2PEnvelope) throws
    func runtimeStats() -> KeepTalkingRuntimeStats
    func requestP2PTrial()
    func debug(_ message: String)
}
