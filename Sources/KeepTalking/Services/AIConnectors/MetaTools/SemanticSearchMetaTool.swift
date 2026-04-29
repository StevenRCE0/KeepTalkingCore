import AIProxy
import FluentKit
import Foundation
import MCP

// Sendable result item used to safely pass data across task boundaries.
private struct SemanticSearchItem: Sendable {
    let threadID: String
    let label: String
    let score: Double
    let excerpt: String
    let nodeID: String
    let nodeLabel: String
}

extension KeepTalkingClient {
    func executeSearchThreadsToolCall(
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext
    ) async throws -> String {
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

        // MARK: - Local search

        var localItems: [SemanticSearchItem] = []
        if let callback = semanticSearchCallback {
            let contextTagIDs: [UUID] =
                (try? await KeepTalkingMapping
                    .query(on: localStore.database)
                    .filter(\.$context.$id == contextID)
                    .filter(\.$kind == .tag)
                    .all()
                    .compactMap(\.id)) ?? []

            let localResults: [KeepTalkingSemanticSearchResult]
            do {
                localResults = try await callback(query, topK, [contextID], contextTagIDs)
            } catch {
                localResults = []
                onLog?("[search-threads] local search failed error=\(error.localizedDescription)")
            }

            let aliasLookup = try await aliasLookup()
            let nodeLabel =
                aliasLookup.alias(for: .node(config.node))
                ?? String(config.node.uuidString.prefix(8).lowercased())
            let nodeID = config.node.uuidString.lowercased()

            localItems = localResults.map { result in
                let alias =
                    aliasLookup.alias(for: .thread(result.threadID))
                    ?? String(result.threadID.uuidString.prefix(8).lowercased())
                return SemanticSearchItem(
                    threadID: result.threadID.uuidString.lowercased(),
                    label: alias,
                    score: Double(result.score),
                    excerpt: String(result.text.prefix(400)),
                    nodeID: nodeID,
                    nodeLabel: nodeLabel
                )
            }
        }

        // MARK: - Remote fan-out

        let remoteEntries = runtimeCatalog.remoteSemanticRetrievalActions
        var remoteItems: [SemanticSearchItem] = []

        if !remoteEntries.isEmpty {
            remoteItems = await withTaskGroup(
                of: [SemanticSearchItem].self,
                returning: [SemanticSearchItem].self
            ) { group in
                for entry in remoteEntries {
                    group.addTask {
                        await self.fetchRemoteSemanticSearchItems(
                            entry: entry,
                            query: query,
                            topK: topK,
                            context: context
                        )
                    }
                }
                var collected: [SemanticSearchItem] = []
                for await items in group {
                    collected.append(contentsOf: items)
                }
                return collected
            }
        }

        // MARK: - Merge and sort by score descending

        var allItems = localItems + remoteItems
        allItems.sort { $0.score > $1.score }

        return jsonString([
            "ok": true,
            "query": query,
            "count": allItems.count,
            "results": allItems.map {
                [
                    "thread_id": $0.threadID,
                    "label": $0.label,
                    "score": $0.score,
                    "excerpt": $0.excerpt,
                    "node_id": $0.nodeID,
                    "node_label": $0.nodeLabel,
                ] as [String: Any]
            },
        ])
    }

    // MARK: - Private helpers

    private func fetchRemoteSemanticSearchItems(
        entry: KeepTalkingSemanticRetrievalCatalogEntry,
        query: String,
        topK: Int,
        context: KeepTalkingContext
    ) async -> [SemanticSearchItem] {
        let call = KeepTalkingActionCall(
            action: entry.actionID,
            arguments: [
                "query": .string(query),
                "top_k": .int(topK),
            ]
        )
        let result: KeepTalkingActionCallResult
        do {
            result = try await dispatchActionCall(
                actionOwner: entry.ownerNodeID,
                call: call,
                context: context
            )
        } catch {
            onLog?(
                "[search-threads] remote fan-out failed node=\(entry.ownerNodeID.uuidString.lowercased()) action=\(entry.actionID.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            return []
        }

        guard !result.isError else {
            onLog?(
                "[search-threads] remote fan-out error node=\(entry.ownerNodeID.uuidString.lowercased()) action=\(entry.actionID.uuidString.lowercased()) message=\(result.errorMessage ?? "unknown")"
            )
            return []
        }

        return parseRemoteSemanticSearchItems(result, ownerNodeID: entry.ownerNodeID)
    }

    private func parseRemoteSemanticSearchItems(
        _ result: KeepTalkingActionCallResult,
        ownerNodeID: UUID
    ) -> [SemanticSearchItem] {
        guard
            let textContent = result.content.compactMap({ content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }).first,
            let data = textContent.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["ok"] as? Bool == true,
            let rawResults = json["results"] as? [[String: Any]]
        else {
            return []
        }

        let fallbackNodeLabel = String(ownerNodeID.uuidString.prefix(8).lowercased())
        let nodeID = ownerNodeID.uuidString.lowercased()

        return rawResults.compactMap { item -> SemanticSearchItem? in
            guard
                let threadID = item["thread_id"] as? String,
                let score = item["score"] as? Double
            else { return nil }
            let label = (item["label"] as? String) ?? String(threadID.prefix(8))
            let excerpt = (item["excerpt"] as? String) ?? ""
            let nodeLabel = (item["node_label"] as? String) ?? fallbackNodeLabel
            return SemanticSearchItem(
                threadID: threadID,
                label: label,
                score: score,
                excerpt: excerpt,
                nodeID: nodeID,
                nodeLabel: nodeLabel
            )
        }
    }
}
