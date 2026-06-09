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

    /// Per-grant scope — the unified `.all | .verbs(Set<KeepTalkingActionVerb>)`
    /// grant. `nil` means no restriction (full access). Stored in the `permission`
    /// JSON column (name retained; the DB is recreated fresh on cutover).
    @OptionalField(key: "permission")
    public var permission: KeepTalkingActionScope?

    /// WS3 (cross-device authorization): B's per-peer opt-in that this grantee's
    /// blocking calls may be confirmed off-device by the owner (macOS broadcast to
    /// co-owned devices). `nil`/`false` = not opted in. Column added ahead of WS3
    /// so the behavior can land without another DB recreation; no logic uses it yet.
    @OptionalField(key: "allow_remote_confirmation")
    public var allowRemoteConfirmation: Bool?

    public init() {}

    init(
        id: UUID = UUID(),
        relation: KeepTalkingNodeRelation,
        action: KeepTalkingAction,
        approvingContext: ApprovingContext,
        permission: KeepTalkingActionScope? = nil,
        allowRemoteConfirmation: Bool? = nil
    ) throws {
        self.id = id
        self.$relation.id = try relation.requireID()
        self.$action.id = try action.requireID()
        self.approvingContext = approvingContext
        self.wakeHandles = nil
        self.permission = permission
        self.allowRemoteConfirmation = allowRemoteConfirmation
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
