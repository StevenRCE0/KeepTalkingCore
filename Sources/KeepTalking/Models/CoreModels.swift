import FluentKit
import Foundation

/// Runtime configuration shared by the client, transports, and executors.
public struct KeepTalkingConfig: Sendable {
    public static let signalingChannel = "keep-talking.signaling"
    public static let chatChannelPrefix = "keep-talking.chat"
    public static let blobChannelPrefix = "keep-talking.blob"
    public static let actionCallChannelPrefix = "keep-talking.action_call"

    public let contextID: UUID
    public let node: UUID
    public let p2pAttemptTimeoutSeconds: TimeInterval
    public let sfuEndpoint: SFUEndpoint?
    public let recentAttachmentSyncLookback: TimeInterval

    public struct SFUEndpoint: Sendable, Hashable {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16 = 9701) {
            self.host = host
            self.port = port
        }
    }

    /// Creates a configuration for a single KeepTalking node session.
    public init(
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        node: UUID = UUID(),
        p2pAttemptTimeoutSeconds: TimeInterval = 5,
        sfuEndpoint: SFUEndpoint? = nil,
        recentAttachmentSyncLookback: TimeInterval = 14 * 24 * 60 * 60
    ) {
        self.contextID = contextID
        self.node = node
        self.p2pAttemptTimeoutSeconds = p2pAttemptTimeoutSeconds
        self.sfuEndpoint = sfuEndpoint
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
            contextID: contextID,
            node: node,
            p2pAttemptTimeoutSeconds: p2pAttemptTimeoutSeconds,
            sfuEndpoint: sfuEndpoint,
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
