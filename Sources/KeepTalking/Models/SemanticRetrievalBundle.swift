import Foundation

/// Bundle that defines a permission-gated semantic search capability.
///
/// A `semanticRetrieval` action backed by this bundle lets other nodes
/// query the host's embedded thread memory. The `contextIDs` field
/// constrains which contexts are eligible to appear in results —
/// empty means no restriction. Tag scoping is resolved automatically
/// from the execution node's own DB at query time.
public struct KeepTalkingSemanticRetrievalBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    /// Context IDs the search is restricted to. Empty means no restriction.
    public var contextIDs: [UUID]

    public init(
        id: UUID = UUID(),
        name: String = "Search Thread Memory",
        indexDescription: String =
            "Search stored and live thread memory for earlier topics, facts, decisions, and unfinished work.",
        contextIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.contextIDs = contextIDs
    }
}
