//
//  NodeRelation.swift
//  KeepTalking
//
//  Created by 砚渤 on 23/02/2026.
//

import FluentKit
import Foundation



public final class KeepTalkingNodeRelation: Model, @unchecked Sendable {
    public static let schema = "kt_node_relation"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "authorised_actions")
    public var authorisedActionsData: Data

    @Field(key: "relationship")
    public var relationship: KeepTalkingRelationship

    @Parent(key: "from")
    public var from: KeepTalkingNode

    @Parent(key: "to")
    public var to: KeepTalkingNode

    @Siblings(
        through: KeepTalkingNodeRelationActionRelation.self,
        from: \.$relation,
        to: \.$action
    )
    public var authorisedActions: [KeepTalkingAction]

    public init() {
        authorisedActionsData = Data()
    }

    public init(
        id: UUID = UUID(),
        from: KeepTalkingNode,
        to: KeepTalkingNode,
        relationship: KeepTalkingRelationship,
        authorisedActionsData: Data = Data()
    ) throws {
        self.id = id
        self.$from.id = try from.requireID()
        self.$to.id = try to.requireID()
        self.relationship = relationship
        self.authorisedActionsData = authorisedActionsData
    }
}
