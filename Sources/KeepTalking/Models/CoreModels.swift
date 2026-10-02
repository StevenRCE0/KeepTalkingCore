import FluentKit
import Foundation

/// Runtime configuration of one client: its context, its node, and node-local
/// tuning. The transport isn't configured here — it's process-wide (see
/// `KeepTalkingTransport`).
public struct KeepTalkingConfig: Sendable {
    public let contextID: UUID
    public let node: UUID
    public let recentAttachmentSyncLookback: TimeInterval

    /// Creates a configuration for a single KeepTalking node session.
    public init(
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        node: UUID = UUID(),
        recentAttachmentSyncLookback: TimeInterval = 14 * 24 * 60 * 60,
        contextSyncChunkSize: Int = KeepTalkingContextSyncMetadata.defaultChunkSize
    ) {
        self.contextID = contextID
        self.node = node
        self.recentAttachmentSyncLookback = max(0, recentAttachmentSyncLookback)
        self.contextSyncChunkSize = max(1, contextSyncChunkSize)
    }

    /// Messages per chunk in a context-sync summary. Chunks are the unit of
    /// divergence detection: a smaller size localizes a mismatch more precisely
    /// at the cost of a larger summary.
    ///
    /// A node-local tuning knob, not a per-context one. It used to be persisted
    /// on the context row alongside a cached summary, which meant a full-table
    /// read and re-digest on every batch that saved a message — all to carry
    /// this single number, which no production caller ever changed.
    public let contextSyncChunkSize: Int

    /// Returns a copy of the configuration scoped to a different context.
    public func withContextID(_ contextID: UUID) -> KeepTalkingConfig {
        KeepTalkingConfig(
            contextID: contextID,
            node: node,
            recentAttachmentSyncLookback: recentAttachmentSyncLookback,
            contextSyncChunkSize: contextSyncChunkSize
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
    /// Applies outstanding migrations. Construction does not do this, so a
    /// store must be migrated before it is queried.
    func migrate() async throws
    func reset() async throws

    /// Drains in-flight queries, then releases the thread pool and event-loop
    /// group. Idempotent.
    ///
    /// Call this before dropping the last reference to a store you are
    /// retiring — switching to another identity's database, for instance.
    /// Merely releasing it runs the teardown from `deinit` on a background
    /// queue, which can tear the event loop down underneath a query still in
    /// flight; NIO then trips its `EventLoopFuture.deinit` debug assertion and
    /// the process traps.
    func shutdown() async
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
