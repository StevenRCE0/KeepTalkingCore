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

/// Mutable class so lazy-registered MCP/skill tools can be appended in-place.
/// The shared cache holds a reference; mutations are visible across runAI calls
/// on the same cached instance without requiring a cache invalidation.
final class KeepTalkingActionRuntimeCatalog: @unchecked Sendable {
    var catalog: KeepTalkingActionToolCatalog
    var routesByFunctionName: [String: KeepTalkingAgentToolRoute]
    let actionStubs: [KeepTalkingActionStub]
    let remoteSemanticRetrievalActions: [KeepTalkingSemanticRetrievalCatalogEntry]
    let lazyRegistry: KeepTalkingLazyToolRegistry

    init(
        catalog: KeepTalkingActionToolCatalog,
        routesByFunctionName: [String: KeepTalkingAgentToolRoute],
        actionStubs: [KeepTalkingActionStub],
        remoteSemanticRetrievalActions: [KeepTalkingSemanticRetrievalCatalogEntry],
        lazyRegistry: KeepTalkingLazyToolRegistry
    ) {
        self.catalog = catalog
        self.routesByFunctionName = routesByFunctionName
        self.actionStubs = actionStubs
        self.remoteSemanticRetrievalActions = remoteSemanticRetrievalActions
        self.lazyRegistry = lazyRegistry
    }

    /// Appends lazily-discovered tool definitions and their routes into the catalog.
    /// Called after MCP/skill schemas are fetched so subsequent runAI calls (with
    /// this cached instance) already include these tools in allTools from the start.
    func append(
        definitions: [KeepTalkingActionToolDefinition],
        routes: [String: KeepTalkingAgentToolRoute]
    ) {
        catalog = KeepTalkingActionToolCatalog(
            definitions: catalog.definitions + definitions
        )
        for (name, route) in routes {
            routesByFunctionName[name] = route
        }
    }
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
    var skillCatalogContextLoader: KeepTalkingSkillCatalogLoader {
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
        var actionStubs: [KeepTalkingActionStub] = []
        var remoteSemanticRetrievalEntries: [KeepTalkingSemanticRetrievalCatalogEntry] = []
        let lazyRegistry = KeepTalkingLazyToolRegistry()

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

        for action in allActions {
            guard
                let actionID = action.id,
                let ownerNodeID = action.$node.id
            else {
                continue
            }

            let isCurrentNode = ownerNodeID == config.node
            let supportsWakeAssist = action.blockingAuthorisation == true

            switch action.payload {
                case .mcpBundle(let bundle):
                    let description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                    actionStubs.append(KeepTalkingActionStub(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        name: bundle.name,
                        kind: .mcp,
                        description: description,
                        supportsWakeAssist: supportsWakeAssist,
                        isCurrentNode: isCurrentNode
                    ))

                case .skill(let bundle):
                    let description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                    actionStubs.append(KeepTalkingActionStub(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        name: bundle.name,
                        kind: .skill,
                        description: description,
                        supportsWakeAssist: supportsWakeAssist,
                        isCurrentNode: isCurrentNode
                    ))

                case .primitive(let bundle):
                    let description =
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription
                    actionStubs.append(KeepTalkingActionStub(
                        actionID: actionID,
                        ownerNodeID: ownerNodeID,
                        name: bundle.name,
                        kind: .primitive,
                        description: description,
                        supportsWakeAssist: supportsWakeAssist,
                        isCurrentNode: isCurrentNode
                    ))
                    let primitiveActionDefinition =
                        makePrimitiveActionProxyDefinition(
                            actionID: actionID,
                            ownerNodeID: ownerNodeID,
                            bundle: bundle,
                            descriptor: action.descriptor,
                            supportsWakeAssist: supportsWakeAssist
                        )
                    definitionsByName[primitiveActionDefinition.functionName] =
                        primitiveActionDefinition
                    routesByFunctionName[primitiveActionDefinition.functionName] =
                        .actionProxy(primitiveActionDefinition)

                case .semanticRetrieval(let bundle):
                    // Skip the local node's own semantic retrieval; it is served
                    // transparently by the built-in kt_search_threads tool.
                    guard !isCurrentNode else { continue }
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
            actionStubs: actionStubs.sorted {
                $0.actionID.uuidString < $1.actionID.uuidString
            },
            remoteSemanticRetrievalActions: remoteSemanticRetrievalEntries.sorted {
                $0.actionID.uuidString < $1.actionID.uuidString
            },
            lazyRegistry: lazyRegistry
        )
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
}
