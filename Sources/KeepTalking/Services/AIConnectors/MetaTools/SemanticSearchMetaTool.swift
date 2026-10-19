import AIProxy
import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    func executeSearchThreadsToolCall(
        rawArguments: String,
        remoteSemanticRetrievalActions remoteEntries: [KeepTalkingSemanticRetrievalCatalogEntry],
        context: KeepTalkingContext,
        handOver: ThreadSearchHandOver = .unconsulted,
        publisher: AIOrchestrator.ToolHintPublisher? = nil
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
        let aliasLookup = try await aliasLookup()
        let hits = try await threadSearchHits(
            query: query, topK: topK, context: context, remoteEntries: remoteEntries, aliasLookup: aliasLookup
        )

        var read: [String: RetrievedThread] = [:]
        for hit in hits {
            guard let threadID = UUID(uuidString: hit.threadID) else { continue }
            do {
                read[hit.threadID] = try await retrievedThread(
                    threadID, score: hit.score, aliasLookup: aliasLookup, ceilingTokens: handOver.readCeilingTokens
                )
            } catch {
                onLog?(
                    "[search-threads] reading thread \(hit.threadID.prefix(8)) failed error=\(error.localizedDescription)"
                )
            }
        }
        let deliveries = handOver.deliveries(hits.compactMap { read[$0.threadID] })
        let consultation = await handOver.consult(
            deliveries.filter { $0.delivery == .answered }.map(\.thread), query: query, on: self
        )
        let result = handOver.toolResult(
            query: query, hits: hits, read: read, deliveries: deliveries, consultation: consultation
        )
        await publishRevealedThreads(
            deliveries.filter { $0.delivery == .verbatim || $0.delivery == .answered }.map(\.thread.thread.threadID),
            query: query,
            publisher: publisher
        )
        onLog?("[search-threads] query=\"\(query.prefix(80))\" hits=\(hits.count) \(result.log)")
        return jsonString(result.payload)
    }

    /// Ranked hits here and on every peer that shares its thread memory,
    /// best first, one per thread.
    private func threadSearchHits(
        query: String,
        topK: Int,
        context: KeepTalkingContext,
        remoteEntries: [KeepTalkingSemanticRetrievalCatalogEntry],
        aliasLookup: KeepTalkingAliasLookup
    ) async throws -> [ThreadSearchHit] {
        let contextID = try context.requireID()
        let localResults: [KeepTalkingSemanticSearchResult]
        do {
            let scopes = try await Self.retrievableSemanticMemoryScopes(
                for: contextID,
                on: localStore.database
            )
            localResults = try await Self.retrieveSemanticMemory(
                query: query,
                topK: topK,
                scopes: scopes,
                semanticSearch: semanticSearchCallback,
                on: localStore.database
            )
        } catch {
            localResults = []
            onLog?("[search-threads] local search failed error=\(error.localizedDescription)")
        }

        let nodeLabel =
            aliasLookup.alias(for: .node(config.node))
            ?? String(config.node.uuidString.prefix(8).lowercased())
        let nodeID = config.node.uuidString.lowercased()
        let localHits = localResults.map { result in
            ThreadSearchHit(
                threadID: result.threadID.uuidString.lowercased(),
                label: aliasLookup.alias(for: .thread(result.threadID))
                    ?? String(result.threadID.uuidString.prefix(8).lowercased()),
                score: Double(result.score),
                excerpt: String(result.text.prefix(400)),
                nodeID: nodeID,
                nodeLabel: nodeLabel
            )
        }

        let remoteHits = await withTaskGroup(of: [ThreadSearchHit].self) { group in
            for entry in remoteEntries {
                group.addTask {
                    await self.fetchRemoteSemanticSearchItems(entry: entry, query: query, topK: topK, context: context)
                }
            }
            var collected: [ThreadSearchHit] = []
            for await hits in group { collected.append(contentsOf: hits) }
            return collected
        }

        var seen = Set<String>()
        return (localHits + remoteHits)
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.threadID).inserted }
    }

    // MARK: - Private helpers

    private func fetchRemoteSemanticSearchItems(
        entry: KeepTalkingSemanticRetrievalCatalogEntry,
        query: String,
        topK: Int,
        context: KeepTalkingContext
    ) async -> [ThreadSearchHit] {
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
    ) -> [ThreadSearchHit] {
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

        return rawResults.compactMap { item -> ThreadSearchHit? in
            guard
                let threadID = item["thread_id"] as? String,
                let score = item["score"] as? Double
            else { return nil }
            let label = (item["label"] as? String) ?? String(threadID.prefix(8))
            let excerpt = (item["excerpt"] as? String) ?? ""
            let nodeLabel = (item["node_label"] as? String) ?? fallbackNodeLabel
            return ThreadSearchHit(
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
