//
//  KeepTalkingNodeStatus.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

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
