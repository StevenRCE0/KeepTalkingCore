import FluentKit
import Foundation

/// Runtime configuration shared by the client, transports, and executors.
public struct KeepTalkingConfig: Sendable {
    public static let signalingChannel = "keep-talking.signaling"
    public static let chatChannelPrefix = "keep-talking.chat"
    public static let blobChannelPrefix = "keep-talking.blob"
    public static let actionCallChannelPrefix = "keep-talking.action_call"

    public let signalURL: URL
    public let contextID: UUID
    public let node: UUID
    public let p2pPreferredRemoteID: String?
    public let p2pAttemptTimeoutSeconds: TimeInterval
    public let p2pStunServers: [String]
    public let recentAttachmentSyncLookback: TimeInterval

    /// Creates a configuration for a single KeepTalking node session.
    ///
    /// - Parameters:
    ///   - signalURL: Signaling server endpoint.
    ///   - contextID: Active context identifier used to scope channels.
    ///   - node: Local node identifier.
    ///   - p2pPreferredRemoteID: Preferred peer identifier for direct P2P attempts.
    ///   - p2pAttemptTimeoutSeconds: Maximum duration to wait for a P2P attempt.
    ///   - p2pStunServers: STUN servers used during ICE negotiation.
    public init(
        signalURL: URL,
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        node: UUID = UUID(),
        p2pPreferredRemoteID: String? = nil,
        p2pAttemptTimeoutSeconds: TimeInterval = 5,
        p2pStunServers: [String] = ["stun:stun.l.google.com:19302"],
        recentAttachmentSyncLookback: TimeInterval = 14 * 24 * 60 * 60
    ) {
        self.signalURL = signalURL
        self.contextID = contextID
        self.node = node
        self.p2pPreferredRemoteID = p2pPreferredRemoteID
        self.p2pAttemptTimeoutSeconds = p2pAttemptTimeoutSeconds
        self.p2pStunServers = p2pStunServers
        self.recentAttachmentSyncLookback = max(0, recentAttachmentSyncLookback)
    }

    public var chatChannelLabel: String {
        "\(Self.chatChannelPrefix).\(scopedSessionID)"
    }

    public var actionCallChannelLabel: String {
        "\(Self.actionCallChannelPrefix).\(scopedSessionID)"
    }

    public var blobChannelLabel: String {
        "\(Self.blobChannelPrefix).\(scopedSessionID)"
    }

    public var signalingChannelLabel: String {
        Self.signalingChannel
    }

    public var scopedSessionID: String {
        contextID.uuidString.lowercased()
    }

    /// Returns a copy of the configuration scoped to a different context.
    public func withContextID(_ contextID: UUID) -> KeepTalkingConfig {
        KeepTalkingConfig(
            signalURL: signalURL,
            contextID: contextID,
            node: node,
            p2pPreferredRemoteID: p2pPreferredRemoteID,
            p2pAttemptTimeoutSeconds: p2pAttemptTimeoutSeconds,
            p2pStunServers: p2pStunServers,
            recentAttachmentSyncLookback: recentAttachmentSyncLookback
        )
    }
}

/// Snapshot of transport-level counters and channel state.
public struct KeepTalkingRuntimeStats: Sendable {
    public let sent: Int
    public let received: Int
    public let outboundLabel: String?
    public let outboundState: Int?
    public let inboundLabel: String?
    public let inboundState: Int?
    public let retainedChannels: Int
    public let route: String?

    public var outboundIsOpen: Bool {
        outboundState == 1
    }
    public var inboundIsOpen: Bool {
        inboundState == 1
    }

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
    func storeNodeMetadata(
        nodeID: String,
        name: String,
        purposes: [String],
        publicKey: String?,
        trustedNodeID: String?
    ) async throws
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

public struct KeepTalkingAdvertisedAction: Codable, Sendable {
    public enum PayloadSummary: Codable, Sendable {
        case mcpBundle(name: String, indexDescription: String)
        case skill(name: String, indexDescription: String)
        case primitive(
            name: String,
            indexDescription: String,
            action: KeepTalkingPrimitiveActionKind
        )
    }

    public let actionID: UUID
    public let ownerNodeID: UUID?
    public let descriptor: KeepTalkingActionDescriptor?
    public let payloadSummary: PayloadSummary
    public let remoteAuthorisable: Bool
    public let blockingAuthorisation: Bool
    public let createdAt: Date?
    public let lastUsed: Date?

    public init(
        actionID: UUID,
        ownerNodeID: UUID?,
        descriptor: KeepTalkingActionDescriptor?,
        payloadSummary: PayloadSummary,
        remoteAuthorisable: Bool,
        blockingAuthorisation: Bool,
        createdAt: Date? = nil,
        lastUsed: Date? = nil
    ) {
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.descriptor = descriptor
        self.payloadSummary = payloadSummary
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}

public struct KeepTalkingNodeRelationStatus: Codable, Sendable {
    public let toNodeID: UUID
    public let relationship: KeepTalkingRelationship
    public let actions: [KeepTalkingAdvertisedAction]
    public let actionWakeRoutes: [KeepTalkingActionWakeRoute]

    public init(
        toNodeID: UUID,
        relationship: KeepTalkingRelationship,
        actions: [KeepTalkingAdvertisedAction],
        actionWakeRoutes: [KeepTalkingActionWakeRoute] = []
    ) {
        self.toNodeID = toNodeID
        self.relationship = relationship
        self.actions = actions
        self.actionWakeRoutes = actionWakeRoutes
    }
}

public struct KeepTalkingNodeStatus: Codable, Sendable {
    public let node: KeepTalkingNode
    public let context: KeepTalkingContext
    public let nodeRelations: [KeepTalkingNodeRelationStatus]

    public init(
        node: KeepTalkingNode,
        context: KeepTalkingContext,
        nodeRelations: [KeepTalkingNodeRelationStatus]
    ) {
        self.node = node
        self.context = context
        self.nodeRelations = nodeRelations
    }
}

public struct KeepTalkingAsymmetricCipherEnvelope: Codable, Sendable {
    public let senderNodeID: UUID
    public let recipientNodeID: UUID
    public let ciphertext: Data

    public init(
        senderNodeID: UUID,
        recipientNodeID: UUID,
        ciphertext: Data
    ) {
        self.senderNodeID = senderNodeID
        self.recipientNodeID = recipientNodeID
        self.ciphertext = ciphertext
    }
}

public enum KeepTalkingP2PEnvelope: Codable, Sendable {
    case message(KeepTalkingContextMessage)
    case attachment(KeepTalkingContextAttachmentDTO)
    case context(KeepTalkingContext)
    case node(KeepTalkingNode)
    case nodeStatus(KeepTalkingNodeStatus)
    case encryptedNodeStatus(KeepTalkingAsymmetricCipherEnvelope)
    case contextSync(KeepTalkingContextSyncEnvelope)
    case actionCallRequest(KeepTalkingActionCallRequest)
    case requestAck(KeepTalkingRequestAck)
    case actionCallResult(KeepTalkingActionCallResult)
    case encryptedActionCallRequest(KeepTalkingAsymmetricCipherEnvelope)
    case encryptedRequestAck(KeepTalkingAsymmetricCipherEnvelope)
    case encryptedActionCallResult(KeepTalkingAsymmetricCipherEnvelope)
    case actionCatalogRequest(KeepTalkingActionCatalogRequest)
    case actionCatalogResult(KeepTalkingActionCatalogResult)
    case encryptedActionCatalogRequest(KeepTalkingAsymmetricCipherEnvelope)
    case encryptedActionCatalogResult(KeepTalkingAsymmetricCipherEnvelope)
    case p2pSignal(KeepTalkingP2PSignalPayload)
    case p2pPresence(KeepTalkingP2PPresencePayload)
}

enum KeepTalkingEnvelopeChannel: Hashable, Sendable {
    case chat
    case blob
    case actionCall
    case signaling
}

extension KeepTalkingContextSyncEnvelope {
    /// Node IDs involved in this sync exchange.
    var participantNodeIDs: [UUID] {
        switch self {
            case .summaryRequest(let r):
                return [r.requester, r.recipient]
            case .summaryResult(let r):
                return [r.requester, r.responder]
            case .tailRequest(let r):
                return [r.requester, r.recipient]
            case .chunkRequest(let r):
                return [r.requester, r.recipient]
            case .messagesResult(let r):
                return [r.requester, r.responder]
            case .attachmentRequest(let r):
                return [r.requester]
        }
    }
}

extension KeepTalkingP2PEnvelope {
    /// All remote node IDs that can be inferred from the envelope payload.
    var participantNodeIDs: [UUID] {
        switch self {
            case .message(let m):
                if case .node(let id) = m.sender { return [id] }
                return []
            case .attachment:
                return []
            case .context(let ctx):
                var ids: [UUID] = []
                for msg in ctx.messages {
                    if case .node(let id) = msg.sender { ids.append(id) }
                }
                for att in ctx.attachments {
                    if case .node(let id) = att.sender { ids.append(id) }
                }
                return ids
            case .node(let n):
                return n.id.map { [$0] } ?? []
            case .nodeStatus(let s):
                return s.node.id.map { [$0] } ?? []
            case .encryptedNodeStatus(let e):
                return [e.senderNodeID, e.recipientNodeID]
            case .contextSync(let e):
                return e.participantNodeIDs
            case .actionCallRequest(let r):
                return [r.callerNodeID, r.targetNodeID]
            case .requestAck(let a):
                return [a.callerNodeID, a.targetNodeID]
            case .actionCallResult(let r):
                return [r.callerNodeID, r.targetNodeID]
            case .encryptedActionCallRequest(let e),
                .encryptedRequestAck(let e),
                .encryptedActionCallResult(let e),
                .encryptedActionCatalogRequest(let e),
                .encryptedActionCatalogResult(let e):
                return [e.senderNodeID, e.recipientNodeID]
            case .actionCatalogRequest(let r):
                return [r.callerNodeID, r.targetNodeID]
            case .actionCatalogResult(let r):
                return [r.callerNodeID, r.targetNodeID]
            case .p2pSignal(let s):
                return [s.from]
            case .p2pPresence(let p):
                return [p.node]
        }
    }

    var channel: KeepTalkingEnvelopeChannel {
        switch self {
            case .message,
                .attachment,
                .context,
                .node,
                .nodeStatus,
                .encryptedNodeStatus,
                .contextSync:
                return .chat
            case .actionCallRequest,
                .requestAck,
                .actionCallResult,
                .encryptedActionCallRequest,
                .encryptedRequestAck,
                .encryptedActionCallResult,
                .actionCatalogRequest,
                .actionCatalogResult,
                .encryptedActionCatalogRequest,
                .encryptedActionCatalogResult:
                return .actionCall
            case .p2pSignal, .p2pPresence:
                return .signaling
        }
    }
}

extension KeepTalkingConfig {
    func label(for channel: KeepTalkingEnvelopeChannel) -> String {
        switch channel {
            case .chat:
                return chatChannelLabel
            case .blob:
                return blobChannelLabel
            case .actionCall:
                return actionCallChannelLabel
            case .signaling:
                return signalingChannelLabel
        }
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
