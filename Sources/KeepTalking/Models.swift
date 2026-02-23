import Foundation

public struct KeepTalkingConfig: Sendable {
    public let signalURL: URL
    public let session: String
    public let participantID: String
    public let channel: String
    public let userID: String?

    public init(
        signalURL: URL,
        session: String,
        participantID: String,
        channel: String = "keep-talking.chat",
        userID: String? = nil
    ) {
        self.signalURL = signalURL
        self.session = session
        self.participantID = participantID
        self.channel = channel
        self.userID = userID
    }
}

public struct KeepTalkingMessage: Codable, Sendable {
    public let from: String
    public let to: String?
    public let text: String

    public init(from: String, to: String?, text: String) {
        self.from = from
        self.to = to
        self.text = text
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

public struct KeepTalkingNode: Codable, Sendable, Hashable {
    public let nodeID: String
    public let userID: String?
    public let lastSeenAt: Date

    public init(nodeID: String, userID: String?, lastSeenAt: Date = Date()) {
        self.nodeID = nodeID
        self.userID = userID
        self.lastSeenAt = lastSeenAt
    }
}

public struct KeepTalkingFriendNode: Codable, Sendable, Hashable {
    public let friendID: String
    public let nodeID: String
    public let lastSeenAt: Date

    public init(friendID: String, nodeID: String, lastSeenAt: Date = Date()) {
        self.friendID = friendID
        self.nodeID = nodeID
        self.lastSeenAt = lastSeenAt
    }
}

public struct KeepTalkingConversationMessage: Codable, Sendable, Hashable {
    public let id: String
    public let from: String
    public let to: String?
    public let text: String
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        from: String,
        to: String?,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.timestamp = timestamp
    }
}

public struct KeepTalkingConversationContext: Codable, Sendable, Hashable {
    public let conversationID: String
    public var messages: [KeepTalkingConversationMessage]
    public var updatedAt: Date

    public init(
        conversationID: String,
        messages: [KeepTalkingConversationMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

public struct KeepTalkingLocalSnapshot: Codable, Sendable {
    public var myNodes: [KeepTalkingNode]
    public var conversations: [KeepTalkingConversationContext]
    public var friendNodes: [KeepTalkingFriendNode]

    public init(
        myNodes: [KeepTalkingNode] = [],
        conversations: [KeepTalkingConversationContext] = [],
        friendNodes: [KeepTalkingFriendNode] = []
    ) {
        self.myNodes = myNodes
        self.conversations = conversations
        self.friendNodes = friendNodes
    }
}

public protocol KeepTalkingKVService: Sendable {
    func storeNodeID(_ nodeID: String, for userID: String) async throws
    func loadNodeIDs(for userID: String) async throws -> [String]
}

public protocol KeepTalkingLocalStore: Sendable {
    func loadSnapshot() throws -> KeepTalkingLocalSnapshot
    func saveSnapshot(_ snapshot: KeepTalkingLocalSnapshot) throws
}

public enum KeepTalkingEnvelopeKind: String, Codable, Sendable {
    case chat
    case node
    case friendNode
    case conversation
    case stateBundle
    case stateRequest
}

public struct KeepTalkingP2PEnvelope: Codable, Sendable {
    public let from: String
    public let to: String?
    public let kind: KeepTalkingEnvelopeKind?
    public let text: String?
    public let node: KeepTalkingNode?
    public let friendNode: KeepTalkingFriendNode?
    public let conversation: KeepTalkingConversationContext?
    public let state: KeepTalkingLocalSnapshot?

    public init(
        from: String,
        to: String? = nil,
        kind: KeepTalkingEnvelopeKind? = nil,
        text: String? = nil,
        node: KeepTalkingNode? = nil,
        friendNode: KeepTalkingFriendNode? = nil,
        conversation: KeepTalkingConversationContext? = nil,
        state: KeepTalkingLocalSnapshot? = nil
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.text = text
        self.node = node
        self.friendNode = friendNode
        self.conversation = conversation
        self.state = state
    }

    var resolvedKind: KeepTalkingEnvelopeKind? {
        if let kind {
            return kind
        }
        if text != nil {
            return .chat
        }
        if node != nil {
            return .node
        }
        if friendNode != nil {
            return .friendNode
        }
        if conversation != nil {
            return .conversation
        }
        if state != nil {
            return .stateBundle
        }
        return nil
    }

    static func chat(from: String, to: String?, text: String) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .chat, text: text)
    }

    static func node(from: String, to: String?, node: KeepTalkingNode) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .node, node: node)
    }

    static func friendNode(from: String, to: String?, friendNode: KeepTalkingFriendNode) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .friendNode, friendNode: friendNode)
    }

    static func conversation(
        from: String,
        to: String?,
        conversation: KeepTalkingConversationContext
    ) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .conversation, conversation: conversation)
    }

    static func state(from: String, to: String?, state: KeepTalkingLocalSnapshot) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .stateBundle, state: state)
    }

    static func stateRequest(from: String, to: String?) -> KeepTalkingP2PEnvelope {
        KeepTalkingP2PEnvelope(from: from, to: to, kind: .stateRequest)
    }
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

struct SessionDescriptionPayload: Codable, Sendable {
    let type: String
    let sdp: String
}

struct IceCandidatePayload: Codable, Sendable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32?
    let usernameFragment: String?
}

struct TricklePayload: Codable, Sendable {
    let target: Int
    let candidate: IceCandidatePayload
}

struct JoinParams: Codable, Sendable {
    let sid: String
    let uid: String
    let offer: SessionDescriptionPayload
}

struct OfferParams: Codable, Sendable {
    let desc: SessionDescriptionPayload
}

struct AnswerParams: Codable, Sendable {
    let desc: SessionDescriptionPayload
}

struct RpcRequest<Params: Encodable>: Encodable {
    let method: String
    let params: Params
    let id: String?

    enum CodingKeys: String, CodingKey {
        case method
        case params
        case id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
        try container.encodeIfPresent(id, forKey: .id)
    }
}
