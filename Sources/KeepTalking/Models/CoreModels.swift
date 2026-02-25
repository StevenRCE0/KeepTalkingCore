import FluentKit
import Foundation

public struct KeepTalkingConfig: Sendable {
    public static let signalingChannel = "keep-talking.signaling"
    public static let chatChannelPrefix = "keep-talking.chat"
    public static let actionCallChannelPrefix = "keep-talking.action_call"

    public let signalURL: URL
    public let contextID: UUID
    public let node: UUID
    public let p2pPreferredRemoteID: String?
    public let p2pAttemptTimeoutSeconds: TimeInterval
    public let p2pStunServers: [String]

    public init(
        signalURL: URL,
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        node: UUID = UUID(),
        p2pPreferredRemoteID: String? = nil,
        p2pAttemptTimeoutSeconds: TimeInterval = 5,
        p2pStunServers: [String] = ["stun:stun.l.google.com:19302"]
    ) {
        self.signalURL = signalURL
        self.contextID = contextID
        self.node = node
        self.p2pPreferredRemoteID = p2pPreferredRemoteID
        self.p2pAttemptTimeoutSeconds = p2pAttemptTimeoutSeconds
        self.p2pStunServers = p2pStunServers
    }

    public var chatChannelLabel: String {
        "\(Self.chatChannelPrefix).\(scopedSessionID)"
    }

    public var actionCallChannelLabel: String {
        "\(Self.actionCallChannelPrefix).\(scopedSessionID)"
    }

    public var signalingChannelLabel: String {
        Self.signalingChannel
    }

    public var scopedSessionID: String {
        contextID.uuidString.lowercased()
    }

    public func withContextID(_ contextID: UUID) -> KeepTalkingConfig {
        KeepTalkingConfig(
            signalURL: signalURL,
            contextID: contextID,
            node: node,
            p2pPreferredRemoteID: p2pPreferredRemoteID,
            p2pAttemptTimeoutSeconds: p2pAttemptTimeoutSeconds,
            p2pStunServers: p2pStunServers
        )
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
    public let route: String?

    init(
        sent: Int,
        received: Int,
        outboundLabel: String?,
        outboundState: Int?,
        inboundLabel: String?,
        inboundState: Int?,
        retainedChannels: Int,
        route: String?
    ) {
        self.sent = sent
        self.received = received
        self.outboundLabel = outboundLabel
        self.outboundState = outboundState
        self.inboundLabel = inboundLabel
        self.inboundState = inboundState
        self.retainedChannels = retainedChannels
        self.route = route
    }
}

public protocol KeepTalkingKVService: Sendable {
    func storeNodeID(_ node: UUID) async throws
    func loadNodeIDs() async throws -> [UUID]
}

public protocol KeepTalkingLocalStore: Sendable {
    var database: any Database { get }
}

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

public struct KeepTalkingNodeRelationStatus: Codable, Sendable {
    public let toNodeID: UUID
    public let relationship: KeepTalkingRelationship
    public let actions: [KeepTalkingAction]

    public init(
        toNodeID: UUID,
        relationship: KeepTalkingRelationship,
        actions: [KeepTalkingAction]
    ) {
        self.toNodeID = toNodeID
        self.relationship = relationship
        self.actions = actions
    }
}

public struct KeepTalkingNodeStatus: Codable, Sendable {
    public let node: KeepTalkingNode
    public let contextID: UUID
    public let nodeRelations: [KeepTalkingNodeRelationStatus]

    public init(
        node: KeepTalkingNode,
        contextID: UUID,
        nodeRelations: [KeepTalkingNodeRelationStatus]
    ) {
        self.node = node
        self.contextID = contextID
        self.nodeRelations = nodeRelations
    }
}

public enum KeepTalkingP2PEnvelope: Codable, Sendable {
    case message(KeepTalkingContextMessage)
    case context(KeepTalkingContext)
    case node(KeepTalkingNode)
    case nodeStatus(KeepTalkingNodeStatus)
    case actionCallRequest(KeepTalkingActionCallRequest)
    case actionCallResult(KeepTalkingActionCallResult)
    case p2pSignal(KeepTalkingP2PSignalPayload)
    case p2pPresence(KeepTalkingP2PPresencePayload)
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
