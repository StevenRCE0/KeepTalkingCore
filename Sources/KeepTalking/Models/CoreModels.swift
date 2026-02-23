import FluentKit
import Foundation

public struct KeepTalkingConfig: Sendable {
    public let signalURL: URL
    public let session: String
    public let channel: String
    public let node: UUID

    public init(
        signalURL: URL,
        session: String,
        channel: String = "keep-talking.chat",
        node: UUID = UUID()
    ) {
        self.signalURL = signalURL
        self.session = session
        self.channel = channel
        self.node = node
    }
}

public struct KeepTalkingRuntimeStats: Sendable {
    public let sent: Int
    public let received: Int
    public let outboundLabel: String?
    public let outboundState: Int?
    public let inboundLabel: String?
    public let inboundState: Int?
    public let retainedChannels: Int

    init(
        sent: Int,
        received: Int,
        outboundLabel: String?,
        outboundState: Int?,
        inboundLabel: String?,
        inboundState: Int?,
        retainedChannels: Int
    ) {
        self.sent = sent
        self.received = received
        self.outboundLabel = outboundLabel
        self.outboundState = outboundState
        self.inboundLabel = inboundLabel
        self.inboundState = inboundState
        self.retainedChannels = retainedChannels
    }
}

public protocol KeepTalkingKVService: Sendable {
    func storeNodeID(_ node: UUID) async throws
    func loadNodeIDs() async throws -> [UUID]
}

public protocol KeepTalkingLocalStore: Sendable {
    var database: any Database { get }
}

public enum KeepTalkingP2PEnvelope: Codable, Sendable {
    case message(KeepTalkingContextMessage)
    case context(KeepTalkingContext)
    case node(KeepTalkingNode)
}

enum KeepTalkingInternalError: LocalizedError {
    case unsupportedEnvelope

    var errorDescription: String? {
        switch self {
        case .unsupportedEnvelope:
            return "Unsupported P2P envelope payload."
        }
    }
}
