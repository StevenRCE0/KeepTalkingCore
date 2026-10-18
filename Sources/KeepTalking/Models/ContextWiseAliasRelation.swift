import FluentKit
import Foundation

/// The sharing decision joining a context to one of the local node's own
/// alias rows: whether that alias — the global one, or the one scoped to the
/// context — is shown to the context's members.
///
/// Shaped like `KeepTalkingNodeRelationAliasRelation`, with a context as the
/// audience instead of a node relation. It decides presentation only; it
/// grants nothing.
///
/// No row means undecided, which shares by default (the global alias still
/// only to trusted nodes). A row records the user's choice either way, and
/// its presence is what tells the host the user has decided for that context.
public final class KeepTalkingContextWiseAliasRelation: Model, @unchecked Sendable {
    public static let schema = "kt_context_wise_alias_relation"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @Parent(key: "alias")
    public var alias: KeepTalkingMapping

    @Field(key: "is_shared")
    public var isShared: Bool

    public init() {}

    init(
        id: UUID = UUID.v7(),
        contextID: UUID,
        aliasID: UUID,
        isShared: Bool
    ) {
        self.id = id
        self.$context.id = contextID
        self.$alias.id = aliasID
        self.isShared = isShared
    }
}
