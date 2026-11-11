import FluentKit
import Foundation

extension KeepTalkingClient {
    // MARK: - What the model reads

    public func setWorkspaceProviders(_ providers: [any KeepTalkingWorkspaceProviding]) {
        workspaceProviders = providers
    }

    public func recordWorkspaceLift(manifest: KeepTalkingWorkspaceManifest, snapshot: KeepTalkingWorkspaceSnapshot) {
        workspaceLiftCache[manifest.schema] = KeepTalkingWorkspaceSection(manifest: manifest, snapshot: snapshot)
    }

    public func forgetWorkspaceLift(schema: String) {
        workspaceLiftCache.removeValue(forKey: schema)
    }

    func workspaceSections(
        policy: KeepTalkingWorkspacePromptPolicy = .default
    ) async -> [KeepTalkingWorkspaceSection] {
        let providers = workspaceProviders
        let cached = workspaceLiftCache.filter { schema, _ in
            !providers.contains { $0.manifest.schema == schema }
        }
        guard !providers.isEmpty || !cached.isEmpty else { return [] }
        let budget = policy.perProviderBudget(providerCount: providers.count + cached.count)
        var sections: [KeepTalkingWorkspaceSection] = []
        for provider in providers {
            let manifest = provider.manifest
            var chosen: KeepTalkingWorkspaceSnapshot?
            for granularity in manifest.granularities.sorted(by: >) {
                guard let snapshot = try? await provider.snapshot(granularity: granularity) else { continue }
                chosen = snapshot
                if AIMessage.approximateTokens(snapshot.liftedText) <= budget { break }
            }
            guard let chosen else {
                onLog?("[workspace] \(manifest.title) (\(manifest.schema)) gave no snapshot this turn")
                continue
            }
            sections.append(KeepTalkingWorkspaceSection(manifest: manifest, snapshot: chosen))
        }
        sections += cached.values.sorted { $0.manifest.schema < $1.manifest.schema }
        return sections
    }

    // MARK: - Deltas

    public func publishWorkspaceDelta(schema: String, change: Data) {
        try? sendEnvelope(
            KeepTalkingWorkspaceDeltaPayload(
                from: config.node, contextID: config.contextID, schema: schema, change: change)
        )
    }

    func handleIncomingWorkspaceDelta(_ payload: KeepTalkingWorkspaceDeltaPayload) -> Bool {
        guard payload.from != config.node, payload.contextID == config.contextID else { return false }
        signals.workspaceChanges.send(
            KeepTalkingWorkspaceChange(
                contextID: payload.contextID, schema: payload.schema, origin: payload.from, change: payload.change))
        return true
    }

    // MARK: - Stages

    public func workspaceStage(schema: String) async throws -> KeepTalkingWorkspaceStage? {
        try await stageRow(schema: schema, holder: config.node)?.stage
    }

    public func workspaceStageData(schema: String) async throws -> KeepTalkingWorkspacePendingStage? {
        guard let stage = try await workspaceStage(schema: schema) else { return nil }
        guard let data = try await blobData(stage.blobID) else { return nil }
        return KeepTalkingWorkspacePendingStage(stage: stage, data: data)
    }

    @discardableResult
    public func recordWorkspaceStage(schema: String, export: KeepTalkingWorkspaceExport) async throws
        -> KeepTalkingWorkspaceStage
    {
        let blobID = try await storeBlob(export.data, mimeType: export.mimeType, pathExtension: export.pathExtension)
        let stage = KeepTalkingWorkspaceStage(
            schema: schema, holder: config.node, blobID: blobID, mimeType: export.mimeType)
        let previous = try await upsertStage(stage)
        if let previous, previous != blobID {
            try? await Self.pruneStrayBlobs(among: [previous], on: localStore.database, blobStore: blobStore)
        }
        try? sendEnvelope(
            KeepTalkingWorkspaceStagePayload(from: config.node, contextID: config.contextID, stage: stage))
        return stage
    }

    public func pendingWorkspaceStages(schema: String) async throws -> [KeepTalkingWorkspacePendingStage] {
        let own = try await workspaceStage(schema: schema)?.blobID
        var pending: [KeepTalkingWorkspacePendingStage] = []
        for row in try await stageRows(schema: schema) where row.holder != config.node {
            guard row.blobID != own, row.blobID != row.mergedBlobID, let data = try await blobData(row.blobID) else {
                continue
            }
            pending.append(KeepTalkingWorkspacePendingStage(stage: row.stage, data: data))
        }
        return pending
    }

    public func markWorkspaceStageMerged(_ stage: KeepTalkingWorkspaceStage) async throws {
        guard let row = try await stageRow(schema: stage.schema, holder: stage.holder) else { return }
        row.mergedBlobID = stage.blobID
        try await row.save(on: localStore.database)
    }

    func handleIncomingWorkspaceStage(_ payload: KeepTalkingWorkspaceStagePayload) async throws -> Bool {
        guard payload.from != config.node, payload.contextID == config.contextID, payload.stage.holder == payload.from
        else { return false }
        let stage = payload.stage
        if let existing = try await stageRow(schema: stage.schema, holder: stage.holder),
            existing.updatedAt >= stage.updatedAt
        {
            return false
        }
        try await upsertStage(stage)
        let own = try await workspaceStage(schema: stage.schema)?.blobID
        if stage.blobID == own {
            try await markWorkspaceStageMerged(stage)
            return true
        }
        if let data = try await blobData(stage.blobID) {
            signals.workspaceStages.send(KeepTalkingWorkspacePendingStage(stage: stage, data: data))
        } else {
            try? await announceWantedBlobs([stage.blobID], in: config.contextID)
        }
        return true
    }

    func offerWorkspaceStagesIfArrived(blobID: String) async {
        guard
            let rows = try? await KeepTalkingWorkspaceStageRow.query(on: localStore.database)
                .filter(\.$context.$id == config.contextID)
                .filter(\.$blobID == blobID)
                .all()
        else { return }
        for row in rows where row.holder != config.node && row.mergedBlobID != blobID {
            let own = try? await workspaceStage(schema: row.workspaceSchema)?.blobID
            guard own != blobID, let data = try? await blobData(blobID) else { continue }
            signals.workspaceStages.send(KeepTalkingWorkspacePendingStage(stage: row.stage, data: data))
        }
    }

    func broadcastWorkspaceStages() async {
        await publishWorkspaceCatalog()
        await publishWorkspaceResources()
        guard let rows = try? await stageRows() else { return }
        for row in rows where row.holder == config.node {
            try? sendEnvelope(
                KeepTalkingWorkspaceStagePayload(from: config.node, contextID: config.contextID, stage: row.stage))
        }
    }

    @discardableResult
    private func upsertStage(_ stage: KeepTalkingWorkspaceStage) async throws -> String? {
        let contextID = config.contextID
        return try await localStore.database.transaction { db -> String? in
            let row = try await KeepTalkingWorkspaceStageRow.query(on: db)
                .filter(\.$context.$id == contextID)
                .filter(\.$workspaceSchema == stage.schema)
                .filter(\.$holder == stage.holder)
                .first()
            let previous = row?.blobID
            if let row {
                row.adopt(stage)
                try await row.save(on: db)
            } else {
                try await KeepTalkingWorkspaceStageRow(contextID: contextID, stage: stage).save(on: db)
            }
            return previous
        }
    }

    private func stageRow(schema: String, holder: UUID) async throws -> KeepTalkingWorkspaceStageRow? {
        try await KeepTalkingWorkspaceStageRow.query(on: localStore.database)
            .filter(\.$context.$id == config.contextID)
            .filter(\.$workspaceSchema == schema)
            .filter(\.$holder == holder)
            .first()
    }

    private func stageRows(schema: String? = nil) async throws -> [KeepTalkingWorkspaceStageRow] {
        var query = KeepTalkingWorkspaceStageRow.query(on: localStore.database)
            .filter(\.$context.$id == config.contextID)
        if let schema { query = query.filter(\.$workspaceSchema == schema) }
        return try await query.all()
    }

    private func blobData(_ blobID: String) async throws -> Data? {
        guard let record = try await blobRecord(for: blobID), record.availability == .ready else { return nil }
        return try blobStore.read(relativePath: record.relativePath, blobID: blobID)
    }

    func handleIncomingWorkspaceViewport(_ payload: KeepTalkingWorkspaceViewportPayload) {
        guard payload.from != config.node, payload.contextID == config.contextID else { return }
        guard case .following(let leader) = workspaceFollowMode, leader == payload.from else { return }
        signals.workspaceViewports.send(
            KeepTalkingWorkspaceViewportUpdate(
                contextID: payload.contextID, schema: payload.schema, from: payload.from, state: payload.state))
    }

    // MARK: - The context's workspaces

    public func contextWorkspaces() async throws -> [KeepTalkingContextWorkspaceRecord] {
        try await allContextWorkspaceRecords().filter { !$0.isRemoved }
    }

    func allContextWorkspaceRecords() async throws -> [KeepTalkingContextWorkspaceRecord] {
        let contextID = config.contextID
        return try await localStore.database.transaction { db in
            try await KeepTalkingContextWorkspace.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
                .map(\.record)
        }
    }

    @discardableResult
    public func addContextWorkspace(
        schema: String, title: String, kind: KeepTalkingWorkspaceKind, provider: String
    ) async throws -> KeepTalkingContextWorkspaceRecord {
        let record = KeepTalkingContextWorkspaceRecord(
            schema: schema, title: title, kind: kind, provider: provider, addedBy: config.node)
        try await mergeContextWorkspaces([record])
        await publishWorkspaceCatalog()
        return record
    }

    public func renameContextWorkspace(schema: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            var record = try await allContextWorkspaceRecords().first(where: { $0.schema == schema && !$0.isRemoved })
        else { return }
        record.title = trimmed
        record.updatedAt = Date()
        try await mergeContextWorkspaces([record])
        await publishWorkspaceCatalog()
    }

    public func removeContextWorkspace(schema: String) async throws {
        guard var record = try await allContextWorkspaceRecords().first(where: { $0.schema == schema }) else { return }
        record.isRemoved = true
        record.updatedAt = Date()
        try await mergeContextWorkspaces([record])
        await publishWorkspaceCatalog()
    }

    @discardableResult
    func mergeContextWorkspaces(_ incoming: [KeepTalkingContextWorkspaceRecord]) async throws -> Bool {
        let contextID = config.contextID
        let changed = try await localStore.database.transaction { db -> Bool in
            let existing = try await KeepTalkingContextWorkspace.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
            var bySchema = Dictionary(
                existing.map { ($0.workspaceSchema, $0) }, uniquingKeysWith: { first, _ in first })
            var changed = false
            for record in incoming {
                if let row = bySchema[record.schema] {
                    guard record.updatedAt > row.updatedAt else { continue }
                    row.adopt(record)
                    try await row.save(on: db)
                } else {
                    let row = KeepTalkingContextWorkspace(contextID: contextID, record: record)
                    try await row.save(on: db)
                    bySchema[record.schema] = row
                }
                changed = true
            }
            return changed
        }
        if changed { signals.workspaceCatalogChanges.send(contextID) }
        return changed
    }

    func handleIncomingWorkspaceCatalog(_ payload: KeepTalkingWorkspaceCatalogPayload) async throws -> Bool {
        guard payload.from != config.node, payload.contextID == config.contextID else { return false }
        return try await mergeContextWorkspaces(payload.workspaces)
    }

    func publishWorkspaceCatalog() async {
        guard let records = try? await allContextWorkspaceRecords(), !records.isEmpty else { return }
        try? sendEnvelope(
            KeepTalkingWorkspaceCatalogPayload(from: config.node, contextID: config.contextID, workspaces: records))
    }

    // MARK: - Viewport

    public func setWorkspaceFollowMode(_ mode: KeepTalkingWorkspaceFollowMode) {
        workspaceFollowMode = mode
    }

    public func publishWorkspaceViewport(schema: String, _ state: KeepTalkingWorkspaceViewport) {
        guard workspaceFollowMode == .broadcasting else { return }
        try? sendEnvelope(
            KeepTalkingWorkspaceViewportPayload(
                from: config.node, contextID: config.contextID, schema: schema, state: state))
    }
}

// MARK: - The model's tools

extension KeepTalkingClient {
    func workspaceTools() -> [KeepTalkingActionToolDefinition] {
        let live = workspaceProviders.map(\.manifest)
        let known =
            live
            + workspaceLiftCache.values.map(\.manifest).filter { cached in
                !live.contains { $0.schema == cached.schema }
            }
        guard !known.isEmpty else { return [] }
        var tools = [makeWorkspaceSnapshotTool(manifests: known)]
        let writable = live.filter { !$0.mutations.isEmpty }
        if !writable.isEmpty { tools.append(makeWorkspaceMutateTool(manifests: writable)) }
        return tools
    }

    private func workspaceProvider(schema: String?) -> (any KeepTalkingWorkspaceProviding)? {
        guard let schema else { return workspaceProviders.count == 1 ? workspaceProviders.first : nil }
        return workspaceProviders.first { $0.manifest.schema == schema }
    }

    // MARK: - Resources

    public func workspaceResources(schema: String) async throws -> [KeepTalkingWorkspaceResourceRecord] {
        try await allWorkspaceResourceRecords().filter { $0.schema == schema && !$0.isRemoved }
    }

    func allWorkspaceResourceRecords() async throws -> [KeepTalkingWorkspaceResourceRecord] {
        let contextID = config.contextID
        return try await localStore.database.transaction { db in
            try await KeepTalkingWorkspaceResourceRow.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
                .map(\.record)
        }
    }

    @discardableResult
    public func claimWorkspaceResource(schema: String, attachmentID: UUID) async throws
        -> KeepTalkingWorkspaceResourceRecord
    {
        let existing = try await allWorkspaceResourceRecords().first {
            $0.schema == schema && $0.resourceID == attachmentID
        }
        if let existing, !existing.isRemoved { return existing }
        guard let attachment = try await contextAttachment(attachmentID, in: config.contextID) else {
            throw KeepTalkingWorkspaceError.resourceNotFound(attachmentID.uuidString.lowercased())
        }
        let record = KeepTalkingWorkspaceResourceRecord(
            schema: schema, resourceID: attachmentID, blobID: attachment.blobID, mimeType: attachment.mimeType,
            filename: attachment.filename, addedBy: config.node)
        try await mergeWorkspaceResources([record])
        await publishWorkspaceResources()
        return record
    }

    public func releaseWorkspaceResources(schema: String, keeping: Set<UUID>) async throws {
        let now = Date()
        let released = try await workspaceResources(schema: schema)
            .filter { !keeping.contains($0.resourceID) }
            .map { record in
                var record = record
                record.isRemoved = true
                record.updatedAt = now
                return record
            }
        guard !released.isEmpty else { return }
        try await mergeWorkspaceResources(released)
        await publishWorkspaceResources()
    }

    @discardableResult
    func mergeWorkspaceResources(_ incoming: [KeepTalkingWorkspaceResourceRecord]) async throws -> Bool {
        let contextID = config.contextID
        let stored = try await localStore.database.transaction { db -> [KeepTalkingWorkspaceResourceRecord] in
            let existing = try await KeepTalkingWorkspaceResourceRow.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
            var byKey = Dictionary(
                existing.map { ("\($0.workspaceSchema)/\($0.resourceID)", $0) }, uniquingKeysWith: { first, _ in first }
            )
            var stored: [KeepTalkingWorkspaceResourceRecord] = []
            for record in incoming {
                let key = "\(record.schema)/\(record.resourceID)"
                if let row = byKey[key] {
                    guard record.updatedAt > row.updatedAt else { continue }
                    row.adopt(record)
                    try await row.save(on: db)
                } else {
                    let row = KeepTalkingWorkspaceResourceRow(contextID: contextID, record: record)
                    try await row.save(on: db)
                    byKey[key] = row
                }
                stored.append(record)
            }
            return stored
        }
        await requestBlobsIfMissing(stored.filter { !$0.isRemoved }.map(\.blobID), in: contextID)
        return !stored.isEmpty
    }

    func handleIncomingWorkspaceResources(_ payload: KeepTalkingWorkspaceResourcesPayload) async throws -> Bool {
        guard payload.from != config.node, payload.contextID == config.contextID else { return false }
        return try await mergeWorkspaceResources(payload.resources)
    }

    func publishWorkspaceResources() async {
        guard let records = try? await allWorkspaceResourceRecords(), !records.isEmpty else { return }
        try? sendEnvelope(
            KeepTalkingWorkspaceResourcesPayload(from: config.node, contextID: config.contextID, resources: records))
    }

    public func workspaceResource(_ id: UUID) async throws -> KeepTalkingWorkspaceResource {
        let handle = id.uuidString.lowercased()
        let source: (blobID: String, mimeType: String, name: String)
        if let held = try await allWorkspaceResourceRecords().first(where: { $0.resourceID == id && !$0.isRemoved }) {
            source = (held.blobID, held.mimeType, held.filename)
        } else if let attachment = try await contextAttachment(id, in: config.contextID) {
            source = (attachment.blobID, attachment.mimeType, attachment.filename)
        } else {
            throw KeepTalkingWorkspaceError.resourceNotFound(handle)
        }
        guard source.mimeType.hasPrefix("image/") else {
            throw KeepTalkingWorkspaceError.resourceUnsupported(handle, mimeType: source.mimeType)
        }
        let record = try await KeepTalkingBlobRecord.query(on: localStore.database)
            .filter(\.$id, .equal, source.blobID)
            .first()
        guard let record, record.availability == .ready else {
            try? await announceWantedBlobs([source.blobID], in: config.contextID)
            throw KeepTalkingWorkspaceError.resourceNotReady(handle)
        }
        let data = try blobStore.read(relativePath: record.relativePath, blobID: source.blobID)
        guard
            let fitted = KeepTalkingImageDownscaler.fitted(
                data, mimeType: source.mimeType, target: KeepTalkingWorkspaceResource.imageTarget)
        else {
            throw KeepTalkingWorkspaceError.resourceUnsupported(handle, mimeType: source.mimeType)
        }
        record.lastAccessedAt = Date()
        try? await record.save(on: localStore.database)
        return KeepTalkingWorkspaceResource(
            id: id, name: source.name, mimeType: fitted.mimeType,
            dataURL: "data:\(fitted.mimeType);base64,\(fitted.data.base64EncodedString())")
    }

    private func inlineWorkspaceResource(in payload: Any, schema: String) async throws -> Any {
        guard var object = payload as? [String: Any], let raw = object["resourceHandle"] as? String else {
            return payload
        }
        let handleText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let id = await KeepTalkingIOManager(client: self)
                .resolveResourceHandle(handleText, contextID: config.contextID).settledID
        else { throw KeepTalkingWorkspaceError.resourceNotFound(handleText) }
        let resource = try await workspaceResource(id)
        try await claimWorkspaceResource(schema: schema, attachmentID: id)
        object["resource"] = resource.jsonObject
        object.removeValue(forKey: "resourceHandle")
        return object
    }

    func executeWorkspaceSnapshotToolCall(rawArguments: String) async -> String {
        let args = (try? decodeToolArguments(rawArguments)) ?? [:]
        let schema = args["schema"]?.stringValue
        let granularity =
            KeepTalkingWorkspaceGranularity(rawValue: args["granularity"]?.stringValue ?? "") ?? .full
        guard let provider = workspaceProvider(schema: schema) else {
            if let schema, let cached = workspaceLiftCache[schema] {
                return Self.workspaceSnapshotPayload(
                    cached.manifest, cached.snapshot, note: "from the last lift; no page is open")
            }
            return Self.toolError(KeepTalkingWorkspaceError.noWorkspace(schema: schema).localizedDescription)
        }
        do {
            let snapshot = try await provider.snapshot(granularity: granularity)
            return Self.workspaceSnapshotPayload(provider.manifest, snapshot, note: nil)
        } catch {
            return Self.toolError("could not read \(provider.manifest.schema): \(error.localizedDescription)")
        }
    }

    func executeWorkspaceMutateToolCall(rawArguments: String) async -> String {
        guard let data = rawArguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMutations = args["mutations"] as? [[String: Any]]
        else {
            return Self.toolError(
                "expected {\"schema\": string, \"mutations\": [{operation, payload, targetElementID?}]}")
        }
        let schema = args["schema"] as? String
        guard let provider = workspaceProvider(schema: schema) else {
            return Self.toolError(KeepTalkingWorkspaceError.noWorkspace(schema: schema).localizedDescription)
        }
        var mutations: [KeepTalkingWorkspaceMutation] = []
        var unresolved: [String] = []
        for (index, raw) in rawMutations.enumerated() {
            guard let operation = raw["operation"] as? String else { continue }
            let payload: Any
            do {
                payload = try await inlineWorkspaceResource(
                    in: raw["payload"] ?? [String: Any](), schema: provider.manifest.schema)
            } catch {
                unresolved.append("mutation \(index + 1) (\(operation)): \(error.localizedDescription)")
                continue
            }
            guard JSONSerialization.isValidJSONObject(payload),
                let payloadData = try? JSONSerialization.data(withJSONObject: payload)
            else { continue }
            mutations.append(
                KeepTalkingWorkspaceMutation(
                    operation: operation, payloadJSON: String(decoding: payloadData, as: UTF8.self),
                    targetElementID: raw["targetElementID"] as? String))
        }
        guard !mutations.isEmpty else {
            return Self.toolError((["no valid mutations"] + unresolved).joined(separator: "; "))
        }
        do {
            let result = try await provider.applyMutations(mutations)
            let failed = result.failed + unresolved.count
            let object: [String: Any] = [
                "ok": failed == 0, "schema": provider.manifest.schema, "applied": result.applied,
                "failed": failed, "createdElementIDs": result.createdElementIDs, "errors": result.errors + unresolved,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return Self.toolError("could not change \(provider.manifest.schema): \(error.localizedDescription)")
        }
    }

    private static func workspaceSnapshotPayload(
        _ manifest: KeepTalkingWorkspaceManifest, _ snapshot: KeepTalkingWorkspaceSnapshot, note: String?
    ) -> String {
        var object: [String: Any] = [
            "ok": true, "schema": manifest.schema, "title": manifest.title,
            "granularity": snapshot.granularity.rawValue,
            "stats": [
                "totalElements": snapshot.stats.totalElements, "visibleElements": snapshot.stats.visibleElements,
                "selectedElements": snapshot.stats.selectedElements, "groups": snapshot.stats.groups,
                "connections": snapshot.stats.connections,
            ],
            "text": snapshot.liftedText,
        ]
        if let note { object["note"] = note }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolError(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
