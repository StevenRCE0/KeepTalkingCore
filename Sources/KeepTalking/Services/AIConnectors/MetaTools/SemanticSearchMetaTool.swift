import FluentKit
import Foundation
import OpenAI

extension KeepTalkingClient {
    func executeSearchThreadsToolCall(
        rawArguments: String,
        context: KeepTalkingContext
    ) async throws -> String {
        guard let callback = semanticSearchCallback else {
            return jsonString([
                "ok": false,
                "error": "Semantic search is not available on this node.",
            ])
        }

        let args = (try? decodeToolArguments(rawArguments)) ?? [:]
        guard
            let query = args["query"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty
        else {
            return jsonString([
                "ok": false,
                "error": "query is required.",
            ])
        }
        let topK = args["top_k"]?.intValue ?? 5
        let contextID = try context.requireID()

        let contextTagIDs: [UUID] = (try? await KeepTalkingMapping.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$kind == .tag)
            .all()
            .compactMap(\.id)) ?? []

        let results: [KeepTalkingSemanticSearchResult]
        do {
            // Scope to the current context by default; other nodes granted a
            // narrower permission will have their contextIDs pre-set in the bundle.
            results = try await callback(query, topK, [contextID], contextTagIDs)
        } catch {
            return jsonString([
                "ok": false,
                "error": error.localizedDescription,
            ])
        }

        let aliasLookup = try await aliasLookup()

        let items: [[String: Any]] = results.map { result in
            let alias =
                aliasLookup.alias(for: .thread(result.threadID))
                ?? result.threadID.uuidString.prefix(8).lowercased()
                    .description
            return [
                "thread_id": result.threadID.uuidString.lowercased(),
                "label": alias,
                "score": result.score,
                "excerpt": String(result.text.prefix(400)),
            ]
        }

        return jsonString([
            "ok": true,
            "query": query,
            "count": items.count,
            "results": items,
        ])
    }
}
