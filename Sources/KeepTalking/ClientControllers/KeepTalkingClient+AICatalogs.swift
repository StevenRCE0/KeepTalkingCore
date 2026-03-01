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

        let onlineNodeIDs = Set(
            try await KeepTalkingNode.query(on: localStore.database)
                .filter(\.$discoveredDuringLogon, .equal, logon)
                .all()
                .compactMap(\.id)
        )

        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        let localActions = try await selfNode.$actions.query(
            on: localStore.database
        ).all()
        let authorizedLocalActions = try await authorizedActions(
            localActions,
            for: selfNode,
            context: context
        )

        let onlineOutgoingRelations = try await selfNode.$outgoingNodeRelations
            .query(on: localStore.database).filter(
                \.$to.$id ~~ onlineNodeIDs
            ).all()

        let remoteActions = try await withThrowingTaskGroup(
            of: [KeepTalkingAction].self,
            returning: [KeepTalkingAction].self
        ) { group in
            for relation in onlineOutgoingRelations {
                group.addTask {
                    let actionRelations = try await relation.$actionRelations
                        .query(on: self.localStore.database)
                        .with(\.$action)
                        .all()

                    return try await self.authorizedActions(
                        actionRelations.map(\.action),
                        for: KeepTalkingNode(id: relation.$to.id),
                        context: context
                    )
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
                            descriptor: action.descriptor
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

        for action in actions {
            guard
                let actionID = action.id,
                let ownerNodeID = action.$node.id,
                ownerNodeID != config.node
            else {
                continue
            }

            let queryKind: KeepTalkingActionCatalogQueryKind?
            switch action.payload {
                case .mcpBundle:
                    queryKind = .mcpTools
                case .skill:
                    queryKind = .skillMetadata
                default:
                    queryKind = nil
            }
            guard let queryKind else {
                continue
            }

            queriesByNodeID[ownerNodeID, default: []].append(
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

    func loadSkillCatalogContext(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingSkillCatalogContext {
        do {
            try validateSkillDirectory(bundle.directory)
            let manifestURL = SkillDirectoryDefinitions.entryURL(
                .manifest,
                in: bundle.directory
            )
            let manifestText = try String(
                contentsOf: manifestURL,
                encoding: .utf8
            )
            return KeepTalkingSkillCatalogContext(
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                bundle: bundle,
                manifestPath: manifestURL.path,
                manifestMetadata: parseManifestMetadata(manifestText),
                referencesFiles: listRelativeFiles(
                    in: SkillDirectoryDefinitions.entryURL(
                        .references,
                        in: bundle.directory
                    ),
                    root: bundle.directory
                ),
                scripts: listRelativeFiles(
                    in: SkillDirectoryDefinitions.entryURL(
                        .scripts,
                        in: bundle.directory
                    ),
                    root: bundle.directory
                ),
                assets: listRelativeFiles(
                    in: SkillDirectoryDefinitions.entryURL(
                        .assets,
                        in: bundle.directory
                    ),
                    root: bundle.directory
                ),
                manifestPreview: clipped(
                    manifestText,
                    maxCharacters: Self.skillManifestPreviewMaxCharacters
                ),
                loadError: nil
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

    func validateSkillDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SkillManagerError.invalidSkillDirectory(directory)
        }

        let manifestURL = SkillDirectoryDefinitions.entryURL(
            .manifest,
            in: directory
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SkillManagerError.missingSkillManifest(manifestURL)
        }
    }

    func parseManifestMetadata(_ manifest: String) -> [String: String] {
        guard manifest.hasPrefix("---") else {
            return [:]
        }
        let lines = manifest.components(separatedBy: .newlines)
        guard
            lines.count >= 3,
            lines[0].trimmingCharacters(in: .whitespaces) == "---"
        else {
            return [:]
        }

        var metadata: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            guard
                let separator = line.firstIndex(of: ":"),
                separator != line.startIndex
            else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                metadata[key] = value
            }
        }
        return metadata
    }

    func listRelativeFiles(in directory: URL, root: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return []
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let rootPath = root.standardizedFileURL.path
        var files: [String] = []
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                ),
                values.isRegularFile == true
            else {
                continue
            }

            let path = fileURL.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                files.append(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return files.sorted()
    }

    func resolveSkillFileURL(
        _ rawPath: String,
        skillDirectory: URL
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillManagerError.invalidToolArguments(rawPath)
        }

        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = skillDirectory.appendingPathComponent(trimmed)
        }

        let resolved = candidate.standardizedFileURL
        let rootPath = skillDirectory.standardizedFileURL.path
        let resolvedPath = resolved.path
        let insideRoot =
            resolvedPath == rootPath
            || resolvedPath.hasPrefix(rootPath + "/")
        guard insideRoot else {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolvedPath,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue
        else {
            throw SkillManagerError.invalidSkillPath(trimmed)
        }
        return resolved
    }

    func agentContextTranscript(
        _ context: KeepTalkingContext,
        skillSummaries: [KeepTalkingSkillSummaryEntry]
    ) async throws -> String {
        guard let contextID = context.id else {
            return "No prior messages in this context."
        }

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
            conversationTranscript = recentMessages.map { message in
                let sender: String =
                    switch message.sender {
                        case .node(let nodeID):
                            "node:\(nodeID.uuidString.lowercased())"
                        case .autonomous(let name):
                            "agent:\(name)"
                    }
                return "[\(sender)] \(message.content)"
            }.joined(separator: "\n")
        }

        let skillSummary = renderSkillContextSummary(skillSummaries)
        guard !skillSummary.isEmpty else {
            return conversationTranscript
        }

        return """
            \(conversationTranscript)

            \(skillSummary)
            """
    }

    func renderSkillContextSummary(
        _ skillSummaries: [KeepTalkingSkillSummaryEntry]
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
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters)) + "\n...[truncated]..."
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
