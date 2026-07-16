import FluentKit
import Foundation

extension KeepTalkingClient {
    public static func retrievableSemanticMemoryScopes(
        for contextID: UUID,
        on database: any Database
    ) async throws -> [KeepTalkingSemanticMemoryScope] {
        try await retrievableSemanticMemoryScopes(
            for: [contextID],
            on: database
        )
    }

    public static func retrievableSemanticMemoryScopes(
        for contextIDs: [UUID],
        on database: any Database
    ) async throws -> [KeepTalkingSemanticMemoryScope] {
        let requestedContextIDs = Set(contextIDs)
        guard !requestedContextIDs.isEmpty else { return [] }

        let threads = try await retrievableSemanticThreads(on: database)
        let threadByID = Dictionary(
            uniqueKeysWithValues: threads.compactMap { thread in
                thread.id.map { ($0, thread) }
            }
        )
        let mappings = try await KeepTalkingMapping.query(on: database)
            .filter(\.$kind == .tag)
            .filter(\.$deletedAt == nil)
            .all()
        let contextTags = mappings.filter { $0.$context.id != nil }
        let threadTags = mappings.filter { $0.thread != nil }

        var scopes: [KeepTalkingSemanticMemoryScope.Target: KeepTalkingSemanticMemoryScope] = [:]

        for contextID in requestedContextIDs.sorted(by: uuidAscending) {
            let directThreadIDs =
                threads
                .filter { $0.$context.id == contextID }
                .compactMap(\.id)
                .sorted(by: uuidAscending)
            let tags =
                contextTags
                .filter { $0.$context.id == contextID }
                .map(semanticMemoryTag)
                .uniquedAndSorted()

            if !directThreadIDs.isEmpty {
                let scope = KeepTalkingSemanticMemoryScope(
                    target: .context(contextID),
                    contextID: contextID,
                    threadIDs: directThreadIDs,
                    matchingTags: tags
                )
                scopes[scope.target] = scope
            }

            let tagKeys = Set(tags.map(SemanticMemoryTagKey.init))
            guard !tagKeys.isEmpty else { continue }

            let matchingContextTags = contextTags.filter {
                $0.$context.id != contextID
                    && tagKeys.contains(SemanticMemoryTagKey($0))
            }
            var contextTagsByID: [UUID: [KeepTalkingMapping]] = [:]
            for mapping in matchingContextTags {
                guard let matchingContextID = mapping.$context.id else { continue }
                contextTagsByID[matchingContextID, default: []].append(mapping)
            }
            for (matchingContextID, matchingTags) in contextTagsByID {
                let matchingThreadIDs =
                    threads
                    .filter { $0.$context.id == matchingContextID }
                    .compactMap(\.id)
                    .sorted(by: uuidAscending)
                guard !matchingThreadIDs.isEmpty else { continue }

                let target = KeepTalkingSemanticMemoryScope.Target.context(matchingContextID)
                let priorTags = scopes[target]?.matchingTags ?? []
                scopes[target] = KeepTalkingSemanticMemoryScope(
                    target: target,
                    contextID: matchingContextID,
                    threadIDs: matchingThreadIDs,
                    matchingTags: (priorTags + matchingTags.map(semanticMemoryTag))
                        .uniquedAndSorted()
                )
            }

            let matchingMappings = threadTags.filter {
                tagKeys.contains(SemanticMemoryTagKey($0))
            }
            var mappingsByThreadID: [UUID: [KeepTalkingMapping]] = [:]
            for mapping in matchingMappings {
                guard let threadID = mapping.thread else { continue }
                mappingsByThreadID[threadID, default: []].append(mapping)
            }
            for (threadID, mappings) in mappingsByThreadID {
                guard let thread = threadByID[threadID] else { continue }
                let target = KeepTalkingSemanticMemoryScope.Target.thread(threadID)
                let priorTags = scopes[target]?.matchingTags ?? []
                scopes[target] = KeepTalkingSemanticMemoryScope(
                    target: target,
                    contextID: thread.$context.id,
                    threadIDs: [threadID],
                    matchingTags: (priorTags + mappings.map(semanticMemoryTag))
                        .uniquedAndSorted()
                )
            }
        }

        return scopes.values.sorted { lhs, rhs in
            semanticMemoryScopeSortKey(lhs) < semanticMemoryScopeSortKey(rhs)
        }
    }

    public static func retrieveSemanticMemory(
        query: String,
        topK: Int,
        scopes: [KeepTalkingSemanticMemoryScope],
        semanticSearch: SemanticSearchCallback?,
        on database: any Database
    ) async throws -> [KeepTalkingSemanticSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedThreadIDs = Set(scopes.flatMap(\.threadIDs))
        guard !query.isEmpty, topK > 0, !allowedThreadIDs.isEmpty else {
            return []
        }

        let threads = try await KeepTalkingThread.query(on: database)
            .filter(\.$id ~~ Array(allowedThreadIDs))
            .all()

        async let semanticResults = semanticEnhancements(
            query: query,
            topK: topK,
            allowedThreadIDs: allowedThreadIDs,
            semanticSearch: semanticSearch
        )

        var documents: [(id: UUID, text: String)] = []
        documents.reserveCapacity(threads.count)
        for thread in threads {
            guard let id = thread.id else { continue }
            let text = try await threadDocumentText(for: thread, on: database)
            guard !text.isEmpty else { continue }
            documents.append((id: id, text: text))
        }

        return fuseSemanticMemoryResults(
            semantic: await semanticResults,
            lexical: lexicalSemanticMemoryResults(
                query: query,
                documents: documents,
                limit: max(topK * 3, topK)
            ),
            documents: documents,
            limit: topK
        )
    }
}

private struct SemanticMemoryTagKey: Hashable {
    let namespace: String?
    let normalizedValue: String

    init(_ mapping: KeepTalkingMapping) {
        namespace = mapping.namespace
        normalizedValue = mapping.normalizedValue
    }

    init(_ tag: KeepTalkingSemanticMemoryScope.Tag) {
        namespace = tag.namespace
        normalizedValue = tag.normalizedValue
    }
}

private func semanticMemoryTag(
    _ mapping: KeepTalkingMapping
) -> KeepTalkingSemanticMemoryScope.Tag {
    KeepTalkingSemanticMemoryScope.Tag(
        namespace: mapping.namespace,
        value: mapping.value,
        normalizedValue: mapping.normalizedValue,
        colorHex: mapping.colorHex
    )
}

private func semanticMemoryScopeSortKey(
    _ scope: KeepTalkingSemanticMemoryScope
) -> String {
    switch scope.target {
        case .context(let id):
            return "0:\(id.uuidString)"
        case .thread(let id):
            return "1:\(id.uuidString)"
    }
}

private func uuidAscending(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}

extension Array where Element == KeepTalkingSemanticMemoryScope.Tag {
    fileprivate func uniquedAndSorted() -> [Element] {
        var seen: Set<SemanticMemoryTagKey> = []

        return filter { seen.insert(SemanticMemoryTagKey($0)).inserted }
            .sorted {
                let lhs = [($0.namespace ?? ""), $0.normalizedValue]
                let rhs = [($1.namespace ?? ""), $1.normalizedValue]
                return lhs.lexicographicallyPrecedes(rhs)
            }
    }
}

extension KeepTalkingClient {
    fileprivate static func retrievableSemanticThreads(
        on database: any Database
    ) async throws -> [KeepTalkingThread] {
        let threads = try await KeepTalkingThread.query(on: database).all()
        let messages = try await KeepTalkingContextMessage.query(on: database)
            .sort(\.$timestamp)
            .all()
        let messagesByContextID = Dictionary(
            grouping: messages,
            by: { $0.$context.id }
        )

        var retrievableThreads: [KeepTalkingThread] = []
        for thread in threads {
            guard
                thread.resolvedMessageRange(
                    in: messagesByContextID[thread.$context.id] ?? []
                ) != nil
            else { continue }
            retrievableThreads.append(thread)
        }

        return retrievableThreads
    }

    fileprivate static func semanticEnhancements(
        query: String,
        topK: Int,
        allowedThreadIDs: Set<UUID>,
        semanticSearch: SemanticSearchCallback?
    ) async -> [KeepTalkingSemanticSearchResult] {
        guard let semanticSearch else { return [] }
        let results =
            (try? await semanticSearch(query, max(topK * 3, topK))) ?? []

        return results.filter { allowedThreadIDs.contains($0.threadID) }
    }

    fileprivate static func lexicalSemanticMemoryResults(
        query: String,
        documents: [(id: UUID, text: String)],
        limit: Int
    ) -> [KeepTalkingSemanticSearchResult] {
        let tokens = semanticMemoryTokens(query)
        guard !tokens.isEmpty else { return [] }
        let foldedQuery = foldSemanticMemoryText(query)

        return documents.compactMap { document -> KeepTalkingSemanticSearchResult? in
            let text = foldSemanticMemoryText(document.text)
            var score: Float = 0
            var matchedTokenCount = 0
            for token in tokens {
                let count = semanticMemoryOccurrenceCount(of: token, in: text)
                guard count > 0 else { continue }
                matchedTokenCount += 1
                score += Float(1 + log(Double(count)))
            }
            guard matchedTokenCount > 0 else { return nil }
            score *= Float(matchedTokenCount) / Float(tokens.count)
            if tokens.count > 1, text.contains(foldedQuery) {
                score += 4
            }

            return KeepTalkingSemanticSearchResult(
                threadID: document.id,
                text: document.text,
                score: score
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }

            return uuidAscending($0.threadID, $1.threadID)
        }
        .prefix(limit)
        .map { $0 }
    }

    fileprivate static func fuseSemanticMemoryResults(
        semantic: [KeepTalkingSemanticSearchResult],
        lexical: [KeepTalkingSemanticSearchResult],
        documents: [(id: UUID, text: String)],
        limit: Int
    ) -> [KeepTalkingSemanticSearchResult] {
        let reciprocalRankConstant: Float = 60
        let documentText = Dictionary(uniqueKeysWithValues: documents)
        var scores: [UUID: Float] = [:]

        for results in [lexical, semantic] {
            var seen: Set<UUID> = []
            for (rank, result) in results.enumerated()
            where seen.insert(result.threadID).inserted {
                scores[result.threadID, default: 0] +=
                    1 / (reciprocalRankConstant + Float(rank + 1))
            }
        }

        let maximumScore = scores.values.max() ?? 1

        return scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return uuidAscending($0.key, $1.key)
        }
        .prefix(limit)
        .compactMap { threadID, score in
            guard let text = documentText[threadID] else { return nil }
            return KeepTalkingSemanticSearchResult(
                threadID: threadID,
                text: text,
                score: score / maximumScore
            )
        }
    }

    fileprivate static func semanticMemoryTokens(_ string: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "of", "to", "in", "on",
            "for", "is", "are", "was", "were", "be", "it", "this", "that",
            "with", "as", "at", "by", "from", "i", "you", "we", "they",
        ]
        let tokens = foldSemanticMemoryText(string)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
        let meaningfulTokens = tokens.filter { !stopwords.contains($0) }

        return meaningfulTokens.isEmpty ? tokens : meaningfulTokens
    }

    fileprivate static func foldSemanticMemoryText(_ string: String) -> String {
        string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    fileprivate static func semanticMemoryOccurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = haystack.startIndex
        while start < haystack.endIndex,
            let range = haystack.range(of: needle, range: start..<haystack.endIndex)
        {
            count += 1
            start = range.upperBound
        }

        return count
    }
}
