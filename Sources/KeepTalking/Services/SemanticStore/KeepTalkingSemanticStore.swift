import Foundation

/// A result from semantic search over indexed threads.
public struct KeepTalkingSemanticSearchResult: Sendable {
    public let threadID: UUID
    public let text: String
    public let score: Float

    public init(threadID: UUID, text: String, score: Float) {
        self.threadID = threadID
        self.text = text
        self.score = score
    }
}

/// Abstracts a vector store for thread-level semantic search.
/// The backing implementation (e.g. VecturaKit) is injected by the app layer.
public protocol KeepTalkingSemanticStore: Sendable {

    /// Index a thread as a document. Thread UUID becomes the document ID.
    func indexThread(id: UUID, text: String) async throws

    /// Update the document text for an already-indexed thread.
    func updateThread(id: UUID, text: String) async throws

    /// Remove a thread's document from the index.
    func removeThread(id: UUID) async throws

    /// Semantic search: return the top-k threads most relevant to the query.
    func search(query: String, topK: Int) async throws -> [KeepTalkingSemanticSearchResult]

    /// Remove all documents from the index.
    func reset() async throws

    /// Number of documents currently indexed.
    func documentCount() async throws -> Int

    /// Return all indexed documents (for debugging).
    func allDocuments() async throws -> [(id: UUID, text: String)]
}
