import Foundation

/// Bundle that defines a permission-gated semantic search capability.
///
/// A `semanticRetrieval` action backed by this bundle lets other nodes
/// query the host's embedded thread memory. The `contextIDs` and `tagTitles`
/// fields constrain which threads are eligible to appear in results —
/// empty arrays mean "all" (no filter).  These constraints are set at
/// bundle-creation time and enforced at query time, so granting this
/// action to another node with `.context(X)` scope gives them a
/// context-scoped semantic-search window into your data.
public struct KeepTalkingSemanticRetrievalBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    /// Context IDs the search is restricted to. Empty means no restriction.
    public var contextIDs: [UUID]
    /// Tag titles the search is restricted to. Empty means no restriction.
    public var tagTitles: [String]

    public init(
        id: UUID = UUID(),
        name: String = "Search Thread Memory",
        indexDescription: String =
            "Search stored and live thread memory for earlier topics, facts, decisions, and unfinished work.",
        contextIDs: [UUID] = [],
        tagTitles: [String] = []
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.contextIDs = contextIDs
        self.tagTitles = tagTitles
    }
}
