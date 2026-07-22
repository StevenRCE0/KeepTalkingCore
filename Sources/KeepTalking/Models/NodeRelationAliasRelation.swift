import FluentKit
import Foundation

/// The grant policy joining a node relation to an alias mapping.
public final class KeepTalkingNodeRelationAliasRelation: Model,
    @unchecked Sendable
{
    public static let schema = "kt_node_relation_alias_relation"

    public typealias ApprovingContext =
        KeepTalkingNodeRelationApprovingContext

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "relation")
    public var relation: KeepTalkingNodeRelation

    @Parent(key: "alias")
    public var alias: KeepTalkingMapping

    @OptionalField(key: "approving_context")
    public var approvingContext: ApprovingContext?

    @OptionalField(key: "wake_handles")
    public var wakeHandles: [KeepTalkingPushWakeHandle]?

    @OptionalField(key: "permission")
    public var permission: KeepTalkingActionScope?

    @OptionalField(key: "allow_remote_confirmation")
    public var allowRemoteConfirmation: Bool?

    public init() {}

    init(
        id: UUID = UUID.v7(),
        relation: KeepTalkingNodeRelation,
        alias: KeepTalkingMapping,
        approvingContext: ApprovingContext,
        permission: KeepTalkingActionScope? = nil,
        allowRemoteConfirmation: Bool? = nil
    ) throws {
        self.id = id
        self.$relation.id = try relation.requireID()
        self.$alias.id = try alias.requireID()
        self.approvingContext = approvingContext
        self.wakeHandles = nil
        self.permission = permission
        self.allowRemoteConfirmation = allowRemoteConfirmation
    }

    public func applicable(in context: KeepTalkingContext?) -> Bool {
        approvingContext?.applicable(in: context) ?? false
    }
}
