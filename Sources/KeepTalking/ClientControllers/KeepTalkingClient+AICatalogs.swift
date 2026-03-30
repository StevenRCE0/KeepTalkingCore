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

struct KeepTalkingActionRuntimeCatalog: Sendable {
    let catalog: KeepTalkingActionToolCatalog
    let routesByFunctionName: [String: KeepTalkingAgentToolRoute]
    let skillSummaries: [KeepTalkingSkillSummaryEntry]
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

        let outgoingRelations = try await selfNode.$outgoingNodeRelations
            .query(on: localStore.database)
            .all()

        let remoteActions = try await withThrowingTaskGroup(
            of: [KeepTalkingAction].self,
            returning: [KeepTalkingAction].self
        ) { group in
            for relation in outgoingRelations where relation.allows(context: context) {
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

                default:
                    continue
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

    func agentContextTranscript(
        _ context: KeepTalkingContext,
        skillSummaries: [KeepTalkingSkillSummaryEntry]
    ) async throws -> String {
        guard let contextID = context.id else {
            return "No prior messages in this context."
        }
        let aliasLookup = try await aliasLookup()

        let recentMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$timestamp, .descending)
        .limit(30)
        .all()

        let conversationTranscript: String
        if recentMessages.isEmpty {
            conversationTranscript = "No prior messages in this context."
        } else {
            conversationTranscript =
                recentMessages
                .reversed()
                .map { message in
                    let sender =
                        KeepTalkingActionToolDefinition
                        .conversationSenderTag(
                            message.sender,
                            nodeAliasResolver: {
                                aliasLookup.alias(for: .node($0))
                            }
                        )
                    return "[\(sender)] \(message.content)"
                }.joined(separator: "\n")
        }

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
            let preview = previewList(
                Array(recentAttachmentNames),
                maxItems: 8
            )
            attachmentSummary = """
                Context attachments: \(attachmentCount)
                Recent attachment names: \(preview)
                Use \(Self.contextAttachmentListingToolFunctionName) for the full inventory and \(Self.contextAttachmentReadToolFunctionName) to inspect one.
                """
        } else {
            attachmentSummary = ""
        }

        let nodeNameSummary = renderNodeNameSummary(
            recentMessages: recentMessages,
            aliasLookup: aliasLookup
        )
        let skillSummary = renderSkillContextSummary(
            skillSummaries,
            aliasLookup: aliasLookup
        )
        return [nodeNameSummary, conversationTranscript, attachmentSummary, skillSummary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
                  owner_node_name: \(KeepTalkingClient.resolve(node: context.ownerNodeID, aliasLookup: aliasLookup).primary(uppercaseID: true))
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
            let name = KeepTalkingClient.resolve(
                node: nodeID,
                aliasLookup: aliasLookup
            ).primary(uppercaseID: true)
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
