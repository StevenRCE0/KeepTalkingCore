import FluentKit
import Foundation
import MCP

public enum SemanticRetrievalActionManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case missingCallback
    case missingQuery

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not a semantic retrieval bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .missingCallback:
                return "Semantic search callback is not configured for this client."
            case .missingQuery:
                return "Search query is required."
        }
    }
}

/// Executes incoming `.semanticRetrieval` action calls on the local node.
///
/// Mirrors the structure of `PrimitiveActionManager`: the manager stores
/// registered bundles by action ID and, when called, resolves the bundle's
/// `contextIDs`/`tagTitles` constraints before delegating to the
/// app-injected `SemanticSearchCallback`.
///
/// The callback is wired up lazily via `setSearchCallback` so it always
/// reflects the most-recent value set through
/// `KeepTalkingClient.setSemanticSearchCallback`.
public actor SemanticRetrievalActionManager {

    private var searchCallback: KeepTalkingClient.SemanticSearchCallback?
    private let database: any Database
    private var bundlesByActionID: [UUID: KeepTalkingSemanticRetrievalBundle] = [:]

    public init(database: any Database) {
        self.database = database
    }

    public func setSearchCallback(
        _ callback: KeepTalkingClient.SemanticSearchCallback?
    ) {
        searchCallback = callback
    }

    public func registerAction(_ action: KeepTalkingAction) async throws {
        guard case .semanticRetrieval(let bundle) = action.payload else {
            throw SemanticRetrievalActionManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw SemanticRetrievalActionManagerError.missingActionID
        }
        bundlesByActionID[actionID] = bundle
    }

    public func refreshAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw SemanticRetrievalActionManagerError.missingActionID
        }
        bundlesByActionID.removeValue(forKey: actionID)
        try await registerAction(action)
    }

    public func unregisterAction(actionID: UUID) {
        bundlesByActionID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else { return }
        if bundlesByActionID[actionID] == nil {
            try await registerAction(action)
        }
    }

    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        contextID: UUID
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard case .semanticRetrieval(let bundle) = action.payload else {
            throw SemanticRetrievalActionManagerError.invalidAction
        }
        guard let searchCallback else {
            throw SemanticRetrievalActionManagerError.missingCallback
        }
        try await registerIfNeeded(action)

        let query = call.arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw SemanticRetrievalActionManagerError.missingQuery
        }
        let topK = call.arguments["top_k"]?.intValue ?? 5

        // Automatically determine whether the calling context is locally available on
        // this node. If the context exists here, it is a shared context and the caller
        // can search it on their own device — only return threads from other contexts
        // to complement, not duplicate, the caller's local results.
        let callingContextExistsLocally =
            (try? await KeepTalkingContext.query(on: database)
                .filter(\.$id == contextID)
                .first()) != nil

        // Apply bundle scope.
        let effectiveContextIDs: [UUID]
        if !bundle.contextIDs.isEmpty {
            effectiveContextIDs = bundle.contextIDs
        } else if callingContextExistsLocally {
            // Exclude the calling context — caller can search it locally.
            let allContextIDs =
                (try? await KeepTalkingContext.query(on: database)
                    .all()
                    .compactMap(\.id)
                    .filter { $0 != contextID }) ?? []
            effectiveContextIDs = allContextIDs
        } else {
            effectiveContextIDs = [contextID]
        }

        // If all contexts were excluded (e.g. remote has no other contexts), return empty.
        guard !effectiveContextIDs.isEmpty else {
            let emptyResults: [[String: Any]] = []
            let payload = encodedJSON([
                "ok": true, "query": query, "count": 0, "results": emptyResults,
            ] as [String: Any])
            return (
                content: [.text(text: payload, annotations: nil, _meta: nil)],
                isError: false
            )
        }

        // Resolve tag IDs from this node's DB — tags are node-local and never travel
        // over the wire. Scope to the effective contexts, mirroring local-mode behavior.
        let tagIDs: [UUID] =
            ((try? await KeepTalkingMapping.query(on: database)
                .filter(\.$kind == .tag)
                .all()) ?? [])
            .compactMap { mapping -> UUID? in
                guard
                    let ctxID = mapping.$context.id,
                    effectiveContextIDs.contains(ctxID)
                else { return nil }
                return mapping.id
            }

        let results = try await searchCallback(
            query, topK, effectiveContextIDs, tagIDs
        )

        let items: [[String: Any]] = results.map { result in
            [
                "thread_id": result.threadID.uuidString.lowercased(),
                "label": String(
                    result.threadID.uuidString.prefix(8).lowercased()
                ),
                "score": result.score,
                "excerpt": String(result.text.prefix(400)),
            ]
        }

        let payload = encodedJSON([
            "ok": true,
            "query": query,
            "count": items.count,
            "results": items,
        ])

        return (
            content: [.text(text: payload, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    // MARK: - Private

    private func encodedJSON(_ object: Any) -> String {
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
