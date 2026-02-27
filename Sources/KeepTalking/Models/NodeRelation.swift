//
//  NodeRelation.swift
//  KeepTalking
//
//  Created by 砚渤 on 23/02/2026.
//

import FluentKit
import Foundation

public enum KeepTalkingRelationship: Codable, Sendable, Equatable {
    case pending
    case owner
    case trusted([KeepTalkingContext])
    case trustedInAllContext

    public var isTrustedOrOwner: Bool {
        switch self {
        case .owner, .trusted, .trustedInAllContext:
            return true
        case .pending:
            return false
        }
    }

    public func allows(context: KeepTalkingContext?) -> Bool {
        switch self {
        case .owner, .trustedInAllContext:
            return true
        case .trusted(let contexts):
            guard let context else { return false }
            return contexts.contains(context)
        case .pending:
            return false
        }
    }
}

public final class KeepTalkingNodeRelation: Model, @unchecked Sendable {
    public static let schema = "kt_node_relation"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "relationship")
    public var relationship: KeepTalkingRelationship

    @Parent(key: "from")
    public var from: KeepTalkingNode

    @Parent(key: "to")
    public var to: KeepTalkingNode

    @Children(for: \.$relation)
    public var actionRelations: [KeepTalkingNodeRelationActionRelation]

    @Children(for: \.$relation)
    public var identityKeys: [KeepTalkingNodeIdentityKey]

    public init() {
        relationship = .pending
    }

    public init(
        id: UUID = UUID(),
        from: KeepTalkingNode,
        to: KeepTalkingNode,
        relationship: KeepTalkingRelationship,
    ) throws {
        self.id = id
        self.$from.id = try from.requireID()
        self.$to.id = try to.requireID()
        self.relationship = relationship
    }

    public func allows(context: KeepTalkingContext?) -> Bool {
        relationship.allows(context: context)
    }
}
