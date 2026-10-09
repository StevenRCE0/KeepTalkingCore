//
//  PluginHost.swift
//  KeepTalking
//
//  KTPP host — an optionally-enabled actor serving `PluginHost` (gRPC,
//  JSON-coded) on the plugin Unix socket. Desktop platforms only; nothing
//  listens until `start()`. A plugin connects and says `Hello` — no pairing
//  and no sessions: whoever reaches the socket is this user, and the plugin's
//  name is its catalog identity — then pushes its action kinds and serves
//  the calls the host sends down its connection.
//  Calls are made verifiable by injecting a `KeepTalkingCallAttestor`.
//  See DESIGN_PLUGIN_ACTIONS.md and Wire/KTPPWireService.swift.
//

#if os(macOS) || os(Linux)

import Foundation
import GRPCCore
import MCP

// MARK: - Public surface types

public struct KTPPCatalogSummary: Sendable {
    public let catalogID: UUID
    public let info: KTPPPluginInfo
    public let role: String?
    public let kinds: KTPPKindsResult?
    public let connected: Bool
}

/// Host-observed AI spend a call incurred through `RequestAct` — the host's
/// own metered cost on the plugin's behalf, which the plugin attests nothing
/// about. Token counts ride along when the connector surfaces them.
public struct KTPPHostActUsage: Sendable, Equatable {
    public var requests: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
}

/// One dispatched call as the host recorded it: the evidence exchanged (when
/// an attestor is injected), what the attestor concluded, and what the call
/// consumed.
public struct KTPPCallRecord: Sendable {
    public let invocationID: String
    public let catalogID: UUID
    public let kindName: String
    public let authorization: KeepTalkingAttestation?
    public let receipt: KeepTalkingAttestation?
    public let verdict: KeepTalkingAttestationVerdict
    public let usage: [KTPPMeterUsage]
    public let hostActUsage: KTPPHostActUsage?
}

public struct KTPPCallOutcome: Sendable {
    public let content: Value
    public let isError: Bool
    public let usage: [KTPPMeterUsage]
    /// Explanatory notes the plugin pushed during the call (`Elucidation`),
    /// in arrival order — display/summarization data.
    public let elucidations: [String]
    public let record: KTPPCallRecord
}

/// One requested ACT attachment, resolved by the actor against the bound
/// call's manifest (read-direction, path-backed) before the handler sees it.
public struct KTPPActAttachment: Sendable {
    public let handle: String
    public let name: String
    public let path: URL
}

/// The actor-side request handed to the injected ACT handler: the plugin's
/// ask plus its already-validated attachments.
public struct KTPPActTurnRequest: Sendable {
    public let task: String
    public let system: String?
    public let expects: String?
    public let maxOutputTokens: Int?
    public let attachments: [KTPPActAttachment]
}

/// Identity of the bound call an ACT turn executes under — attribution for
/// logging and the record's `hostActUsage`.
public struct KTPPActCallContext: Sendable {
    public let invocationID: String
    public let catalogID: UUID
    public let catalogName: String
    public let kindName: String
    public let instanceID: UUID
    public let contextID: UUID
    public let callerNodeID: UUID
}

public enum KTPPHostEvent: Sendable {
    case listening(socketPath: String)
    /// A plugin connected (its `Hello` was answered). A newer connection with
    /// the same plugin name replaces an older one.
    case connected(catalogID: UUID, info: KTPPPluginInfo, role: String?)
    case kindsRegistered(catalogID: UUID, kinds: KTPPKindsResult)
    case disconnected(catalogID: UUID)
    case log(String)
}

public enum KTPPHostError: LocalizedError {
    case notStarted
    case unknownCatalog(UUID)
    case unknownKind(String)
    case notConnected(UUID)
    case timeout(String)
    case protocolViolation(String)
    /// The plugin answered a host request with its own failure — the message
    /// is the plugin's, e.g. a missing dependency.
    case pluginRefused(String)
    /// The host refused a call before sending it; the message says why and
    /// what the caller should do instead.
    case callRefused(String)

    public var errorDescription: String? {
        switch self {
            case .notStarted: return "Plugin host is not started."
            case .unknownCatalog(let id): return "Unknown plugin catalog \(id.uuidString.lowercased())."
            case .unknownKind(let name): return "No connected catalog registers kind '\(name)'."
            case .notConnected(let id): return "Plugin catalog \(id.uuidString.lowercased()) is not connected."
            case .timeout(let what): return "KTPP timeout waiting for \(what)."
            case .protocolViolation(let reason): return "KTPP protocol violation: \(reason)"
            case .pluginRefused(let message): return message
            case .callRefused(let message): return message
        }
    }
}

// MARK: - Host actor

public actor KeepTalkingPluginHost {
    /// A catalog's live connection: where host → plugin messages are queued.
    /// The connection's writer drains the outbox onto the stream in order.
    private struct Connection {
        /// Tells this connection apart from a newer one for the same plugin.
        let token: UUID
        let outbox: AsyncStream<KTPPWire.HostMessage>.Continuation
    }

    private struct CatalogState {
        var info: KTPPPluginInfo
        var role: String?
        var kinds: KTPPKindsResult?
        var connection: Connection?
    }

    private let hostNodeID: UUID
    private let socketPath: String
    /// Random per launch; every `Welcome` carries it, so plugins can tell a
    /// host restart from a reconnect.
    private let instance = UUID().uuidString.lowercased()

    /// The Catalogue — persisted kinds, queried by the app's action-creation UI.
    public let catalogue: KeepTalkingPluginCatalogueStore
    private var attestor: any KeepTalkingCallAttestor

    private var server: KTPPWireServer?
    private var serveTask: Task<Void, Never>?
    private var catalogs: [UUID: CatalogState] = [:]
    /// In-flight host → plugin requests, tagged with the connection they went
    /// out on: a reply can only come back over that connection.
    private var pending:
        [UInt64: (connection: UUID, continuation: CheckedContinuation<KTPPWire.PluginMessage.Body, Error>)] =
            [:]
    private var lastRequestID: UInt64 = 0
    private var kindWaiters: [(kind: String, continuation: CheckedContinuation<UUID, Error>)] = []
    private var records: [KTPPCallRecord] = []

    /// One provisioned resource of an in-flight call, kept host-side for
    /// `host.act.request` attachment resolution.
    private struct ActiveResourceRef {
        let path: URL?
        let direction: KTResourceManifest.Direction
        let name: String
    }

    /// State for a call currently awaiting its `plugin.call.result` — the
    /// binding anchor for the reverse-direction `host.act.*` operations the
    /// servicing plugin may issue. Keyed by invocationID; created in
    /// `callKind` before the frame is sent, removed when the response (or
    /// timeout) lands — so ACT and elucidation are honored exactly while the
    /// call they belong to is running, never after.
    private struct ActiveCallState {
        let catalogID: UUID
        let catalogName: String
        let kindName: String
        let instanceID: UUID
        let contextID: UUID
        let callerNodeID: UUID
        let resourcesByHandle: [String: ActiveResourceRef]
        /// Kind ceiling ∩ instance-scope narrowing for the `act` capability
        /// (§7.5): computed once at dispatch so the reverse-direction handler
        /// can gate without re-deriving declarations mid-call.
        let actPermitted: Bool
        let onElucidation: (@Sendable (String, String?) -> Void)?
        var actRequests: Int = 0
        var actInputTokens: Int = 0
        var actOutputTokens: Int = 0
        var sawTokenCounts: Bool = false
        var elucidations: [String] = []
        var elucidationsDropped: Bool = false
    }

    /// Whether a call on `kind` under `instanceScope` may use `host.act`:
    /// the kind must declare the fixed `act` capability, and an instance
    /// scope carrying the reserved `capabilities` key must include it (the
    /// user's narrowing wins — fail-closed on both dials).
    static func actCapabilityPermitted(
        kind: KTPPKindDeclaration?, instanceScope: Value?
    ) -> Bool {
        guard kind?.declaredCapabilities.contains(.act) == true else { return false }
        guard case .object(let fields)? = instanceScope,
            let narrowing = fields["capabilities"]
        else {
            // No narrowing recorded at all: the kind's declaration stands.
            return true
        }
        // A narrowing that isn't a list of tokens is malformed, and an
        // unreadable dial must not read as "unrestricted" — that turned a
        // corrupt or hand-edited scope bag into a silent grant of AI spend.
        guard case .array(let scoped) = narrowing else { return false }
        return scoped.contains { entry in
            if case .string(let token) = entry {
                return token == KTPPPluginCapability.act.rawValue
            }
            return false
        }
    }

    private var activeCalls: [String: ActiveCallState] = [:]

    /// Hard per-call ACT budget (host policy; constants in v1).
    static let maxActRequestsPerCall = 4
    static let maxActAttachmentBytes = 256 * 1024
    static let defaultActMaxOutputTokens = 4096
    /// Elucidation caps — excess is dropped, never an error: narration must
    /// not be able to fail a call.
    static let maxElucidationsPerCall = 64
    static let elucidationMessageCap = 200
    static let elucidationDetailCap = 4096

    /// The injected AI seam: runs one bounded, tool-less ACT turn on the
    /// host node's LOCAL connector. The actor gates (binding, consent,
    /// budget, attachment resolution) before this is ever invoked; it stays
    /// AI-free itself. Unset = `host.act.request` answers `act_unavailable`.
    private var actHandler: (@Sendable (KTPPActTurnRequest, KTPPActCallContext) async throws -> KTPPActResult)?

    public func setACTHandler(
        _ handler: (@Sendable (KTPPActTurnRequest, KTPPActCallContext) async throws -> KTPPActResult)?
    ) {
        actHandler = handler
    }

    private var eventHandler: (@Sendable (KTPPHostEvent) -> Void)?

    public init(
        hostNodeID: UUID,
        socketPath: String,
        catalogue: KeepTalkingPluginCatalogueStore? = nil,
        attestor: any KeepTalkingCallAttestor = KeepTalkingUnattestedCalls()
    ) {
        self.hostNodeID = hostNodeID
        self.socketPath = socketPath
        self.attestor = attestor
        self.catalogue =
            catalogue
            ?? KeepTalkingPluginCatalogueStore(
                fileURL: KeepTalkingPluginCatalogueStore.defaultFileURL())
    }

    /// Makes plugin calls verifiable: the attestor authorizes each call before
    /// it goes out and checks the plugin's receipt when the result comes back.
    /// Default: `KeepTalkingUnattestedCalls`.
    public func setAttestor(_ attestor: any KeepTalkingCallAttestor) {
        self.attestor = attestor
    }

    /// Invoked when a plugin asks the user to create an instance of one of its
    /// kinds (`host.action.create`). Returning an action id means created;
    /// returning nil means declined. Unset = the reverse API is unsupported.
    private var actionProposalHandler: (@Sendable (KeepTalkingPluginActionProposal) async -> UUID?)?

    public func setActionProposalHandler(
        _ handler: (@Sendable (KeepTalkingPluginActionProposal) async -> UUID?)?
    ) {
        actionProposalHandler = handler
    }

    private var addActionUIHandler: (@Sendable (_ kindName: String?, _ pluginName: String?) async -> Void)?

    public func setAddActionUIHandler(
        _ handler: (@Sendable (_ kindName: String?, _ pluginName: String?) async -> Void)?
    ) {
        addActionUIHandler = handler
    }

    /// Directory the socket and its discovery file live in.
    ///
    /// This must be reachable from OUTSIDE the app: plugins are separate,
    /// unsandboxed processes. A sandboxed KeepTalking's own Application Support
    /// is inside its container — invisible to them, and at ~120 bytes over the
    /// ~104-byte Unix socket path limit besides. So prefer the **app-group**
    /// container (shared by design, and short enough), and fall back to plain
    /// Application Support for unsandboxed hosts like the CLI.
    public static func socketDirectory() -> URL {
        if let groupID = Bundle.main.object(
            forInfoDictionaryKey: "KEEP_TALKING_APP_GROUP") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID)
        {
            return container
        }
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "KeepTalking")
    }

    /// The socket for a given node, beside the discovery file plugins read.
    ///
    /// Named after the node so two KeepTalking instances on one machine (a dev
    /// build and a release build, say) never fight over the same path — and so
    /// a plugin that reconnects reaches the same node it paired with rather
    /// than whichever process bound first.
    public static func socketPath(forNode nodeID: UUID) -> String {
        let short = nodeID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        let candidate = socketDirectory().appending(path: "ktpp-\(short).sock").path
        // Last-ditch guard: still too long (deeply nested container) means no
        // plugin could connect anyway, so fall back to the shortest path we
        // can name rather than binding something unusable.
        return candidate.utf8.count <= 100
            ? candidate
            : (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("ktpp-\(short).sock")
    }

    /// Every `KeepTalkingClient` on a node shares ONE host: connections live on
    /// the instance that accepted them, so a per-client host would leave the
    /// client dispatching a call unable to see the plugin that can serve it.
    private static let sharedHostsLock = NSLock()
    nonisolated(unsafe) private static var sharedHosts: [UUID: KeepTalkingPluginHost] = [:]

    public static func shared(forNode nodeID: UUID) -> KeepTalkingPluginHost {
        sharedHostsLock.lock()
        defer { sharedHostsLock.unlock() }
        if let existing = sharedHosts[nodeID] { return existing }
        let host = KeepTalkingPluginHost(hostNodeID: nodeID, socketPath: socketPath(forNode: nodeID))
        sharedHosts[nodeID] = host
        return host
    }

    public func setEventHandler(_ handler: (@Sendable (KTPPHostEvent) -> Void)?) {
        eventHandler = handler
    }

    private func emit(_ event: KTPPHostEvent) {
        eventHandler?(event)
    }

    private func log(_ message: String) {
        emit(.log(message))
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard server == nil else { return }
        await rehydratePersistedCatalogs()

        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: socketDirectory, withIntermediateDirectories: true)

        // The server holds this actor as its handler until `stop()` drops it.
        let server = KTPPWireServer(socketPath: socketPath, handler: self)
        self.server = server
        serveTask = Task { [weak self] in
            do {
                try await server.serve()
            } catch {
                await self?.log("plugin server ended: \(error.localizedDescription)")
            }
        }
        do {
            try await server.waitUntilListening()
        } catch {
            serveTask?.cancel()
            serveTask = nil
            self.server = nil
            throw error
        }

        // Reachability gate: same-user only. The socket's directory is the
        // user's own; the socket itself is made owner-only as well.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: socketPath)
        writeDiscoveryFile()

        emit(.listening(socketPath: socketPath))
    }

    public func stop() async {
        guard let server else { return }
        // Tell every plugin this is deliberate, then end its connection; each
        // connection's own teardown reports it closed.
        for state in catalogs.values {
            guard let connection = state.connection else { continue }
            connection.outbox.yield(
                KTPPWire.HostMessage(
                    body: .goodbye(
                        KTPPWire.Goodbye(reason: .shuttingDown, message: "KeepTalking is stopping"))))
            connection.outbox.finish()
        }
        for (_, entry) in pending {
            entry.continuation.resume(throwing: KTPPHostError.notStarted)
        }
        pending.removeAll()
        server.beginGracefulShutdown()
        self.server = nil
        serveTask?.cancel()
        serveTask = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: discoveryFilePath)
    }

    private var discoveryFilePath: String {
        ((socketPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("ktpp.json")
    }

    private func writeDiscoveryFile() {
        let discovery: [String: Any] = [
            "socketPath": socketPath,
            "hostNodeID": hostNodeID.uuidString.lowercased(),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "protocolVersion": KTPPWire.protocolVersion,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: discovery) {
            FileManager.default.createFile(atPath: discoveryFilePath, contents: data)
        }
    }

    // MARK: Introspection

    public func listCatalogs() -> [KTPPCatalogSummary] {
        catalogs.map { id, state in
            KTPPCatalogSummary(
                catalogID: id,
                info: state.info,
                role: state.role,
                kinds: state.kinds,
                connected: state.connection != nil
            )
        }
    }

    public func callRecords() -> [KTPPCallRecord] { records }

    /// Asks every connected companion to reveal its main window
    /// and make it key (`RevealRequest`). Returns whether at least one
    /// companion revealed — false means no companion is connected, or the
    /// connected one has no UI, so the caller can fall back to launching the
    /// companion app.
    @discardableResult
    public func revealCompanion(timeout: TimeInterval = 5) async -> Bool {
        let targets = catalogs.filter {
            $0.value.role == KTPPWire.Role.companion.rawValue && $0.value.connection != nil
        }.map(\.key)
        var acknowledged = false
        for catalogID in targets {
            guard
                case .reveal(let result)? = try? await request(
                    catalogID: catalogID, .reveal(KTPPWire.RevealRequest()),
                    awaiting: "reveal", timeout: timeout),
                result.revealed
            else { continue }
            acknowledged = true
        }
        return acknowledged
    }

    /// Most choices one scope-options answer may carry; the rest are dropped
    /// (the plugin can narrow with `query`).
    public static let maxScopeOptions = 500

    /// The live choices a connected catalog offers for one scope key of one of
    /// its kinds — what the instance form shows instead of a free-text field.
    /// `scope` is the form's current bag; `query` narrows a long list
    /// plugin-side.
    ///
    /// Only keys declared with `x-ktpp-options.live` are asked. The answer is
    /// untrusted display data, capped and trimmed here; nothing in it widens
    /// what an instance may do.
    public func scopeOptions(
        catalogID: UUID,
        kindName: String,
        key: String,
        scope: [String: Value] = [:],
        query: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> [KTPPScopeOption] {
        guard let state = catalogs[catalogID] else { throw KTPPHostError.unknownCatalog(catalogID) }
        guard state.connection != nil else { throw KTPPHostError.notConnected(catalogID) }
        guard let kind = state.kinds?.kinds.first(where: { $0.kindName == kindName }) else {
            throw KTPPHostError.unknownKind(kindName)
        }
        guard KTPPScopeOptionsSpec.parse(scopeSchema: kind.scopeSchema, key: key)?.isLive == true
        else {
            throw KTPPHostError.protocolViolation(
                "kind '\(kindName)' declares no live options for '\(key)'")
        }
        let reply = try await request(
            catalogID: catalogID,
            .scopeOptions(
                KTPPScopeOptionsRequest(
                    kindName: kindName, key: key, scope: scope,
                    query: query.flatMap { $0.isEmpty ? nil : $0 })),
            awaiting: "scope options", timeout: timeout)
        guard case .scopeOptions(let result) = reply else {
            throw KTPPHostError.protocolViolation("expected scope options, got \(reply.label)")
        }
        return Array(result.options.compactMap { $0.sanitized() }.prefix(Self.maxScopeOptions))
    }

    // MARK: Declared resources and generated files

    /// Reads one resource a connected catalog's kind DECLARES — the
    /// plugin-resources meta tool's single exception to "IO rides the call".
    /// Answered with MCP's `resources/read` contents, verbatim; undeclared
    /// uris are refused before anything is sent.
    public func readResource(
        catalogID: UUID, kindName: String, uri: String, timeout: TimeInterval = 30
    ) async throws -> [Resource.Content] {
        guard let state = catalogs[catalogID] else { throw KTPPHostError.unknownCatalog(catalogID) }
        guard state.connection != nil else { throw KTPPHostError.notConnected(catalogID) }
        guard let kind = state.kinds?.kinds.first(where: { $0.kindName == kindName }) else {
            throw KTPPHostError.unknownKind(kindName)
        }
        guard kind.resources?.contains(where: { $0.uri == uri }) == true else {
            throw KTPPHostError.protocolViolation("'\(uri)' is not a resource \(kindName) declares")
        }
        let reply = try await request(
            catalogID: catalogID,
            .resourceRead(KTPPResourceReadRequest(kindName: kindName, uri: uri)),
            awaiting: "resource read", timeout: timeout)
        guard case .resourceRead(let result) = reply else {
            throw KTPPHostError.protocolViolation("expected resource contents, got \(reply.label)")
        }
        return result.contents
    }

    /// Tool-call IO mapped to KTRM at call time: every file a result carries —
    /// an image, audio, or embedded resource contents — becomes a KeepTalking
    /// resource rather than bytes in the reply. It fills the outputs the caller
    /// requested first (the run's write slots, delivered per their persistence;
    /// a single-file slot takes one, a collection slot the rest); whatever finds
    /// no slot is written to `runDirectory`, which the run delivers as private
    /// OTBs. An image also stays in the result, so the agent driving the tool
    /// still sees it; anything else is replaced by a note saying where it went.
    /// Text resource contents with no slot stay inline, as MCP returned them.
    static func mappingGeneratedContents(
        _ content: [Tool.Content], into manifest: KTResourceManifest?, runDirectory: URL?
    ) -> [Tool.Content] {
        var slots = (manifest?.entries ?? []).filter { $0.direction == .write && $0.path != nil }
        return content.enumerated().flatMap { index, item -> [Tool.Content] in
            guard let file = generatedFile(item, index: index) else { return [item] }
            let slotIndex =
                slots.firstIndex(where: { !$0.isDirectory }) ?? slots.firstIndex(where: \.isDirectory)
            let target: URL
            let destination: String
            if let slotIndex, let slotPath = slots[slotIndex].path {
                let slot = slots[slotIndex]
                target = slot.isDirectory ? slotPath.appendingPathComponent(file.name) : slotPath
                destination = KTResourceManifest.resourceURI(
                    handle: slot.envKey, child: slot.isDirectory ? file.name : nil)
                if !slot.isDirectory { slots.remove(at: slotIndex) }
            } else if !file.isText, let runDirectory {
                target = uniqueFile(named: file.name, in: runDirectory)
                destination = "a private resource (handle in produced_resources)"
            } else {
                return [item]
            }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: target)
            } catch {
                return [item]
            }
            let note = Tool.Content.text(
                text: "[\(file.name) (\(file.data.count) bytes) delivered to \(destination)]",
                annotations: nil, _meta: nil)
            return file.staysInline ? [item, note] : [note]
        }
    }

    /// The file a content block carries, if any: its bytes, a file name, and
    /// whether it is text (inline when unclaimed) or an image (kept visible).
    private static func generatedFile(
        _ item: Tool.Content, index: Int
    ) -> (name: String, data: Data, isText: Bool, staysInline: Bool)? {
        func named(_ stem: String, _ mimeType: String) -> String {
            MIMEType.preferredExtension(forMIMEType: mimeType).map { "\(stem).\($0)" } ?? stem
        }
        switch item {
            case .image(let base64, let mimeType, _, _):
                guard let data = decodedBase64(base64) else { return nil }
                return (named("image-\(index + 1)", mimeType), data, false, true)
            case .audio(let base64, let mimeType, _, _):
                guard let data = decodedBase64(base64) else { return nil }
                return (named("audio-\(index + 1)", mimeType), data, false, false)
            case .resource(let resource, _, _):
                let name = resourceFileName(uri: resource.uri, fallback: "resource-\(index + 1)")
                if let data = resource.blob.flatMap(decodedBase64) {
                    let isImage = resource.mimeType?.hasPrefix("image/") == true
                    return (name, data, false, isImage)
                }
                if let text = resource.text { return (name, Data(text.utf8), true, false) }
                return nil
            default:
                return nil
        }
    }

    /// Bare base64, or the payload of a `data:` URL.
    private static func decodedBase64(_ text: String) -> Data? {
        let payload = text.range(of: ";base64,").map { String(text[$0.upperBound...]) } ?? text
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func uniqueFile(named name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// A safe single-component file name from a resource uri's last segment.
    static func resourceFileName(uri: String, fallback: String) -> String {
        let segment = uri.split(separator: "?").first.flatMap { $0.split(separator: "/").last } ?? ""
        let safe = String(segment.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return safe.isEmpty ? fallback : String(safe.prefix(120))
    }

    /// Awaits the first connected catalog that registers `kindName`.
    public func waitForKind(_ kindName: String, timeout: TimeInterval) async throws -> UUID {
        if let existing = connectedCatalogID(registering: kindName) {
            return existing
        }
        return try await withCheckedThrowingContinuation { continuation in
            kindWaiters.append((kindName, continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expireKindWaiter(kindName)
            }
        }
    }

    private func expireKindWaiter(_ kindName: String) {
        for (index, waiter) in kindWaiters.enumerated().reversed() where waiter.kind == kindName {
            waiter.continuation.resume(throwing: KTPPHostError.timeout("kind '\(kindName)'"))
            kindWaiters.remove(at: index)
        }
    }

    private func connectedCatalogID(registering kindName: String) -> UUID? {
        catalogs.first { _, state in
            state.connection != nil && state.kinds?.kinds.contains { $0.kindName == kindName } == true
        }?.key
    }

    // MARK: Calling

    /// Executes one call against a connected catalog's kind: the attestor
    /// authorizes it, the call goes down the plugin's connection, and the
    /// result comes back with the plugin's usage and, when the plugin's
    /// attestor makes one, its receipt — which the host's attestor verifies
    /// before the record lands.
    ///
    /// `manifest` is the run's staged resource manifest; it projects into the
    /// call's `resources` block (handles + resolved paths, §3.1 of the
    /// resources design doc). No file bytes cross the socket — the plugin SDK
    /// reads/writes the paths directly and hides them from handler code.
    public func callKind(
        catalogID: UUID,
        kindName: String,
        tool: String? = nil,
        arguments: [String: Value],
        instanceID: UUID,
        instanceScope: Value?,
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        callerNodeID: UUID? = nil,
        manifest: KTResourceManifest? = nil,
        onElucidation: (@Sendable (String, String?) -> Void)? = nil,
        timeout: TimeInterval = 300
    ) async throws -> KTPPCallOutcome {
        guard let state = catalogs[catalogID] else { throw KTPPHostError.unknownCatalog(catalogID) }
        guard state.connection != nil else { throw KTPPHostError.notConnected(catalogID) }
        guard state.kinds?.kinds.contains(where: { $0.kindName == kindName }) == true else {
            throw KTPPHostError.unknownKind(kindName)
        }

        let invocationID = UUID.v7().uuidString.lowercased()
        let callerNodeID = callerNodeID ?? hostNodeID
        let argumentsValue = Value.object(arguments)
        let resources = KTPPResources(manifest: manifest)
        let statement = KeepTalkingCallStatement(
            invocationID: invocationID,
            hostNodeID: hostNodeID,
            callerNodeID: callerNodeID,
            contextID: contextID,
            executorID: catalogID,
            kindName: kindName,
            tool: tool,
            actionID: instanceID,
            scope: instanceScope,
            arguments: argumentsValue,
            resources: resources?.entries ?? [],
            issuedAt: .now)
        let attestor = self.attestor
        let authorization = try await attestor.authorize(statement)

        // The binding anchor for the plugin's RequestAct / Elucidation:
        // created BEFORE the call goes out, torn down (below, defer) when the
        // result or timeout lands. Actor reentrancy lets act() /
        // handleElucidation() mutate this entry while we await the result.
        activeCalls[invocationID] = ActiveCallState(
            catalogID: catalogID,
            catalogName: state.info.name,
            kindName: kindName,
            instanceID: instanceID,
            contextID: contextID,
            callerNodeID: callerNodeID,
            resourcesByHandle: Dictionary(
                uniqueKeysWithValues: (resources?.entries ?? []).map { entry in
                    (
                        entry.handle,
                        ActiveResourceRef(
                            path: entry.path.map { URL(fileURLWithPath: $0) },
                            direction: entry.direction,
                            name: entry.name)
                    )
                }),
            actPermitted: Self.actCapabilityPermitted(
                kind: state.kinds?.kinds.first { $0.kindName == kindName },
                instanceScope: instanceScope),
            onElucidation: onElucidation)
        defer { activeCalls.removeValue(forKey: invocationID) }

        let call = KTPPCallRequest(
            requestID: invocationID,
            contextID: contextID.uuidString.lowercased(),
            callerNodeID: callerNodeID.uuidString.lowercased(),
            kindName: kindName,
            tool: tool,
            arguments: argumentsValue,
            instance: KTPPInstanceRef(id: instanceID.uuidString.lowercased(), scope: instanceScope),
            resources: resources,
            authorization: authorization
        )
        let reply = try await request(
            catalogID: catalogID, .call(call), awaiting: "call result", timeout: timeout)
        guard case .callResult(let result) = reply else {
            throw KTPPHostError.protocolViolation("expected a call result, got \(reply.label)")
        }
        let usage = result.usage ?? []
        let verdict = await attestor.verify(
            receipt: result.receipt,
            result: KeepTalkingCallResultStatement(
                invocationID: invocationID, content: result.content,
                isError: result.isError, usage: usage),
            statement: statement,
            authorization: authorization)

        // Fold what the plugin's RequestAct turns accumulated during the call
        // into the record, and the elucidation log into the outcome for the
        // caller's backfeed.
        let activeState = activeCalls[invocationID]
        let hostActUsage: KTPPHostActUsage? = activeState.flatMap { state in
            guard state.actRequests > 0 else { return nil }
            return KTPPHostActUsage(
                requests: state.actRequests,
                inputTokens: state.sawTokenCounts ? state.actInputTokens : nil,
                outputTokens: state.sawTokenCounts ? state.actOutputTokens : nil)
        }

        let record = KTPPCallRecord(
            invocationID: invocationID,
            catalogID: catalogID,
            kindName: kindName,
            authorization: authorization,
            receipt: result.receipt,
            verdict: verdict,
            usage: usage,
            hostActUsage: hostActUsage
        )
        records.append(record)

        return KTPPCallOutcome(
            content: result.content,
            isError: result.isError,
            usage: usage,
            elucidations: activeState?.elucidations ?? [],
            record: record
        )
    }

    // MARK: Request/response plumbing

    /// Sends one request down the plugin's connection and awaits its answer.
    /// A `failure` answer throws `pluginRefused` with the plugin's message; a
    /// connection that ends first fails the request at once.
    private func request(
        catalogID: UUID, _ body: KTPPWire.HostMessage.Body, awaiting what: String,
        timeout: TimeInterval
    ) async throws -> KTPPWire.PluginMessage.Body {
        guard let connection = catalogs[catalogID]?.connection else {
            throw KTPPHostError.notConnected(catalogID)
        }
        lastRequestID += 1
        let id = lastRequestID
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = (connection.token, continuation)
            connection.outbox.yield(KTPPWire.HostMessage(id: id, body: body))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.failPending(id, error: KTPPHostError.timeout(what))
            }
        }
        if case .failure(let failure) = reply {
            throw KTPPHostError.pluginRefused(failure.message)
        }
        return reply
    }

    private func failPending(_ id: UInt64, error: Error) {
        if let entry = pending.removeValue(forKey: id) {
            entry.continuation.resume(throwing: error)
        }
    }

    /// Fails every request still waiting on `connection` — it can no longer
    /// be answered, so callers learn now rather than at a minutes-long timeout.
    private func failPending(connection: UUID, catalogID: UUID) {
        for (id, entry) in pending where entry.connection == connection {
            failPending(id, error: KTPPHostError.notConnected(catalogID))
        }
    }

    private func resolvePending(_ id: UInt64, with body: KTPPWire.PluginMessage.Body, connection: UUID) {
        guard let entry = pending[id], entry.connection == connection else { return }
        pending[id] = nil
        entry.continuation.resume(returning: body)
    }

    // MARK: Connections

    private var rehydrated = false

    /// Loads persisted catalogs into the actor so saved instances resolve
    /// across relaunches. Rehydrated catalogs carry their stored kind
    /// declarations; nothing is OFFERED until its plugin connects — the
    /// Catalogue-is-live rule holds.
    private func rehydratePersistedCatalogs() async {
        guard !rehydrated else { return }
        rehydrated = true
        for entry in await catalogue.catalogues() where catalogs[entry.catalogID] == nil {
            catalogs[entry.catalogID] = CatalogState(
                info: KTPPPluginInfo(
                    name: entry.name, vendor: entry.vendor, version: entry.version),
                role: entry.role,
                kinds: entry.kinds.isEmpty
                    ? nil
                    : KTPPKindsResult(
                        manifestVersion: entry.manifestVersion ?? "",
                        manifestHash: "",
                        kinds: entry.kinds,
                        meters: entry.meters.isEmpty ? nil : entry.meters))
        }
        log("rehydrated \(catalogs.count) persisted catalog(s)")
    }

    /// Takes a plugin's `Hello` on a new connection and queues the `Welcome`
    /// on `outbox` (the connection's writer drains it). A plugin is its name:
    /// an older connection for the same name is told it was superseded and
    /// ended — a restarted plugin or a stray second copy, never two at once.
    private func attach(
        _ hello: KTPPWire.Hello, outbox: AsyncStream<KTPPWire.HostMessage>.Continuation
    ) async -> (catalogID: UUID, token: UUID) {
        let catalogID = await catalogue.catalogID(forPluginName: hello.name)
        let info = KTPPPluginInfo(name: hello.name, vendor: hello.vendor, version: hello.version)
        let role = hello.role == .companion ? KTPPWire.Role.companion.rawValue : nil
        let token = UUID()

        if let previous = catalogs[catalogID]?.connection {
            previous.outbox.yield(
                KTPPWire.HostMessage(
                    body: .goodbye(
                        KTPPWire.Goodbye(
                            reason: .superseded,
                            message: "a newer connection for \(hello.name) arrived"))))
            previous.outbox.finish()
            failPending(connection: previous.token, catalogID: catalogID)
            log("replaced the previous connection of \(hello.name)")
        }

        var state = catalogs[catalogID] ?? CatalogState(info: info, role: role)
        state.info = info
        state.role = role
        state.connection = Connection(token: token, outbox: outbox)
        catalogs[catalogID] = state
        outbox.yield(
            KTPPWire.HostMessage(
                body: .welcome(
                    KTPPWire.Welcome(hostNodeID: hostNodeID.uuidString.lowercased(), instance: instance))))

        // Awaited, not fired off: the plugin's kinds follow right behind its
        // hello, and registering them needs this row to exist.
        await catalogue.upsertCatalog(catalogID: catalogID, info: info, role: role)
        await catalogue.setConnected(true, catalogID: catalogID)
        emit(.connected(catalogID: catalogID, info: info, role: role))
        log(
            "connected: \(hello.name) \(hello.version) "
                + "(\(hello.role.rawValue), instance \(hello.instance.prefix(8)))")
        return (catalogID, token)
    }

    /// Ends a connection's bookkeeping. Only the catalog's CURRENT connection
    /// clears its state: a replaced connection's teardown fails its own
    /// requests and nothing else.
    private func detach(catalogID: UUID, token: UUID) async {
        failPending(connection: token, catalogID: catalogID)
        guard catalogs[catalogID]?.connection?.token == token else { return }
        catalogs[catalogID]?.connection?.outbox.finish()
        catalogs[catalogID]?.connection = nil
        await catalogue.setConnected(false, catalogID: catalogID)
        // A newer connection may have arrived across that await; keep the
        // store in step with the actor.
        if catalogs[catalogID]?.connection != nil {
            await catalogue.setConnected(true, catalogID: catalogID)
        }
        emit(.disconnected(catalogID: catalogID))
    }

    /// One plugin → host message on `Connect`. Answers resolve their request;
    /// notifications are handled in arrival order — which is what guarantees
    /// an elucidation sent before a call's result is recorded before the
    /// result closes the call. Returns false when the plugin said goodbye.
    private func receive(
        _ message: KTPPWire.PluginMessage, catalogID: UUID, connection: UUID
    ) async -> Bool {
        if let replyTo = message.replyTo {
            resolvePending(replyTo, with: message.body, connection: connection)
            return true
        }
        switch message.body {
            case .kinds(let kinds):
                await storeKinds(catalogID: catalogID, kinds: kinds)
            case .elucidation(let note):
                handleElucidation(note, catalogID: catalogID)
            case .goodbye(let goodbye):
                log("\(catalogs[catalogID]?.info.name ?? "plugin") said goodbye (\(goodbye.reason.rawValue))")
                return false
            case .hello:
                log("ignoring a second hello on one connection")
            case .failure(let failure):
                log("plugin failure: \(failure.message)")
            case .unknown where message.id != nil:
                catalogs[catalogID]?.connection?.outbox.yield(
                    KTPPWire.HostMessage(
                        replyTo: message.id,
                        body: .failure(
                            KTPPWire.Failure(code: .unsupported, message: "this host does not handle that request"))))
            default:
                break
        }
        return true
    }

    private func storeKinds(catalogID: UUID, kinds: KTPPKindsResult) async {
        catalogs[catalogID]?.kinds = kinds
        await catalogue.registerKinds(catalogID: catalogID, result: kinds)
        emit(.kindsRegistered(catalogID: catalogID, kinds: kinds))
        for (index, waiter) in kindWaiters.enumerated().reversed() {
            if kinds.kinds.contains(where: { $0.kindName == waiter.kind }) {
                waiter.continuation.resume(returning: catalogID)
                kindWaiters.remove(at: index)
            }
        }
    }

    // MARK: Plugin → host requests

    /// `ProposeAction` — a plugin proposing that the user create an instance
    /// of one of its own kinds. Rejected unless the kind is one this very
    /// catalog declared: a plugin may only propose its own capabilities,
    /// never another's.
    private func proposeAction(_ request: KTPPActionCreateRequest) async -> KTPPActionCreateResult {
        let catalogID = await catalogue.catalogID(forPluginName: request.pluginName)
        func reply(_ status: String, actionID: UUID? = nil, message: String? = nil) -> KTPPActionCreateResult {
            KTPPActionCreateResult(
                status: status, actionID: actionID?.uuidString.lowercased(), message: message)
        }
        guard let handler = actionProposalHandler else {
            return reply("unsupported", message: "host does not accept action proposals")
        }
        guard let state = catalogs[catalogID], state.connection != nil else {
            return reply("declined", message: "\(request.pluginName) is not connected")
        }
        guard state.kinds?.kinds.contains(where: { $0.kindName == request.kindName }) == true else {
            return reply("declined", message: "kind '\(request.kindName)' is not yours to propose")
        }

        let proposal = KeepTalkingPluginActionProposal(
            catalogID: catalogID,
            catalogName: state.info.name,
            kindName: request.kindName,
            suggestedName: request.suggestedName ?? request.kindName.beautifulName,
            reason: request.reason,
            suggestedScope: request.suggestedScope
        )
        log("action proposal from \(state.info.name): \(request.kindName)")
        if let actionID = await handler(proposal) {
            return reply("created", actionID: actionID)
        }
        return reply("declined", message: "user declined")
    }

    /// `OpenAddAction` — the plugin (usually the Companion) asks the host to
    /// open its Add Action flow, optionally pre-scoped to a kind.
    private func openAddAction(_ request: KTPPUIAddActionRequest) async {
        await addActionUIHandler?(request.kindName, request.pluginName)
    }

    /// A refused ACT turn: a gRPC status for the plugin's control flow, with
    /// KTPP's own code in the `ktpp-code` trailer for its error type.
    private static func actRefusal(_ code: String, _ message: String) -> RPCError {
        let status: RPCError.Code =
            switch code {
                case "act_unbound": .failedPrecondition
                case "act_denied": .permissionDenied
                case "act_unavailable": .unavailable
                case "act_budget_exhausted": .resourceExhausted
                default: .internalError
            }
        return RPCError(code: status, message: message, metadata: ["ktpp-code": .string(code)])
    }

    /// `RequestAct` — one bounded AI turn for a plugin currently servicing a
    /// call. The actor gates everything the design demands (§4.2/§4.5 of the
    /// resources doc): binding to a live call (its `requestID` names the call
    /// and so the catalog), per-catalog user consent, the per-call budget, and
    /// attachment
    /// resolution against the bound call's own manifest — then delegates the
    /// model turn to the injected handler.
    private func act(_ request: KTPPActRequest) async throws -> KTPPActResult {
        guard let call = activeCalls[request.requestID] else {
            throw Self.actRefusal("act_unbound", "no in-flight call \(request.requestID)")
        }
        let catalogID = call.catalogID
        guard call.actPermitted else {
            throw Self.actRefusal(
                "act_denied", "this kind/instance does not carry the 'act' capability")
        }
        guard await catalogue.allowsACT(catalogID) else {
            throw Self.actRefusal(
                "act_denied", "the user has not allowed this plugin to use the AI provider")
        }
        guard let handler = actHandler else {
            throw Self.actRefusal("act_unavailable", "host has no ACT handler configured")
        }
        // Re-read across the consent await: actor reentrancy means the call may
        // have finished while we were suspended. That is NOT a budget problem,
        // and reporting it as one sent plugin authors chasing a limit they had
        // not reached.
        guard var updated = activeCalls[request.requestID] else {
            throw Self.actRefusal(
                "act_unbound", "call \(request.requestID) ended before its ACT turn could start")
        }
        guard updated.actRequests < Self.maxActRequestsPerCall else {
            throw Self.actRefusal(
                "act_budget_exhausted",
                "per-call ACT budget (\(Self.maxActRequestsPerCall)) exhausted")
        }
        // Attachments resolve ONLY against the bound call's manifest, read
        // direction, path-backed — a plugin can have the model read what it
        // was handed, nothing else. Write slots are excluded on purpose: an
        // output the plugin is meant to PRODUCE is not something it was handed
        // to read, and admitting it widened the boundary this guard states.
        var attachments: [KTPPActAttachment] = []
        for handle in request.attachments ?? [] {
            guard let resource = call.resourcesByHandle[handle],
                resource.direction == .read,
                let path = resource.path
            else {
                throw Self.actRefusal(
                    "act_denied", "attachment \(handle) is not provisioned for this call")
            }
            attachments.append(
                KTPPActAttachment(handle: handle, name: resource.name, path: path))
        }

        // Charge the attempt before running — a failing turn still spent.
        updated.actRequests += 1
        activeCalls[request.requestID] = updated

        let context = KTPPActCallContext(
            invocationID: request.requestID,
            catalogID: catalogID,
            catalogName: call.catalogName,
            kindName: call.kindName,
            instanceID: call.instanceID,
            contextID: call.contextID,
            callerNodeID: call.callerNodeID)
        let turn = KTPPActTurnRequest(
            task: request.task,
            system: request.system,
            expects: request.expects,
            maxOutputTokens: min(
                request.maxOutputTokens ?? Self.defaultActMaxOutputTokens,
                Self.defaultActMaxOutputTokens),
            attachments: attachments)

        log(
            "act turn for \(call.catalogName)/\(call.kindName) "
                + "(\(request.requestID.prefix(8)), \(updated.actRequests)/\(Self.maxActRequestsPerCall))"
        )
        // Automatic tracing, recorded BEFORE the turn runs: a note appended
        // after the await can land once the call's ActiveCall entry is already
        // gone — dropping it precisely when the turn ran long, which is when
        // the trace matters most. The call is provably still bound here: we
        // just charged it.
        recordElucidation(
            invocationID: request.requestID,
            message: "AI turn: \(request.task)",
            detail: nil)
        let result: KTPPActResult
        do {
            result = try await handler(turn, context)
        } catch {
            throw Self.actRefusal("act_failed", error.localizedDescription)
        }
        if var state = activeCalls[request.requestID] {
            if let usage = result.usage {
                state.actInputTokens += usage.inputTokens ?? 0
                state.actOutputTokens += usage.outputTokens ?? 0
                state.sawTokenCounts =
                    state.sawTokenCounts || usage.inputTokens != nil
                    || usage.outputTokens != nil
            }
            activeCalls[request.requestID] = state
        }
        // The turn's own text goes back to the plugin as the RPC's answer;
        // forward it to a live trace callback as detail on the note already
        // logged above, rather than as a second entry that would double-count
        // against the elucidation cap.
        activeCalls[request.requestID]?.onElucidation?(
            "AI turn: \(request.task)",
            String(result.text.prefix(Self.elucidationDetailCap)))
        return result
    }

    /// `Elucidation` — fire-and-forget narration for an in-flight call.
    /// Capped and truncated, never answered, never an error.
    private func handleElucidation(_ note: KTPPActElucidation, catalogID: UUID) {
        guard activeCalls[note.requestID]?.catalogID == catalogID else { return }
        recordElucidation(
            invocationID: note.requestID, message: note.message, detail: note.detail)
    }

    /// Appends a note to the bound call's elucidation log (capped/truncated)
    /// and forwards it to the live callback when one is attached.
    private func recordElucidation(invocationID: String, message: String, detail: String?) {
        guard var state = activeCalls[invocationID] else { return }
        guard state.elucidations.count < Self.maxElucidationsPerCall else {
            if !state.elucidationsDropped {
                state.elucidationsDropped = true
                activeCalls[invocationID] = state
                log("elucidation cap reached for \(invocationID.prefix(8)); dropping the rest")
            }
            return
        }
        let cappedMessage = String(message.prefix(Self.elucidationMessageCap))
        let cappedDetail = detail.map { String($0.prefix(Self.elucidationDetailCap)) }
        state.elucidations.append(cappedMessage)
        activeCalls[invocationID] = state
        state.onElucidation?(cappedMessage, cappedDetail)
    }
}

// MARK: - Serving PluginHost

extension KeepTalkingPluginHost: KTPPWireHostHandler {
    /// One plugin's connection. Two tasks share it: the writer drains the
    /// connection's outbox onto the stream (Welcome first), and the reader
    /// takes the plugin's Hello and handles what follows. Whichever ends first
    /// ends the connection — the plugin hanging up or dying ends the reader;
    /// the host replacing or stopping it ends the writer.
    public nonisolated func connect(
        inbound: RPCAsyncSequence<KTPPWire.PluginMessage, any Error>,
        outbound: RPCWriter<KTPPWire.HostMessage>,
        context: ServerContext
    ) async throws {
        let (queued, outbox) = AsyncStream.makeStream(of: KTPPWire.HostMessage.self)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await message in queued {
                    try await outbound.write(message)
                }
            }
            group.addTask {
                var messages = inbound.makeAsyncIterator()
                guard let first = try await messages.next(), case .hello(let hello) = first.body else {
                    throw RPCError(code: .invalidArgument, message: "a connection opens with hello")
                }
                guard hello.protocolVersion == KTPPWire.protocolVersion else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message:
                            "KTPP v\(hello.protocolVersion) is not supported; this host speaks v\(KTPPWire.protocolVersion)"
                    )
                }
                let attached = await self.attach(hello, outbox: outbox)
                do {
                    while let message = try await messages.next() {
                        let keepGoing = await self.receive(
                            message, catalogID: attached.catalogID, connection: attached.token)
                        if !keepGoing { break }
                    }
                } catch {
                    await self.detach(catalogID: attached.catalogID, token: attached.token)
                    throw error
                }
                await self.detach(catalogID: attached.catalogID, token: attached.token)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    public nonisolated func requestAct(
        _ request: KTPPActRequest, context: ServerContext
    ) async throws -> KTPPActResult {
        try await act(request)
    }

    public nonisolated func proposeAction(
        _ request: KTPPActionCreateRequest, context: ServerContext
    ) async throws -> KTPPActionCreateResult {
        await proposeAction(request)
    }

    public nonisolated func openAddAction(
        _ request: KTPPUIAddActionRequest, context: ServerContext
    ) async throws -> KTPPWire.Empty {
        await openAddAction(request)
        return KTPPWire.Empty()
    }
}

extension KTPPWire.PluginMessage.Body {
    /// For error messages: what kind of answer arrived instead.
    fileprivate var label: String {
        switch self {
            case .hello: "hello"
            case .kinds: "kinds"
            case .callResult: "a call result"
            case .elucidation: "an elucidation"
            case .scopeOptions: "scope options"
            case .resourceRead: "resource contents"
            case .reveal: "a reveal result"
            case .failure(let failure): "a failure (\(failure.message))"
            case .goodbye: "goodbye"
            case .unknown: "an unknown message"
        }
    }
}

#endif
