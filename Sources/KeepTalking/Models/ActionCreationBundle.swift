import Foundation

/// Bundle that defines the permission-gated action-creation capability.
///
/// An `actionCreation` action backed by this bundle lets other nodes ask this
/// host's user to create a new action and grant it back to the caller. Like
/// `KeepTalkingSemanticRetrievalBundle` it is a built-in capability — not a
/// generic primitive — so it never surfaces as a per-action tool; callers reach
/// it through the built-in `kt_create_action` meta tool, and the host answers
/// through the app-installed action-creation handler after user confirmation.
/// The `contextIDs` field constrains which contexts are eligible — empty means
/// no restriction.
public struct KeepTalkingActionCreationBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    /// Context IDs the capability is restricted to. Empty means no restriction.
    public var contextIDs: [UUID]

    public init(
        id: UUID = UUID.v7(),
        name: String = "Create Action",
        indexDescription: String =
            "Asks the host's user to create a new action and grant it to the caller's context. Keep the proposed action's description short (one sentence, ≤12 words) and limited to what the action does — you cannot see the host environment, existing actions, or how the user will discover it, so do not speculate about implementations, detailed scripts, callers, triggers, or surrounding UI. The user on the other end reviews and confirms — and may modify the action — before anything is created and granted.",
        contextIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.contextIDs = contextIDs
    }
}
