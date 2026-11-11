//
//  PluginCatalogueStore.swift
//  KeepTalking
//
//  The Catalogue: the plugins the companion has reported and the kinds they
//  declare, persisted so saved instances resolve while a plugin is away. Only
//  connected plugins offer kinds.
//

import Crypto
import Foundation
import MCP

public struct KeepTalkingPluginCatalogueEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { catalogID }
    public var catalogID: UUID
    public var name: String
    public var vendor: String
    public var version: String
    public var kinds: [KTPPKindDeclaration]
    public var meters: [KTPPMeterDeclaration]
    public var manifestVersion: String?
    public var lastSeenAt: Date
    public var allowsACT: Bool?
}

public actor KeepTalkingPluginCatalogueStore {

    private var entries: [UUID: KeepTalkingPluginCatalogueEntry] = [:]
    private var connected: Set<UUID> = []
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        self.entries = Self.load(from: fileURL)
    }

    public func catalogID(forPluginName pluginName: String) -> UUID {
        entries.values.first { $0.name == pluginName }?.catalogID
            ?? Self.derivedCatalogID(pluginName: pluginName)
    }

    public static func derivedCatalogID(pluginName: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("kt.plugin.catalog:\(pluginName)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

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

    // MARK: Registration

    func apply(_ plugins: [KTPPWire.CatalogPlugin]) {
        connected = []
        for plugin in plugins {
            let catalogID = catalogID(forPluginName: plugin.name)
            var entry =
                entries[catalogID]
                ?? KeepTalkingPluginCatalogueEntry(
                    catalogID: catalogID, name: plugin.name, vendor: plugin.vendor, version: plugin.version,
                    kinds: [], meters: [], manifestVersion: nil, lastSeenAt: .now, allowsACT: nil)
            entry.vendor = plugin.vendor
            entry.version = plugin.version
            if let kinds = plugin.kinds {
                entry.kinds = kinds.kinds
                entry.meters = kinds.meters ?? []
                entry.manifestVersion = kinds.manifestVersion
            }
            if plugin.connected {
                connected.insert(catalogID)
                entry.lastSeenAt = .now
            }
            entries[catalogID] = entry
        }
        persist()
    }

    func disconnectAll() {
        connected = []
    }

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

    // MARK: ACT consent

    public func allowsACT(_ catalogID: UUID) -> Bool {
        entries[catalogID]?.allowsACT == true
    }

    public func setAllowsACT(_ allowed: Bool, catalogID: UUID) {
        guard entries[catalogID] != nil else { return }
        entries[catalogID]?.allowsACT = allowed
        persist()
    }

    public func availableKinds() -> [KeepTalkingPluginActionKindSummary] {
        entries.values
            .filter { connected.contains($0.catalogID) }
            .sorted { $0.name < $1.name }
            .flatMap { entry in
                entry.kinds.map { kind in
                    Self.summarize(kind, in: entry, isAvailable: true)
                }
            }
    }

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
            isAvailable: isAvailable,
            access: kind.access
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

    private struct PersistedCatalogue: Codable {
        var entries: [KeepTalkingPluginCatalogueEntry]
    }

    private nonisolated static func load(
        from fileURL: URL?
    ) -> [UUID: KeepTalkingPluginCatalogueEntry] {
        guard let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let persisted = try? JSONDecoder().decode(PersistedCatalogue.self, from: data)
        else { return [:] }
        return Dictionary(
            persisted.entries.map { ($0.catalogID, $0) },
            uniquingKeysWith: { _, latest in latest })
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = PersistedCatalogue(entries: Array(entries.values))
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
