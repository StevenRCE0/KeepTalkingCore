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
    /// Consent: may this catalog's plugins use the host's AI provider
    /// (`host.act.request`) while servicing a call? OFF by default — the user
    /// flips it per catalog; enforcement happens in the host actor on every
    /// act request. Optional so pre-existing catalogue files keep decoding.
    public var allowsACT: Bool?

    public var fingerprint: String {
        KTPPCrypto.fingerprint(publicKeyB64: identityPublicKey)
    }
}

/// Persisted, queryable Catalogue. Actor-isolated; writes are debounced onto a
/// JSON file so a crash can at worst lose the most recent registration (which
/// the next plugin connect re-supplies anyway).
public actor KeepTalkingPluginCatalogueStore {

    private var entries: [UUID: KeepTalkingPluginCatalogueEntry] = [:]
    /// Old catalog id → the canonical catalog it was merged into. Populated by
    /// the load-time dedupe (below) and persisted, so instances minted against
    /// a superseded pairing can be healed to the canonical catalog.
    private var aliases: [UUID: UUID] = [:]
    /// Catalogs with a live session right now — availability is runtime state,
    /// never persisted.
    private var connected: Set<UUID> = []
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let loaded = Self.load(from: fileURL)
        // Historical repair + ongoing hygiene: before pairings were rehydrated
        // into the host actor, EVERY app relaunch re-paired every plugin under
        // a fresh catalog id — one machine accumulated ~50 duplicate rows per
        // plugin. Coalesce duplicates (same identity key + name) into the
        // EARLIEST pairing; the rest become aliases so old references resolve.
        let deduped = Self.dedupeByIdentity(entries: loaded.entries, aliases: loaded.aliases)
        self.entries = deduped.entries
        self.aliases = deduped.aliases
        if deduped.changed, fileURL != nil {
            Task { await self.persistNow() }
        }
    }

    /// Immediate flush; also the deferred-persist hop the init dedupe uses.
    func persistNow() { persist() }

    private static func dedupeByIdentity(
        entries initial: [UUID: KeepTalkingPluginCatalogueEntry],
        aliases initialAliases: [UUID: UUID]
    ) -> (entries: [UUID: KeepTalkingPluginCatalogueEntry], aliases: [UUID: UUID], changed: Bool) {
        var entries = initial
        var aliases = initialAliases
        var canonicalByIdentity: [String: KeepTalkingPluginCatalogueEntry] = [:]
        var changed = false
        for entry in entries.values.sorted(by: { $0.pairedAt < $1.pairedAt }) {
            let identity = "\(entry.identityPublicKey)|\(entry.name)"
            if var canonical = canonicalByIdentity[identity] {
                // Merge what the duplicate knows into the canonical row: the
                // freshest declaration wins, an ACT consent granted anywhere
                // survives, and the duplicate becomes an alias.
                //
                // Consent merges because the principal the user granted is the
                // plugin IDENTITY (its Ed25519 key), not a catalog row. The
                // duplicates are all one identity re-paired across relaunches,
                // rows the user never chose between and never saw — so dropping
                // the grant because the dedupe happened to crown a different row
                // would revoke a consent the user really did give, for reasons
                // invisible to them. Losing it is not the "safe" direction here;
                // it is an arbitrary one.
                if entry.lastSeenAt > canonical.lastSeenAt {
                    canonical.kinds = entry.kinds
                    canonical.meters = entry.meters
                    canonical.manifestVersion = entry.manifestVersion
                    canonical.lastSeenAt = entry.lastSeenAt
                    canonical.version = entry.version
                    canonical.endorsedBy = entry.endorsedBy
                }
                if entry.allowsACT == true { canonical.allowsACT = true }
                canonicalByIdentity[identity] = canonical
                aliases[entry.catalogID] = canonical.catalogID
                entries[entry.catalogID] = nil
                changed = true
            } else {
                canonicalByIdentity[identity] = entry
            }
        }
        for identity in canonicalByIdentity.values {
            entries[identity.catalogID] = identity
        }
        // Aliases must land on a surviving row even when chained.
        for (old, target) in aliases {
            aliases[old] = Self.resolveAlias(target, entries: entries, aliases: aliases)
        }
        return (entries, aliases, changed)
    }

    private static func resolveAlias(
        _ id: UUID,
        entries: [UUID: KeepTalkingPluginCatalogueEntry],
        aliases: [UUID: UUID]
    ) -> UUID {
        var current = id
        var hops = 0
        while entries[current] == nil, let next = aliases[current], next != current, hops < 16 {
            current = next
            hops += 1
        }
        return current
    }

    private func resolveAlias(_ id: UUID) -> UUID {
        Self.resolveAlias(id, entries: entries, aliases: aliases)
    }

    /// The surviving catalog id for `id`: itself when live, its merge target
    /// when it was deduped away. Instances holding superseded ids heal here.
    public func canonicalCatalogID(_ id: UUID) -> UUID {
        entries[id] != nil ? id : resolveAlias(id)
    }

    /// The canonical catalog for a plugin IDENTITY — the resume anchor when a
    /// plugin's claimed catalog id is stale or unknown (its Ed25519 key, not
    /// any id, is what actually identifies it).
    public func catalogID(identityPublicKey: String, name: String) -> UUID? {
        entries.values
            .first { $0.identityPublicKey == identityPublicKey && $0.name == name }?
            .catalogID
            ?? entries.values.first { $0.identityPublicKey == identityPublicKey }?.catalogID
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
                lastSeenAt: .now,
                allowsACT: nil
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
        // Canonicalize like every read does: a caller holding a deduped-away id
        // would otherwise mark a row that no longer exists as connected, and
        // `isConnected` (which does canonicalize) would never see it.
        let canonical = canonicalCatalogID(catalogID)
        if isConnected {
            connected.insert(canonical)
            entries[canonical]?.lastSeenAt = .now
        } else {
            connected.remove(canonical)
        }
    }

    /// Forgets a catalog entirely. Instances the user minted from its kinds are
    /// separate `kt_actions` rows and are NOT touched here — removing those is
    /// an explicit, separately-confirmed action.
    public func removeCatalog(_ catalogID: UUID) {
        // Forget the SURVIVING row, not whichever id the caller happened to
        // hold: a UI row built from a persisted reference can carry an id the
        // dedupe merged away, and deleting under that id removed nothing while
        // the catalog stayed live through its alias.
        let canonical = canonicalCatalogID(catalogID)
        entries[canonical] = nil
        connected.remove(canonical)
        // Drop the aliases that pointed at the row just deleted (and the id the
        // caller used) so nothing resolves to a catalog that no longer exists.
        aliases = aliases.filter { $0.value != canonical }
        aliases[catalogID] = nil
        persist()
    }

    // MARK: Queries

    public func catalogues() -> [KeepTalkingPluginCatalogueEntry] {
        entries.values.sorted { $0.name < $1.name }
    }

    // NOTE: every id-keyed read below canonicalizes first — callers routinely
    // hold ids from persisted rows (instances, grants) minted against pairings
    // the dedupe has since merged away. A direct dictionary lookup here made
    // healed instances invisible to the agent-tool catalog (`act_agent_no_tools`
    // live) because the catalog builds BEFORE dispatch-time healing runs.

    public func catalogue(_ catalogID: UUID) -> KeepTalkingPluginCatalogueEntry? {
        entries[canonicalCatalogID(catalogID)]
    }

    public func isConnected(_ catalogID: UUID) -> Bool {
        connected.contains(canonicalCatalogID(catalogID))
    }

    // MARK: ACT consent

    /// Whether this catalog may use the host's AI provider during calls.
    /// Fail-closed: unknown catalog or unset toggle both read as false.
    public func allowsACT(_ catalogID: UUID) -> Bool {
        entries[canonicalCatalogID(catalogID)]?.allowsACT == true
    }

    public func setAllowsACT(_ allowed: Bool, catalogID: UUID) {
        let canonical = canonicalCatalogID(catalogID)
        guard entries[canonical] != nil else { return }
        entries[canonical]?.allowsACT = allowed
        persist()
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
        let canonical = canonicalCatalogID(catalogID)
        guard let entry = entries[canonical],
            let kind = entry.kinds.first(where: { $0.kindName == kindName })
        else { return nil }
        return Self.summarize(
            kind, in: entry, isAvailable: connected.contains(canonical))
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
        entries[canonicalCatalogID(catalogID)]?.kinds.first { $0.kindName == kindName }
    }

    public func summary(catalogID: UUID, kindName: String)
        -> KeepTalkingPluginActionKindSummary?
    {
        resolvedKind(catalogID: catalogID, kindName: kindName)
    }

    // MARK: Persistence

    /// On-disk shape since the dedupe: entries + the alias map. Older files
    /// were a bare entry array; both decode.
    private struct PersistedCatalogue: Codable {
        var entries: [KeepTalkingPluginCatalogueEntry]
        var aliases: [String: String]?
    }

    private nonisolated static func load(
        from fileURL: URL?
    ) -> (entries: [UUID: KeepTalkingPluginCatalogueEntry], aliases: [UUID: UUID]) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return ([:], [:]) }
        let decoder = JSONDecoder()
        let decodedEntries: [KeepTalkingPluginCatalogueEntry]
        var decodedAliases: [UUID: UUID] = [:]
        if let modern = try? decoder.decode(PersistedCatalogue.self, from: data) {
            decodedEntries = modern.entries
            for (old, target) in modern.aliases ?? [:] {
                if let oldID = UUID(uuidString: old), let targetID = UUID(uuidString: target) {
                    decodedAliases[oldID] = targetID
                }
            }
        } else if let legacy = try? decoder.decode(
            [KeepTalkingPluginCatalogueEntry].self, from: data)
        {
            decodedEntries = legacy
        } else {
            return ([:], [:])
        }
        return (
            Dictionary(
                decodedEntries.map { ($0.catalogID, $0) },
                uniquingKeysWith: { _, latest in latest }),
            decodedAliases
        )
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = PersistedCatalogue(
            entries: Array(entries.values),
            aliases: aliases.isEmpty
                ? nil
                : Dictionary(
                    uniqueKeysWithValues: aliases.map {
                        ($0.key.uuidString, $0.value.uuidString)
                    })
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
