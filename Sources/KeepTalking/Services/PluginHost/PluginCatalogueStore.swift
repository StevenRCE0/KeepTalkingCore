//
//  PluginCatalogueStore.swift
//  KeepTalking
//
//  The **Catalogue** — persisted registry of paired plugin catalogs and the
//  action *kinds* they provide.
//
//  Why this is its own store rather than `kt_actions` rows: kinds are
//  templates, not callable actions (design doc §4.3). Only instances the user
//  mints become `kt_actions`, and those need no migration because
//  `KeepTalkingAction.Payload` is a Codable column.
//
//  **The Catalogue is live.** What a user may create comes from catalogs with a
//  CONNECTED session — never from memory. Persistence exists only to *resolve*
//  what already exists: a saved instance can show its kind's name and schema
//  while its plugin is away, but it does not come alive until that plugin
//  reconnects and re-declares its catalogue. Offering kinds from a remembered
//  catalog would let a plugin that no longer exists advertise capabilities
//  nothing can serve.
//

import Foundation
import MCP

/// One paired plugin catalog plus the kinds it last declared.
public struct KeepTalkingPluginCatalogueEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { catalogID }
    public var catalogID: UUID
    public var name: String
    public var vendor: String
    public var version: String
    public var identityPublicKey: String
    /// "companion" for the runtime app; nil for ordinary plugins.
    public var role: String?
    /// Companion catalog that endorsed this pairing, when it wasn't interactive.
    public var endorsedBy: UUID?
    public var kinds: [KTPPKindDeclaration]
    public var meters: [KTPPMeterDeclaration]
    public var manifestVersion: String?
    public var pairedAt: Date
    public var lastSeenAt: Date

    public var fingerprint: String {
        KTPPCrypto.fingerprint(publicKeyB64: identityPublicKey)
    }
}

/// Persisted, queryable Catalogue. Actor-isolated; writes are debounced onto a
/// JSON file so a crash can at worst lose the most recent registration (which
/// the next plugin connect re-supplies anyway).
public actor KeepTalkingPluginCatalogueStore {

    private var entries: [UUID: KeepTalkingPluginCatalogueEntry] = [:]
    /// Catalogs with a live session right now — availability is runtime state,
    /// never persisted.
    private var connected: Set<UUID> = []
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        self.entries = Self.load(from: fileURL)
    }

    /// Default location beside the node's other application state.
    public static func defaultFileURL() -> URL? {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = base.appending(path: "KeepTalking")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "plugin-catalogue.json")
    }

    // MARK: Registration (driven by the plugin host)

    public func upsertCatalog(
        catalogID: UUID,
        info: KTPPPluginInfo,
        identityPublicKey: String,
        role: String?,
        endorsedBy: UUID?
    ) {
        var entry =
            entries[catalogID]
            ?? KeepTalkingPluginCatalogueEntry(
                catalogID: catalogID,
                name: info.name,
                vendor: info.vendor,
                version: info.version,
                identityPublicKey: identityPublicKey,
                role: role,
                endorsedBy: endorsedBy,
                kinds: [],
                meters: [],
                manifestVersion: nil,
                pairedAt: .now,
                lastSeenAt: .now
            )
        entry.name = info.name
        entry.vendor = info.vendor
        entry.version = info.version
        entry.identityPublicKey = identityPublicKey
        entry.role = role
        entry.endorsedBy = endorsedBy
        entry.lastSeenAt = .now
        entries[catalogID] = entry
        persist()
    }

    public func registerKinds(catalogID: UUID, result: KTPPKindsResult) {
        guard var entry = entries[catalogID] else { return }
        entry.kinds = result.kinds
        entry.meters = result.meters ?? []
        entry.manifestVersion = result.manifestVersion
        entry.lastSeenAt = .now
        entries[catalogID] = entry
        persist()
    }

    public func setConnected(_ isConnected: Bool, catalogID: UUID) {
        if isConnected {
            connected.insert(catalogID)
            entries[catalogID]?.lastSeenAt = .now
        } else {
            connected.remove(catalogID)
        }
    }

    /// Forgets a catalog entirely. Instances the user minted from its kinds are
    /// separate `kt_actions` rows and are NOT touched here — removing those is
    /// an explicit, separately-confirmed action.
    public func removeCatalog(_ catalogID: UUID) {
        entries[catalogID] = nil
        connected.remove(catalogID)
        persist()
    }

    // MARK: Queries

    public func catalogues() -> [KeepTalkingPluginCatalogueEntry] {
        entries.values.sorted { $0.name < $1.name }
    }

    public func catalogue(_ catalogID: UUID) -> KeepTalkingPluginCatalogueEntry? {
        entries[catalogID]
    }

    public func isConnected(_ catalogID: UUID) -> Bool {
        connected.contains(catalogID)
    }

    /// Kinds the user can instantiate right now: **connected catalogs only**.
    /// Companion-role catalogs are skipped — the runtime app is a trust anchor,
    /// not a capability provider.
    public func availableKinds() -> [KeepTalkingPluginActionKindSummary] {
        entries.values
            .filter { connected.contains($0.catalogID) }
            .filter { $0.role != KTPPConstants.companionRole }
            .sorted { $0.name < $1.name }
            .flatMap { entry in
                entry.kinds.map { kind in
                    Self.summarize(kind, in: entry, isAvailable: true)
                }
            }
    }

    /// Resolution for an instance that already exists: its kind declaration
    /// whether or not the plugin is currently connected, with `isAvailable`
    /// telling the caller which it is. Used to render a saved action's name and
    /// scope form — never to offer new ones.
    public func resolvedKind(catalogID: UUID, kindName: String)
        -> KeepTalkingPluginActionKindSummary?
    {
        guard let entry = entries[catalogID],
            let kind = entry.kinds.first(where: { $0.kindName == kindName })
        else { return nil }
        return Self.summarize(
            kind, in: entry, isAvailable: connected.contains(catalogID))
    }

    private static func summarize(
        _ kind: KTPPKindDeclaration,
        in entry: KeepTalkingPluginCatalogueEntry,
        isAvailable: Bool
    ) -> KeepTalkingPluginActionKindSummary {
        KeepTalkingPluginActionKindSummary(
            catalogID: entry.catalogID,
            catalogName: entry.name,
            vendor: entry.vendor,
            kindName: kind.kindName,
            displayName: kind.displayName,
            indexDescription: kind.indexDescription,
            inputSchema: kind.inputSchema,
            scopeSchema: kind.scopeSchema,
            defaultScope: kind.defaultScope,
            subTools: (kind.subTools ?? []).map(\.name),
            remoteAuthorisable: kind.remoteAuthorisable ?? true,
            blockingAuthorisation: kind.blockingAuthorisation ?? false,
            isAvailable: isAvailable
        )
    }

    public func kind(catalogID: UUID, kindName: String) -> KTPPKindDeclaration? {
        entries[catalogID]?.kinds.first { $0.kindName == kindName }
    }

    public func summary(catalogID: UUID, kindName: String)
        -> KeepTalkingPluginActionKindSummary?
    {
        resolvedKind(catalogID: catalogID, kindName: kindName)
    }

    // MARK: Persistence

    private nonisolated static func load(
        from fileURL: URL?
    ) -> [UUID: KeepTalkingPluginCatalogueEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(
                [KeepTalkingPluginCatalogueEntry].self, from: data)
        else { return [:] }
        return Dictionary(decoded.map { ($0.catalogID, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(entries.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
