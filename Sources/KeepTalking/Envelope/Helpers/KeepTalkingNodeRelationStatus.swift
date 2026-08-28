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

    /// Element-wise lenient decode for the advertised lists: a peer running a
    /// different build may advertise an action shape this build cannot decode
    /// (e.g. a payload case or primitive kind that no longer exists here).
    /// Drop that element instead of failing the whole node status — one stale
    /// advertisement must never cost the recipient every other grant in the
    /// broadcast.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toNodeID = try container.decode(UUID.self, forKey: .toNodeID)
        relationship = try container.decode(
            KeepTalkingRelationship.self,
            forKey: .relationship
        )
        actions = try container.decode(
            [FailableDecodable<KeepTalkingAdvertisedAction>].self,
            forKey: .actions
        ).compactMap(\.value)
        actionWakeRoutes =
            try container.decodeIfPresent(
                [FailableDecodable<KeepTalkingActionWakeRoute>].self,
                forKey: .actionWakeRoutes
            )?.compactMap(\.value) ?? []
    }
}

/// Decodes to nil instead of throwing, so one bad element in a wire array can
/// be dropped without failing the surrounding decode.
private struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
