//
//  KeepTalkingNodeStatus.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation
import NIOConcurrencyHelpers

// TODO: make this opaque DTO
public struct KeepTalkingNodeStatus: Codable, Sendable {
    public let node: KeepTalkingNode
    public let contextID: UUID
    public let nodeRelations: [KeepTalkingNodeRelationStatus]
    /// When the sender built this snapshot, in its own milliseconds, strictly
    /// increasing per sender process. Snapshots ride the bulk lane, a stream
    /// each, so two can arrive out of order: receivers keep the newest.
    public let issuedAtMs: UInt64

    public init(
        node: KeepTalkingNode,
        contextID: UUID,
        nodeRelations: [KeepTalkingNodeRelationStatus],
        issuedAtMs: UInt64 = KeepTalkingNodeStatus.nextIssuedAtMs()
    ) {
        self.node = node
        self.contextID = contextID
        self.nodeRelations = nodeRelations
        self.issuedAtMs = issuedAtMs
    }

    private static let lastIssuedAtMs = NIOLockedValueBox<UInt64>(0)

    /// Wall-clock milliseconds, nudged forward so a clock that steps back
    /// never makes a newer snapshot look older.
    public static func nextIssuedAtMs(now: Date = Date()) -> UInt64 {
        let wall = UInt64(max(now.timeIntervalSince1970, 0) * 1000)
        return lastIssuedAtMs.withLockedValue { last in
            last = max(last + 1, wall)
            return last
        }
    }
}

/// The newest node-status snapshot applied per (sender, context), so an
/// older one that arrives later is dropped instead of undoing it.
final class KeepTalkingNodeStatusWatermarks: Sendable {
    private struct Key: Hashable {
        let node: UUID
        let context: UUID
    }

    private let applied = NIOLockedValueBox<[Key: UInt64]>([:])

    /// Whether `status` is newer than every snapshot admitted for its sender
    /// and context; admitting it raises the mark.
    func admit(_ status: KeepTalkingNodeStatus) -> Bool {
        guard let node = status.node.id else { return true }
        let key = Key(node: node, context: status.contextID)
        return applied.withLockedValue { applied in
            guard (applied[key] ?? 0) < status.issuedAtMs else { return false }
            applied[key] = status.issuedAtMs
            return true
        }
    }
}
