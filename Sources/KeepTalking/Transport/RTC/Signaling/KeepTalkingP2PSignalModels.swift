import Foundation

public struct KeepTalkingP2PSignalData: Codable, Sendable {
    public let kind: String
    public let type: String?
    public let sdp: String?
    public let candidate: String?
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?

    public init(
        kind: String,
        type: String?,
        sdp: String?,
        candidate: String?,
        sdpMid: String?,
        sdpMLineIndex: Int32?
    ) {
        self.kind = kind
        self.type = type
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct KeepTalkingP2PSignalPayload: Codable, Sendable {
    public let from: UUID
    public let to: UUID
    public let data: KeepTalkingP2PSignalData

    public init(from: UUID, to: UUID, data: KeepTalkingP2PSignalData) {
        self.from = from
        self.to = to
        self.data = data
    }
}

public struct KeepTalkingP2PPresencePayload: Codable, Sendable {
    public let node: UUID

    public init(node: UUID) {
        self.node = node
    }
}
