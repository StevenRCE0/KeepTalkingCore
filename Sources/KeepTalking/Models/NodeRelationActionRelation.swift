//
//  NodeRelationActionRelation.swift
//  KeepTalking
//
//  Created by 砚渤 on 23/02/2026.
//

import FluentKit
import Foundation

public final class KeepTalkingNodeRelationActionRelation: Model,
    @unchecked Sendable
{
    public static let schema = "kt_node_relation_action_relation"

    public enum ApprovingContext: Codable, Sendable {
        case all
        case context(KeepTalkingContext)
    }

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "relation")
    public var relation: KeepTalkingNodeRelation

    @Parent(key: "action")
    public var action: KeepTalkingAction

    @OptionalField(key: "approving_context")
    public var approvingContext: ApprovingContext?

    public init() {}

    init(
        id: UUID = UUID(),
        relation: KeepTalkingNodeRelation,
        action: KeepTalkingAction,
        approvingContext: ApprovingContext
    ) throws {
        self.id = id
        self.$relation.id = try relation.requireID()
        self.$action.id = try action.requireID()
        self.approvingContext = approvingContext
    }
}
