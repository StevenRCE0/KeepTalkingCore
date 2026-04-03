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

    /// Returns a copy of the configuration targeting a specific remote peer for P2P negotiation.
    public func withP2PPreferredRemoteID(_ remoteID: String?) -> KeepTalkingConfig {
        KeepTalkingConfig(
            signalURL: signalURL,
            contextID: contextID,
            node: node,
            p2pPreferredRemoteID: remoteID,
            p2pAttemptTimeoutSeconds: p2pAttemptTimeoutSeconds,
            p2pStunServers: p2pStunServers,
            recentAttachmentSyncLookback: recentAttachmentSyncLookback
        )
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
    func reset() async throws
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
