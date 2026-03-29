//
//  KeepTalkingNodeRelationStatus.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

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
