import FluentKit
import Foundation
import MCP
import OpenAI

struct KeepTalkingAICatalogCacheKey: Hashable, Sendable {
    let nodeID: UUID
    let contextID: UUID
}

struct KeepTalkingSkillCatalogContext: Sendable {
    let actionID: UUID
    let ownerNodeID: UUID
    let bundle: KeepTalkingSkillBundle
    let manifestPath: String
    let manifestMetadata: [String: String]
    let referencesFiles: [String]
    let scripts: [String]
    let assets: [String]
    let manifestPreview: String
    let loadError: String?
}

struct KeepTalkingSkillSummaryEntry: Sendable {
    let actionID: UUID
    let ownerNodeID: UUID
    let skillName: String
    let manifestPath: String
    let manifestMetadata: [String: String]
    let referencesFiles: [String]
    let scripts: [String]
    let assets: [String]
    let loadError: String?
}

struct KeepTalkingRemoteCatalogLookup: Sendable {
    var mcpToolsByActionID: [UUID: [KeepTalkingActionCatalogMCPTool]] = [:]
    var skillMetadataByActionID: [UUID: KeepTalkingActionCatalogSkillMetadata] =
        [:]
}

enum KeepTalkingAgentToolRoute: Sendable {
    case actionProxy(KeepTalkingActionToolDefinition)
    case skillMetadata(KeepTalkingSkillCatalogContext)
    case skillFileLocal(KeepTalkingSkillCatalogContext)
    case skillFileRemote(
        actionID: UUID,
        ownerNodeID: UUID,
        skillName: String
    )
}

struct KeepTalkingSemanticRetrievalCatalogEntry: Sendable {
    let actionID: UUID
    let ownerNodeID: UUID
    let bundle: KeepTalkingSemanticRetrievalBundle
}

struct KeepTalkingActionRuntimeCatalog: Sendable {
    let catalog: KeepTalkingActionToolCatalog
    let routesByFunctionName: [String: KeepTalkingAgentToolRoute]
    let skillSummaries: [KeepTalkingSkillSummaryEntry]
    let remoteSemanticRetrievalActions: [KeepTalkingSemanticRetrievalCatalogEntry]
}

actor KeepTalkingActionCatalogCache {
    static let shared = KeepTalkingActionCatalogCache()

    private var catalogByKey: [KeepTalkingAICatalogCacheKey: KeepTalkingActionRuntimeCatalog] =
        [:]

    func catalog(for key: KeepTalkingAICatalogCacheKey)
        -> KeepTalkingActionRuntimeCatalog?
    {
        catalogByKey[key]
    }

    func update(
        _ catalog: KeepTalkingActionRuntimeCatalog,
        for key: KeepTalkingAICatalogCacheKey
    ) {
        catalogByKey[key] = catalog
    }

    func invalidate(nodeID: UUID) {
        catalogByKey = catalogByKey.filter { $0.key.nodeID != nodeID }
    }
}

extension KeepTalkingClient {
    private var skillCatalogContextLoader: KeepTalkingSkillCatalogLoader {
        KeepTalkingSkillCatalogLoader(
            manifestPreviewMaxCharacters: Self.skillManifestPreviewMaxCharacters,
            filePreviewMaxCharacters: Self.skillFileMaxCharacters
        )
    }

    func resolveActionRuntimeCatalog(in context: KeepTalkingContext)
        async throws
        -> KeepTalkingActionRuntimeCatalog
    {
        let cacheKey = KeepTalkingAICatalogCacheKey(
            nodeID: config.node,
            contextID: context.id ?? config.contextID
        )
        if let cached = await KeepTalkingActionCatalogCache.shared.catalog(
            for: cacheKey
        ) {
            return cached
        }

        let fresh = try await buildActionRuntimeCatalog(in: context)
        await KeepTalkingActionCatalogCache.shared.update(fresh, for: cacheKey)
        return fresh
    }

    private func buildActionRuntimeCatalog(in context: KeepTalkingContext)
        async throws
        -> KeepTalkingActionRuntimeCatalog
    {
        var definitionsByName: [String: KeepTalkingActionToolDefinition] = [:]
        var routesByFunctionName: [String: KeepTalkingAgentToolRoute] = [:]
        var skillSummaryByActionID: [UUID: KeepTalkingSkillSummaryEntry] = [:]
        var remoteSemanticRetrievalEntries: [KeepTalkingSemanticRetrievalCatalogEntry] = []

        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        let localActions = try await selfNode.$actions.query(
            on: localStore.database
        ).all()
        let authorizedLocalActions = try await grantedActions(
            localActions,
            for: selfNode,
            context: context
        )

        let incomingRelations = try await selfNode.$incomingNodeRelations
            .query(on: localStore.database)
            .all()

        let remoteActions = try await withThrowingTaskGroup(
            of: [KeepTalkingAction].self,
            returning: [KeepTalkingAction].self
        ) { group in
            for relation in incomingRelations
            where relation.allows(
                context: context
            ) {
                group.addTask {
                    let actionRelations = try await relation.$actionRelations
                        .query(on: self.localStore.database)
                        .with(\.$action)
                        .all()
                    var injectedActions: [KeepTalkingAction] = []
                    injectedActions.reserveCapacity(actionRelations.count)
                    for actionRelation in actionRelations
                    where actionRelation.applicable(in: context) {
                        let action = actionRelation.action
                        if action.disabled == true { continue }
                        guard let ownerNodeID = action.$node.id else {
                            continue
                        }
                        if try await self.shouldInjectActionIntoCatalog(
                            action,
                            ownerNodeID: ownerNodeID
                        ) {
                            injectedActions.append(action)
                        }
                    }
                    return injectedActions
                }
            }

            var result: [KeepTalkingAction] = []
            for try await actions in group {
                result.append(contentsOf: actions)
            }
            return result
        }

        let allActions = deduplicatedAndSortedActions(
            authorizedLocalActions + remoteActions
        )
        let remoteCatalogLookup = await fetchRemoteCatalogLookup(
            for: allActions,
            context: context
        )

        for action in allActions {
            guard
                let actionID = action.id,
                let ownerNodeID = action.$node.id
            else {
                continue
            }

            switch action.payload {
                case .mcpBundle(let bundle):
                    let mcpDefinitions = try await mcpProxyDefinitions(
                        for: action,
                        ownerNodeID: ownerNodeID,
                        bundle: bundle,
                        remoteTools: remoteCatalogLookup.mcpToolsByActionID[
                            actionID
                        ] ?? []
                    )
                    for definition in mcpDefinitions {
                        definitionsByName[definition.functionName] = definition
                        routesByFunctionName[definition.functionName] =
                            .actionProxy(definition)
                    }

                case .skill(let bundle):
                    let skillActionDefinition =
                        makeSkillActionProxyDefinition(
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            bundle: bundle,
                            descriptor: action.descriptor,
                            supportsWakeAssist: action.blockingAuthorisation
                                == true
                        )
                    definitionsByName[skillActionDefinition.functionName] =
                        skillActionDefinition
                    routesByFunctionName[skillActionDefinition.functionName] =
                        .actionProxy(skillActionDefinition)

                    let fileToolDefinition = makeSkillFileReaderDefinition(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        bundle: bundle
                    )
                    definitionsByName[fileToolDefinition.functionName] =
                        fileToolDefinition

                    if ownerNodeID != config.node {
                        routesByFunctionName[fileToolDefinition.functionName] =
                            .skillFileRemote(
                                actionID: actionID,
                                ownerNodeID: ownerNodeID,
                                skillName: bundle.name
                            )
                        if let remoteMetadata =
                            remoteCatalogLookup.skillMetadataByActionID[actionID]
                        {
                            skillSummaryByActionID[actionID] =
                                KeepTalkingSkillSummaryEntry(
                                    actionID: actionID,
                                    ownerNodeID: ownerNodeID,
                                    skillName: remoteMetadata.name,
                                    manifestPath: remoteMetadata.manifestPath,
                                    manifestMetadata: remoteMetadata.manifestMetadata,
                                    referencesFiles: remoteMetadata.referencesFiles,
                                    scripts: remoteMetadata.scripts,
                                    assets: remoteMetadata.assets,
                                    loadError: nil
                                )
                        } else {
                            skillSummaryByActionID[actionID] =
                                KeepTalkingSkillSummaryEntry(
                                    actionID: actionID,
                                    ownerNodeID: ownerNodeID,
                                    skillName: bundle.name,
                                    manifestPath: "",
                                    manifestMetadata: [:],
                                    referencesFiles: [],
                                    scripts: [],
                                    assets: [],
                                    loadError:
                                        "metadata not fetched from remote action owner"
                                )
                        }
                        continue
                    }

                    let skillContext = loadSkillCatalogContext(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        bundle: bundle
                    )
                    skillSummaryByActionID[actionID] =
                        KeepTalkingSkillSummaryEntry(
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            skillName: bundle.name,
                            manifestPath: skillContext.manifestPath,
                            manifestMetadata: skillContext.manifestMetadata,
                            referencesFiles: skillContext.referencesFiles,
                            scripts: skillContext.scripts,
                            assets: skillContext.assets,
                            loadError: skillContext.loadError
                        )

                    let metadataToolDefinition = makeSkillMetadataDefinition(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        bundle: bundle
                    )
                    definitionsByName[metadataToolDefinition.functionName] =
                        metadataToolDefinition
                    routesByFunctionName[metadataToolDefinition.functionName] =
                        .skillMetadata(skillContext)

                    routesByFunctionName[fileToolDefinition.functionName] =
                        .skillFileLocal(skillContext)

                case .primitive(let bundle):
                    let primitiveActionDefinition =
                        makePrimitiveActionProxyDefinition(
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            bundle: bundle,
                            descriptor: action.descriptor,
                            supportsWakeAssist: action.blockingAuthorisation
                                == true
                        )
                    definitionsByName[primitiveActionDefinition.functionName] =
                        primitiveActionDefinition
                    routesByFunctionName[primitiveActionDefinition.functionName] =
                        .actionProxy(primitiveActionDefinition)

                case .semanticRetrieval(let bundle):
                    // Skip the local node's own semantic retrieval; it is served
                    // transparently by the built-in kt_search_threads tool.
                    guard ownerNodeID != config.node else { continue }
                    remoteSemanticRetrievalEntries.append(
                        KeepTalkingSemanticRetrievalCatalogEntry(
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            bundle: bundle
                        )
                    )
            }
        }

        return KeepTalkingActionRuntimeCatalog(
            catalog: KeepTalkingActionToolCatalog(
                definitions: Array(definitionsByName.values).sorted {
                    $0.functionName < $1.functionName
                }
            ),
            routesByFunctionName: routesByFunctionName,
            skillSummaries: Array(skillSummaryByActionID.values).sorted {
                $0.actionID.uuidString < $1.actionID.uuidString
            },
            remoteSemanticRetrievalActions: remoteSemanticRetrievalEntries.sorted {
                $0.actionID.uuidString < $1.actionID.uuidString
            }
        )
    }

    private func fetchRemoteCatalogLookup(
        for actions: [KeepTalkingAction],
        context: KeepTalkingContext
    ) async -> KeepTalkingRemoteCatalogLookup {
        var queriesByNodeID: [UUID: [KeepTalkingActionCatalogQuery]] = [:]
        let onlineNodeIDs = onlineNodeIDs()

        for action in actions {
            guard
                let actionID = action.id,
                let ownerNodeID = action.$node.id,
                ownerNodeID != config.node
            else {
                continue
            }

            guard
                let deliveryNodeID = try? await deliveryNodeID(
                    forRemoteOwnerNodeID: ownerNodeID
                ),
                onlineNodeIDs.contains(deliveryNodeID)
            else {
                continue
            }

            let queryKind: KeepTalkingActionCatalogQueryKind?
            switch action.payload {
                case .mcpBundle:
                    queryKind = .mcpTools
                case .skill:
                    queryKind = .skillMetadata
                case .primitive:
                    queryKind = nil
                default:
                    queryKind = nil
            }
            guard let queryKind else {
                continue
            }

            queriesByNodeID[deliveryNodeID, default: []].append(
                KeepTalkingActionCatalogQuery(
                    actionID: actionID,
                    kind: queryKind
                )
            )
        }

        guard !queriesByNodeID.isEmpty else {
            return KeepTalkingRemoteCatalogLookup()
        }

        return await withTaskGroup(
            of: KeepTalkingActionCatalogResult?.self,
            returning: KeepTalkingRemoteCatalogLookup.self
        ) { group in
            for (ownerNodeID, rawQueries) in queriesByNodeID {
                let queries = deduplicatedCatalogLookupQueries(rawQueries)
                group.addTask {
                    do {
                        return try await self.dispatchActionCatalogRequest(
                            targetNodeID: ownerNodeID,
                            queries: queries,
                            context: context
                        )
                    } catch {
                        self.onLog?(
                            "[ai] remote catalog request failed node=\(ownerNodeID.uuidString.lowercased()) error=\(error.localizedDescription)"
                        )
                        return nil
                    }
                }
            }

            var lookup = KeepTalkingRemoteCatalogLookup()
            for await result in group {
                guard let result else {
                    continue
                }
                if result.isError {
                    onLog?(
                        "[ai] remote catalog result failed node=\(result.targetNodeID.uuidString.lowercased()) error=\(result.errorMessage ?? "unknown")"
                    )
                }
                for item in result.items {
                    if item.isError {
                        onLog?(
                            "[ai] remote catalog item failed action=\(item.actionID.uuidString.lowercased()) kind=\(item.kind.rawValue) error=\(item.errorMessage ?? "unknown")"
                        )
                        continue
                    }
                    switch item.kind {
                        case .mcpTools:
                            lookup.mcpToolsByActionID[item.actionID] =
                                item.mcpTools
                        case .skillMetadata:
                            if let skillMetadata = item.skillMetadata {
                                lookup.skillMetadataByActionID[item.actionID] =
                                    skillMetadata
                            }
                        case .skillFile:
                            continue
                    }
                }
            }
            return lookup
        }
    }

    private func deduplicatedCatalogLookupQueries(
        _ queries: [KeepTalkingActionCatalogQuery]
    ) -> [KeepTalkingActionCatalogQuery] {
        var seen: Set<String> = []
        var result: [KeepTalkingActionCatalogQuery] = []
        result.reserveCapacity(queries.count)

        for query in queries {
            let key = "\(query.actionID.uuidString.lowercased())::\(query.kind.rawValue)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            result.append(query)
        }
        return result
    }

    private func shouldInjectActionIntoCatalog(
        _ action: KeepTalkingAction,
        ownerNodeID: UUID
    ) async throws -> Bool {
        if ownerNodeID == config.node {
            return true
        }
        let deliveryNodeID = try await deliveryNodeID(
            forRemoteOwnerNodeID: ownerNodeID
        )
        if deliveryNodeID == config.node || isNodeOnline(deliveryNodeID) {
            return true
        }
        return action.blockingAuthorisation == true
    }

    func loadSkillCatalogContext(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingSkillCatalogContext {
        do {
            return try skillCatalogContextLoader.loadContext(
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                bundle: bundle
            )
        } catch {
            return KeepTalkingSkillCatalogContext(
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                bundle: bundle,
                manifestPath: SkillDirectoryDefinitions.entryURL(
                    .manifest,
                    in: bundle.directory
                ).path,
                manifestMetadata: [:],
                referencesFiles: [],
                scripts: [],
                assets: [],
                manifestPreview: "",
                loadError: error.localizedDescription
            )
        }
    }

    func resolveSkillFileURL(
        _ rawPath: String,
        skillDirectory: URL
    ) throws -> URL {
        try skillCatalogContextLoader.resolveSkillFileURL(
            rawPath,
            skillDirectory: skillDirectory
        )
    }

    // MARK: - Decay constants

    /// Exponential decay applied to messages inside the live (contextMain) thread.
    /// A smaller value means messages reach further back before falling off.
    private static let contextMainDecayLambda: Double = 0.05

    /// Exponential decay applied to messages inside completed (stored/archived) threads.
    private static let storedThreadDecayLambda: Double = 0.1

    /// Maximum messages taken from the live thread  (= floor(1 / λ₀)).
    private static let contextMainMessageBudget: Int = 20  // floor(1/0.05)

    /// Shared message budget across all completed threads  (= floor(1 / λ₁) * 1.5, rounded).
    private static let storedTotalMessageBudget: Int = 20

    // MARK: - Context transcript

    /// Loads threads + messages for `context` and applies decay-weighted selection,
    /// returning the raw grouped result for use by both the metadata formatter and the
    /// message-list builder.
    private func loadContextSelection(
        contextID: UUID
    ) async throws -> (
        allMessages: [KeepTalkingContextMessage],
        threadedSegments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])],
        selected: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])]
    ) {
        let threads = try await KeepTalkingThread.query(on: localStore.database)
            .filter(\.$context.$id, .equal, contextID)
            .all()

        let allMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$timestamp, .ascending)
        .all()

        let threadedSegments = buildThreadedSegments(
            threads: threads,
            allMessages: allMessages
        )

        let selected: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])]
        if threadedSegments.isEmpty {
            let recent = Array(allMessages.suffix(30))
            selected = [(thread: nil, messages: recent)]
        } else {
            selected = decayWeightedSelection(segments: threadedSegments)
        }

        return (allMessages: allMessages, threadedSegments: threadedSegments, selected: selected)
    }

    /// Returns metadata-only context string (thread map, node names, attachments, skills).
    /// Conversation messages are excluded — use `agentContextMessages` for those.
    func agentContextTranscript(
        _ context: KeepTalkingContext,
        skillSummaries: [KeepTalkingSkillSummaryEntry]
    ) async throws -> String {
        guard let contextID = context.id else {
            return ""
        }
        let aliasLookup = try await aliasLookup()

        let (_, threadedSegments, selectedMessages) = try await loadContextSelection(
            contextID: contextID
        )

        let threadMapSummary = renderThreadMapSummary(
            segments: threadedSegments,
            aliasLookup: aliasLookup
        )

        let allSelectedMessages = selectedMessages.flatMap(\.messages)

        // --- Attachment summary ---
        let attachmentCount = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .count()
        let recentAttachmentNames = try await KeepTalkingContextAttachment.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$createdAt, .descending)
        .sort(\.$sortIndex, .descending)
        .limit(8)
        .all()
        .map(\.filename)
        .reversed()

        let attachmentSummary: String
        if attachmentCount > 0 {
            let preview = previewList(Array(recentAttachmentNames), maxItems: 8)
            attachmentSummary = """
                Context attachments: \(attachmentCount)
                Recent attachment names: \(preview)
                Use \(Self.contextAttachmentListingToolFunctionName) for the full inventory and \(Self.contextAttachmentReadToolFunctionName) to inspect one.
                """
        } else {
            attachmentSummary = ""
        }

        // --- Node name summary (derived from selected messages) ---
        let nodeNameSummary = renderNodeNameSummary(
            recentMessages: allSelectedMessages,
            aliasLookup: aliasLookup
        )
        let skillSummary = renderSkillContextSummary(skillSummaries, aliasLookup: aliasLookup)

        return [threadMapSummary, nodeNameSummary, attachmentSummary, skillSummary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Returns the decay-weighted conversation history as proper API messages,
    /// filtering out intermediate/noise messages. Insert between the system message
    /// and the current user message in the request messages array.
    func agentContextMessages(
        _ context: KeepTalkingContext,
        excludingMessageID: UUID? = nil
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        guard let contextID = context.id else {
            return []
        }

        let (_, _, selected) = try await loadContextSelection(contextID: contextID)

        return selected.flatMap(\.messages).compactMap { message in
            if let excludeID = excludingMessageID, message.id == excludeID {
                return nil
            }
            guard case .message = message.type else { return nil }
            switch message.sender {
                case .autonomous:
                    return .assistant(
                        .init(content: .textContent(message.content))
                    )
                case .node:
                    return .user(
                        .init(content: .string(message.content))
                    )
            }
        }
    }

    // MARK: - Thread segmentation helpers

    /// Groups all context messages into ordered (thread, [message]) pairs.
    /// Threads without any messages are omitted.
    private func buildThreadedSegments(
        threads: [KeepTalkingThread],
        allMessages: [KeepTalkingContextMessage]
    ) -> [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])] {
        guard !threads.isEmpty, !allMessages.isEmpty else { return [] }

        let sorted =
            threads
            .compactMap { thread -> (thread: KeepTalkingThread, range: ClosedRange<Int>)? in
                guard let range = thread.resolvedMessageRange(in: allMessages) else {
                    return nil
                }
                return (thread: thread, range: range)
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

        var result: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])] = []
        for (thread, range) in sorted {
            let slice = Array(allMessages[range])
            // Exclude chitter-chatter messages from the prompt.
            let chitterSet = Set(thread.chitterChatter)
            let filtered = slice.filter { msg in
                guard let id = msg.id else { return true }
                return !chitterSet.contains(id)
            }
            if !filtered.isEmpty {
                result.append((thread: thread, messages: filtered))
            }
        }
        return result
    }

    /// Applies exponential decay to select messages from each thread segment.
    ///
    /// - contextMain: takes up to `contextMainMessageBudget` tail messages with λ₀ decay.
    /// - stored/archived: all threads share `storedTotalMessageBudget` tail messages with λ₁ decay;
    ///   each individual thread receives a proportional slice.
    private func decayWeightedSelection(
        segments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])]
    ) -> [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])] {
        let λ₀ = Self.contextMainDecayLambda
        let λ₁ = Self.storedThreadDecayLambda

        /// Number of tail messages to keep for a thread with a given decay λ and budget cap.
        /// Uses `ceil(-ln(0.01) / λ)` — the position at which the weight drops below 1 %.
        func tailCount(lambda: Double, cap: Int, available: Int) -> Int {
            let depth = Int(ceil(-log(0.01) / lambda))  // ~99 % of cumulative weight
            return min(cap, min(depth, available))
        }

        var result: [(thread: KeepTalkingThread?, messages: [KeepTalkingContextMessage])] = []

        let storedSegments = segments.filter { $0.thread.state != .contextMain }
        let mainSegments = segments.filter { $0.thread.state == .contextMain }

        // --- Completed threads: share storedTotalMessageBudget ---
        if !storedSegments.isEmpty {
            let perThread = max(1, Self.storedTotalMessageBudget / storedSegments.count)
            for seg in storedSegments {
                let n = tailCount(lambda: λ₁, cap: perThread, available: seg.messages.count)
                let selected = Array(seg.messages.suffix(n))
                result.append((thread: seg.thread, messages: selected))
            }
        }

        // --- Live thread (contextMain) ---
        for seg in mainSegments {
            let n = tailCount(lambda: λ₀, cap: Self.contextMainMessageBudget, available: seg.messages.count)
            let selected = Array(seg.messages.suffix(n))
            result.append((thread: seg.thread, messages: selected))
        }

        return result
    }

    // MARK: - Thread rendering helpers

    private func threadTopicName(
        for thread: KeepTalkingThread,
        messages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        if let threadID = thread.id,
            let alias = aliasLookup.alias(for: .thread(threadID)),
            !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return alias
        }
        if let summary = thread.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty
        {
            return summary
        }
        return derivedThreadTopic(from: messages)
    }

    private func derivedThreadTopic(
        from messages: [KeepTalkingContextMessage]
    ) -> String {
        for message in messages.reversed() where message.type == .message {
            let normalized = normalizedTopicSnippet(message.content)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return "untitled"
    }

    private func normalizedTopicSnippet(_ raw: String) -> String {
        let collapsedWhitespace =
            raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedWhitespace.isEmpty else {
            return ""
        }

        let withoutURLs = collapsedWhitespace.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        let words =
            withoutURLs
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return ""
        }
        return words.prefix(6).joined(separator: " ")
    }

    /// Returns a short human-readable label for a thread, used as section header.
    private func threadLabel(
        for thread: KeepTalkingThread,
        messages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        let topic = threadTopicName(
            for: thread,
            messages: messages,
            aliasLookup: aliasLookup
        )
        if thread.state == .contextMain {
            return "Ongoing: \(topic)"
        }
        let stateTag = thread.state == .archived ? "archived" : "completed"
        return "Thread (\(stateTag)): \"\(topic)\""
    }

    /// Renders a single-line thread topic map injected before the transcript.
    private func renderThreadMapSummary(
        segments: [(thread: KeepTalkingThread, messages: [KeepTalkingContextMessage])],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        guard !segments.isEmpty else { return "" }

        let labels = segments.map { seg -> String in
            let topic = threadTopicName(
                for: seg.thread,
                messages: seg.messages,
                aliasLookup: aliasLookup
            )
            if seg.thread.state == .contextMain {
                return "● \"\(topic)\""
            }
            let mark = seg.thread.state == .archived ? "⊘" : "✓"
            return "\(mark) \"\(topic)\""
        }.joined(separator: " → ")

        let currentLiveTopic =
            segments
            .last(where: { $0.thread.state == .contextMain })
            .map {
                threadTopicName(
                    for: $0.thread,
                    messages: $0.messages,
                    aliasLookup: aliasLookup
                )
            }

        if let currentLiveTopic {
            return """
                Conversation thread topics (oldest→newest, last live): \(labels)
                Current live thread topic: "\(currentLiveTopic)"
                """
        }

        return "Conversation thread topics (oldest→newest): \(labels)"
    }

    func renderSkillContextSummary(
        _ skillSummaries: [KeepTalkingSkillSummaryEntry],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        guard !skillSummaries.isEmpty else {
            return ""
        }

        let sorted = skillSummaries.sorted {
            $0.actionID.uuidString < $1.actionID.uuidString
        }
        let sections = sorted.map { context in
            let actionID = context.actionID.uuidString.lowercased()
            let metadataJSON = jsonString(context.manifestMetadata)
            let refs = previewList(context.referencesFiles, maxItems: 8)
            let scripts = previewList(context.scripts, maxItems: 8)
            let assets = previewList(context.assets, maxItems: 8)

            return """
                - action_id: \(actionID)
                  owner_node_id: \(context.ownerNodeID.uuidString.lowercased())
                  owner_node_name: \(aliasLookup.resolve(.node(context.ownerNodeID)).primary())
                  is_current_node: \(context.ownerNodeID == config.node)
                  skill_name: \(context.skillName)
                  manifest_path: \(context.manifestPath)
                  metadata_json: \(metadataJSON)
                  references: \(refs)
                  scripts: \(scripts)
                  assets: \(assets)
                  metadata_error: \(context.loadError ?? "none")
                """
        }

        return """
            Skill bundle metadata summary:
            \(sections.joined(separator: "\n"))
            """
    }

    func renderNodeNameSummary(
        recentMessages: [KeepTalkingContextMessage],
        aliasLookup: KeepTalkingAliasLookup
    ) -> String {
        var nodeIDs = Set(
            recentMessages.compactMap { message -> UUID? in
                guard case .node(let nodeID) = message.sender else {
                    return nil
                }
                return nodeID
            }
        )
        nodeIDs.insert(config.node)

        let sortedNodeIDs = nodeIDs.sorted { $0.uuidString < $1.uuidString }
        let lines = sortedNodeIDs.map { nodeID in
            let name =
                aliasLookup
                .resolve(.node(nodeID))
                .primary(uppercaseID: true)
            let prefix = nodeID == config.node ? "current_node" : "node"
            return "- \(prefix): \(name)"
        }

        return """
            Known node names in this context (mapping aliases with uppercase UUID fallback):
            \(lines.joined(separator: "\n"))
            """
    }

    func previewList(_ values: [String], maxItems: Int) -> String {
        guard !values.isEmpty else {
            return "<none>"
        }
        if values.count <= maxItems {
            return values.joined(separator: ", ")
        }
        let preview = values.prefix(maxItems).joined(separator: ", ")
        return "\(preview), ...[\(values.count - maxItems) more]"
    }

    func clipped(_ text: String, maxCharacters: Int) -> String {
        skillCatalogContextLoader.clipped(text, maxCharacters: maxCharacters)
    }

    func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            return "{\"ok\":false,\"error\":\"invalid_json_object\"}"
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":\"json_encoding_failed\"}"
        }
        return text
    }
}
