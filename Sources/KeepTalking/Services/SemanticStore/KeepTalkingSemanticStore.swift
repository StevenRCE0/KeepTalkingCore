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

    /// Hybrid (semantic + keyword) search: return the top-k threads most
    /// relevant to the query.
    ///
    /// - Parameters:
    ///   - query: the natural-language text matched against the indexed thread
    ///     documents, both semantically and by keyword.
    ///   - topK: the maximum number of results to return. Callers treat it as an
    ///     upper bound and re-rank the returned results themselves.
    ///   - threshold: the minimum combined relevance score (0…1) a
    ///     result must clear, or `nil` to use the store's default. Unattended
    ///     retrieval (agents) should pass a low value for recall; interactive
    ///     search should pass a higher value for precision.
    /// - Returns: at most `topK` results, each pairing a matching thread's UUID
    ///   with its indexed document text and relevance score.
    func search(
        query: String,
        topK: Int,
        threshold: Float?
    ) async throws -> [KeepTalkingSemanticSearchResult]

    /// Remove all documents from the index.
    func reset() async throws

    /// Number of documents currently indexed.
    func documentCount() async throws -> Int

    /// Return all indexed documents (for debugging).
    func allDocuments() async throws -> [(id: UUID, text: String)]
}
