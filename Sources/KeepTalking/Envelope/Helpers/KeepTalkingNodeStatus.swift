//
//  KeepTalkingNodeStatus.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

// TODO: make this opaque DTO
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
