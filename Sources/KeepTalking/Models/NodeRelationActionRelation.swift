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
        case contexts([KeepTalkingContext])
    }

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "relation")
    public var relation: KeepTalkingNodeRelation

    @Parent(key: "action")
    public var action: KeepTalkingAction

    @OptionalField(key: "approving_context")
    public var approvingContext: ApprovingContext?

    @OptionalField(key: "wake_handles")
    public var wakeHandles: [KeepTalkingPushWakeHandle]?

    /// Per-grant permission constraint — filesystem R/W/X mask or MCP tool allowlist.
    /// `nil` means no restriction (full access for the applicable action type).
    @OptionalField(key: "permission")
    public var permission: KeepTalkingGrantPermission?

    public init() {}

    init(
        id: UUID = UUID(),
        relation: KeepTalkingNodeRelation,
        action: KeepTalkingAction,
        approvingContext: ApprovingContext,
        permission: KeepTalkingGrantPermission? = nil
    ) throws {
        self.id = id
        self.$relation.id = try relation.requireID()
        self.$action.id = try action.requireID()
        self.approvingContext = approvingContext
        self.wakeHandles = nil
        self.permission = permission
    }

    public func applicable(in context: KeepTalkingContext?) -> Bool {
        switch approvingContext {
            case .all:
                return true
            case .contexts(let contexts):
                return context == nil ? false : contexts.contains(context!)
            case nil:
                return false
        }
    }

}
