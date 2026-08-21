//
//  PluginHost.swift
//  KeepTalking
//
//  KTPP v1 host — an optionally-enabled actor serving the plugin attach socket
//  directly on SwiftNIO. Desktop platforms only; nothing listens until `start()`.
//  Companions dial the Unix socket, speak first (`plugin.hello`), pair once
//  (Ed25519, TOFU), register action kinds, and serve calls that return signed
//  usage receipts. See DESIGN_PLUGIN_ACTIONS.md §4–§6.
//

#if os(macOS) || os(Linux)

import Crypto
import Foundation
import MCP
import NIOCore
import NIOPosix

// MARK: - Public surface types

public struct KTPPCatalogSummary: Sendable {
    public let catalogID: UUID
    public let info: KTPPPluginInfo
    public let identityPublicKey: String
    public let fingerprint: String
    public let role: String?
    public let endorsedBy: UUID?
    public let kinds: KTPPKindsResult?
    public let connected: Bool
}

public enum KTPPReceiptStatus: Sendable, Equatable {
    case valid
    case missing
    case invalid(reason: String)
}

/// Host-observed AI spend a call incurred through `host.act.request` — the
/// host's own metered cost on the plugin's behalf, recorded OUTSIDE the
/// dual-signed authorization/receipt pair (the plugin attests nothing about
/// it). Token counts ride along when the connector surfaces them.
public struct KTPPHostActUsage: Sendable, Equatable {
    public var requests: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
}

public struct KTPPCallRecord: Sendable {
    public let invocationID: String
    public let catalogID: UUID
    public let kindName: String
    public let authorization: Value
    public let authorizationHash: String
    public let receipt: Value?
    public let receiptStatus: KTPPReceiptStatus
    public let hostActUsage: KTPPHostActUsage?
}

public struct KTPPCallOutcome: Sendable {
    public let content: Value
    public let isError: Bool
    public let receiptStatus: KTPPReceiptStatus
    public let usage: [(meter: String, units: Int)]
    /// Explanatory notes the plugin pushed during the call
    /// (`host.act.elucidate`), in arrival order — display/summarization data,
    /// deliberately outside `resultHash`.
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

public struct KTPPLedgerReport: Sendable {
    public let recordCount: Int
    public let issues: [String]
    public var isSound: Bool { issues.isEmpty }
}

public enum KTPPHostEvent: Sendable {
    case listening(socketPath: String)
    case paired(catalogID: UUID, info: KTPPPluginInfo, fingerprint: String, endorsedBy: UUID?)
    case kindsRegistered(catalogID: UUID, kinds: KTPPKindsResult)
    case sessionClosed(catalogID: UUID)
    case log(String)
}

public enum KTPPHostError: LocalizedError {
    case notStarted
    case unknownCatalog(UUID)
    case unknownKind(String)
    case sessionUnavailable(UUID)
    case handshakeFailure(String)
    case timeout(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
            case .notStarted: return "Plugin host is not started."
            case .unknownCatalog(let id): return "Unknown plugin catalog \(id.uuidString.lowercased())."
            case .unknownKind(let name): return "No connected catalog registers kind '\(name)'."
            case .sessionUnavailable(let id): return "Plugin catalog \(id.uuidString.lowercased()) is not connected."
            case .handshakeFailure(let reason): return "KTPP handshake failed: \(reason)"
            case .timeout(let what): return "KTPP timeout waiting for \(what)."
            case .protocolViolation(let reason): return "KTPP protocol violation: \(reason)"
        }
    }
}

// MARK: - Host actor

public actor KeepTalkingPluginHost {
    private struct CatalogState {
        var info: KTPPPluginInfo
        var identityPublicKey: String
        var role: String?
        var endorsedBy: UUID?
        var kinds: KTPPKindsResult?
        var writer: KTPPFrameWriter?
        /// Identity of the connection currently holding `writer` — a
        /// superseded connection's teardown must not clear its successor.
        var sessionToken: UUID?
        var pluginSequenceHighWater: Int = -1
    }

    private let hostNodeID: UUID
    private let identityKey: Curve25519.Signing.PrivateKey
    private let socketPath: String
    public let hostIdentityPublicKey: String

    /// The Catalogue — persisted kinds, queried by the app's action-creation UI.
    public let catalogue: KeepTalkingPluginCatalogueStore

    private var group: MultiThreadedEventLoopGroup?
    private var acceptTask: Task<Void, Never>?
    private var catalogs: [UUID: CatalogState] = [:]
    private var pending: [String: CheckedContinuation<KTPPFrame, Error>] = [:]
    private var kindWaiters: [(kind: String, continuation: CheckedContinuation<UUID, Error>)] = []

    private var callSequence: Int = 0
    private var lastRecordHash: String?
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

    private var approvePairing: @Sendable (KTPPPluginInfo, String) async -> Bool = { _, _ in false }
    private var eventHandler: (@Sendable (KTPPHostEvent) -> Void)?

    /// True when the signing identity could not be persisted and is therefore
    /// good for this launch only. Surfaced loudly at `start()`: silently
    /// carrying on reintroduces the pairing breakage `persistentIdentityKey`
    /// exists to prevent, and the only symptom is plugins rejecting live calls.
    private var identityKeyIsEphemeral = false

    public init(
        hostNodeID: UUID,
        socketPath: String,
        identityKey: Curve25519.Signing.PrivateKey = .init(),
        identityKeyIsEphemeral: Bool = false,
        catalogue: KeepTalkingPluginCatalogueStore? = nil
    ) {
        self.hostNodeID = hostNodeID
        self.socketPath = socketPath
        self.identityKey = identityKey
        self.identityKeyIsEphemeral = identityKeyIsEphemeral
        self.hostIdentityPublicKey = identityKey.publicKey.rawRepresentation.base64EncodedString()
        self.catalogue =
            catalogue
            ?? KeepTalkingPluginCatalogueStore(
                fileURL: KeepTalkingPluginCatalogueStore.defaultFileURL())
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

    /// Every `KeepTalkingClient` on a node shares ONE host: sessions live on
    /// the instance that accepted them, so a per-client host would leave the
    /// client dispatching a call unable to see the plugin that can serve it.
    private static let sharedHostsLock = NSLock()
    nonisolated(unsafe) private static var sharedHosts: [UUID: KeepTalkingPluginHost] = [:]

    public static func shared(forNode nodeID: UUID) -> KeepTalkingPluginHost {
        sharedHostsLock.lock()
        defer { sharedHostsLock.unlock() }
        if let existing = sharedHosts[nodeID] { return existing }
        let identity = persistentIdentityKey(forNode: nodeID)
        let host = KeepTalkingPluginHost(
            hostNodeID: nodeID,
            socketPath: socketPath(forNode: nodeID),
            identityKey: identity.key,
            identityKeyIsEphemeral: !identity.persisted)
        sharedHosts[nodeID] = host
        return host
    }

    /// The host's signing identity, persisted beside the socket. A per-launch
    /// random key (the old default) broke every resumed pairing: plugins pin
    /// the host key at pairing time and verify every CallAuthorization against
    /// it, so the first relaunch after pairing continuity landed produced
    /// "authorization signature invalid" on live calls. Flat file 0600 — the
    /// same storage answer the plugin SDKs use (design doc §12.5).
    static func persistentIdentityKey(
        forNode nodeID: UUID
    ) -> (key: Curve25519.Signing.PrivateKey, persisted: Bool) {
        let short = nodeID.uuidString
            .replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let url = socketDirectory().appending(path: "ktpp-host-\(short).key")
        if let data = try? Data(contentsOf: url),
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        {
            return (key, true)
        }
        let key = Curve25519.Signing.PrivateKey()
        try? FileManager.default.createDirectory(
            at: socketDirectory(), withIntermediateDirectories: true)
        // `createFile` applies the mode as it creates the file, so the private
        // key is never briefly world-readable the way write-then-chmod left it
        // under a default umask. A failure here is REPORTED, not swallowed:
        // returning an unpersisted key silently is what breaks every resumed
        // pairing on the next launch.
        let persisted = FileManager.default.createFile(
            atPath: url.path,
            contents: key.rawRepresentation,
            attributes: [.posixPermissions: 0o600])
        return (key, persisted)
    }

    public func setPairingApprovalHandler(
        _ handler: @escaping @Sendable (KTPPPluginInfo, String) async -> Bool
    ) {
        approvePairing = handler
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
        guard acceptTask == nil else { return }
        if identityKeyIsEphemeral {
            log(
                "WARNING: host identity key could not be persisted to "
                    + "\(Self.socketDirectory().path) — this launch signs with a "
                    + "throwaway key, so plugins that pinned the previous key will "
                    + "reject calls with 'authorization signature invalid'. Fix the "
                    + "directory's permissions and relaunch."
            )
        }
        await rehydratePersistedCatalogs()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: socketDirectory, withIntermediateDirectories: true)

        let server = try await ServerBootstrap(group: group)
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }

        // Reachability gate: same-user only. Identity still comes from pairing.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: socketPath)
        writeDiscoveryFile()

        emit(.listening(socketPath: socketPath))

        acceptTask = Task { [weak self] in
            do {
                try await server.executeThenClose { inbound in
                    for try await connection in inbound {
                        guard let self else { return }
                        Task { await self.runSession(connection) }
                    }
                }
            } catch {
                await self?.log("accept loop ended: \(error.localizedDescription)")
            }
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: KTPPHostError.notStarted)
        }
        pending.removeAll()
        try? await group?.shutdownGracefully()
        group = nil
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
                identityPublicKey: state.identityPublicKey,
                fingerprint: KTPPCrypto.fingerprint(publicKeyB64: state.identityPublicKey),
                role: state.role,
                endorsedBy: state.endorsedBy,
                kinds: state.kinds,
                connected: state.writer != nil
            )
        }
    }

    public func callRecords() -> [KTPPCallRecord] { records }

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
            state.writer != nil && state.kinds?.kinds.contains { $0.kindName == kindName } == true
        }?.key
    }

    // MARK: Calling

    /// Executes one call against a paired catalog's kind: builds + signs the
    /// CallAuthorization, sends `plugin.call.request`, verifies the returned
    /// signed UsageReceipt, and appends the record pair to the in-memory ledger.
    ///
    /// `manifest` is the run's staged resource manifest; it projects into the
    /// frame's `resources` block (handles + resolved paths, §3.1 of the
    /// resources design doc) and is bound into the signed authorization as
    /// `resourcesHash`. No file bytes cross the socket — the plugin SDK reads/
    /// writes the paths directly and hides them from handler code.
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
        guard state.writer != nil else { throw KTPPHostError.sessionUnavailable(catalogID) }
        guard state.kinds?.kinds.contains(where: { $0.kindName == kindName }) == true else {
            throw KTPPHostError.unknownKind(kindName)
        }

        let invocationID = UUID.v7().uuidString.lowercased()
        let scopeValue = instanceScope ?? .null
        let instanceScopeHash = try KTPPCanonicalJSON.sha256Hex(scopeValue)
        let argumentsValue = Value.object(arguments)
        let argumentsHash = try KTPPCanonicalJSON.sha256Hex(argumentsValue)
        let resources = KTPPResources(manifest: manifest)
        callSequence += 1

        // The binding anchor for reverse-direction host.act.* frames: created
        // BEFORE the call frame goes out, torn down (below, defer) when the
        // response or timeout lands. Actor reentrancy lets handleActRequest /
        // handleElucidation mutate this entry while we await the response.
        activeCalls[invocationID] = ActiveCallState(
            catalogID: catalogID,
            catalogName: state.info.name,
            kindName: kindName,
            instanceID: instanceID,
            contextID: contextID,
            callerNodeID: callerNodeID ?? hostNodeID,
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

        var authFields: [String: Value] = [
            "domain": .string(KTPPConstants.callDomain),
            "alg": .string(KTPPConstants.signatureAlgorithm),
            "invocationID": .string(invocationID),
            "catalogID": .string(catalogID.uuidString.lowercased()),
            "actionID": .string(instanceID.uuidString.lowercased()),
            "kindName": .string(kindName),
            "instanceScopeHash": .string(instanceScopeHash),
            "argumentsHash": .string(argumentsHash),
            "callerNodeID": .string((callerNodeID ?? hostNodeID).uuidString.lowercased()),
            "hostNodeID": .string(hostNodeID.uuidString.lowercased()),
            "contextID": .string(contextID.uuidString.lowercased()),
            "sequence": .int(callSequence),
            "issuedAtMS": .int(Int(Date.now.timeIntervalSince1970 * 1000)),
        ]
        if let tool { authFields["tool"] = .string(tool) }
        if let resources {
            // Bind the exact resource block offered — the plugin SDK verifies
            // this against the payload's `resources` before its handler runs,
            // extending the dual-signed contract to file provisioning.
            authFields["resourcesHash"] = .string(
                try KTPPCanonicalJSON.sha256Hex(try .wrap(resources)))
        }
        if let lastRecordHash { authFields["previousRecordHash"] = .string(lastRecordHash) }
        let authorization = try KTPPCrypto.attachSignature(
            to: .object(authFields), with: identityKey)
        let authorizationHash = try KTPPCanonicalJSON.sha256Hex(authorization)

        let callPayload = KTPPCallRequest(
            requestID: invocationID,
            contextID: contextID.uuidString.lowercased(),
            callerNodeID: (callerNodeID ?? hostNodeID).uuidString.lowercased(),
            kindName: kindName,
            tool: tool,
            arguments: argumentsValue,
            instance: KTPPInstanceRef(
                id: instanceID.uuidString.lowercased(),
                scope: instanceScope,
                scopeHash: instanceScopeHash
            ),
            resources: resources,
            authorization: authorization,
            grant: nil
        )

        let frame = KTPPFrame.request(KTPPFrameKind.callRequest, payload: try .wrap(callPayload))
        let response = try await request(catalogID: catalogID, frame: frame, timeout: timeout)
        guard response.kind != KTPPFrameKind.error else {
            throw KTPPHostError.protocolViolation(describeError(response))
        }
        let result = try (response.payload ?? .null).decode(KTPPCallResult.self)

        let (receiptStatus, usage) = validateReceipt(
            result: result,
            invocationID: invocationID,
            authorizationHash: authorizationHash,
            catalogState: state
        )
        if case .int(let sequence)? = receiptFields(result.receipt)?["sequence"],
            var updated = catalogs[catalogID]
        {
            updated.pluginSequenceHighWater = max(updated.pluginSequenceHighWater, sequence)
            catalogs[catalogID] = updated
        }

        // Fold what the reverse direction accumulated during the call — the
        // ACT spend into the record (host-observed, outside the signed pair),
        // the elucidation log into the outcome for the caller's backfeed.
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
            authorizationHash: authorizationHash,
            receipt: result.receipt,
            receiptStatus: receiptStatus,
            hostActUsage: hostActUsage
        )
        records.append(record)
        lastRecordHash = authorizationHash

        return KTPPCallOutcome(
            content: result.content,
            isError: result.isError,
            receiptStatus: receiptStatus,
            usage: usage,
            elucidations: activeState?.elucidations ?? [],
            record: record
        )
    }

    private func receiptFields(_ receipt: Value?) -> [String: Value]? {
        if case .object(let fields)? = receipt { return fields }
        return nil
    }

    private func validateReceipt(
        result: KTPPCallResult,
        invocationID: String,
        authorizationHash: String,
        catalogState: CatalogState
    ) -> (KTPPReceiptStatus, [(String, Int)]) {
        guard let receipt = result.receipt, let fields = receiptFields(receipt) else {
            return (.missing, [])
        }
        do {
            guard
                try KTPPCrypto.verifySignedObject(
                    receipt, publicKeyB64: catalogState.identityPublicKey)
            else {
                return (.invalid(reason: "bad signature"), [])
            }
            guard case .string(let domain)? = fields["domain"],
                domain == KTPPConstants.receiptDomain
            else { return (.invalid(reason: "wrong domain"), []) }
            guard case .string(let receiptInvocation)? = fields["invocationID"],
                receiptInvocation == invocationID
            else { return (.invalid(reason: "invocation mismatch"), []) }
            guard case .string(let boundAuthHash)? = fields["authorizationHash"],
                boundAuthHash == authorizationHash
            else { return (.invalid(reason: "authorization hash mismatch"), []) }
            let computedResultHash = try KTPPCanonicalJSON.sha256Hex(result.content)
            guard case .string(let resultHash)? = fields["resultHash"],
                resultHash == computedResultHash
            else { return (.invalid(reason: "result hash mismatch"), []) }

            var usage: [(String, Int)] = []
            if case .array(let entries)? = fields["usage"] {
                for entry in entries {
                    if case .object(let e) = entry,
                        case .string(let meter)? = e["meter"],
                        case .int(let units)? = e["units"]
                    {
                        usage.append((meter, units))
                    }
                }
            }
            return (.valid, usage)
        } catch {
            return (.invalid(reason: error.localizedDescription), [])
        }
    }

    /// Re-verifies the whole in-memory ledger: authorization + receipt signatures
    /// and hash-chain continuity.
    public func verifyLedger() -> KTPPLedgerReport {
        var issues: [String] = []
        var previousHash: String?
        for (index, record) in records.enumerated() {
            let tag = "record[\(index)] \(record.invocationID.prefix(8))"
            if (try? KTPPCrypto.verifySignedObject(
                record.authorization, publicKeyB64: hostIdentityPublicKey)) != true
            {
                issues.append("\(tag): authorization signature invalid")
            }
            if case .object(let fields) = record.authorization {
                switch (fields["previousRecordHash"], previousHash) {
                    case (nil, nil): break
                    case (.string(let linked)?, .some(let expected)) where linked == expected: break
                    default: issues.append("\(tag): chain link mismatch")
                }
            }
            if case .invalid(let reason) = record.receiptStatus {
                issues.append("\(tag): receipt invalid (\(reason))")
            }
            previousHash = record.authorizationHash
        }
        return KTPPLedgerReport(recordCount: records.count, issues: issues)
    }

    // MARK: Request/response plumbing

    private func request(
        catalogID: UUID, frame: KTPPFrame, timeout: TimeInterval
    ) async throws -> KTPPFrame {
        guard let writer = catalogs[catalogID]?.writer else {
            throw KTPPHostError.sessionUnavailable(catalogID)
        }
        guard let frameID = frame.id else {
            throw KTPPHostError.protocolViolation("request frame without id")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[frameID] = continuation
            Task { [weak self] in
                do {
                    try await writer.send(frame)
                } catch {
                    await self?.failPending(frameID, error: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.failPending(frameID, error: KTPPHostError.timeout("response to \(frame.kind)"))
            }
        }
    }

    private func failPending(_ frameID: String, error: Error) {
        if let continuation = pending.removeValue(forKey: frameID) {
            continuation.resume(throwing: error)
        }
    }

    private func resolvePending(_ frame: KTPPFrame) {
        guard let re = frame.re, let continuation = pending.removeValue(forKey: re) else { return }
        continuation.resume(returning: frame)
    }

    private func describeError(_ frame: KTPPFrame) -> String {
        if case .object(let fields)? = frame.payload,
            case .string(let message)? = fields["message"]
        {
            return message
        }
        return "unspecified plugin error"
    }

    // MARK: Session state transitions (called from session tasks)

    private var rehydrated = false

    /// Loads persisted pairings into the actor so identities survive app
    /// relaunches. Without this, every restart forgot every pairing: each
    /// reconnecting plugin re-paired under a fresh catalog id, orphaning every
    /// instance minted against the old one and multiplying catalogue rows
    /// (observed live: ~50 duplicates per plugin). Rehydrated catalogs carry
    /// their stored kind declarations so saved instances resolve; nothing is
    /// OFFERED until a session attaches — the Catalogue-is-live rule holds.
    private func rehydratePersistedCatalogs() async {
        guard !rehydrated else { return }
        rehydrated = true
        for entry in await catalogue.catalogues() where catalogs[entry.catalogID] == nil {
            catalogs[entry.catalogID] = CatalogState(
                info: KTPPPluginInfo(
                    name: entry.name, vendor: entry.vendor, version: entry.version),
                identityPublicKey: entry.identityPublicKey,
                role: entry.role,
                endorsedBy: entry.endorsedBy,
                kinds: entry.kinds.isEmpty
                    ? nil
                    : KTPPKindsResult(
                        manifestVersion: entry.manifestVersion ?? "",
                        manifestHash: "",
                        kinds: entry.kinds,
                        meters: entry.meters.isEmpty ? nil : entry.meters,
                        priceSheet: nil))
        }
        log("rehydrated \(catalogs.count) persisted catalog(s)")
    }

    private enum HelloDisposition {
        case resume(catalogID: UUID, storedKey: String)
        case pair(newCatalogID: UUID)
        case reject(String)
    }

    private func evaluateHello(
        publicKey: String, claimedCatalogID: UUID?, pluginName: String
    ) async -> HelloDisposition {
        if let claimed = claimedCatalogID {
            // A claimed id that was deduped away resolves to its canonical row.
            let canonical = await catalogue.canonicalCatalogID(claimed)
            if let known = catalogs[canonical] {
                if known.identityPublicKey == publicKey {
                    return .resume(catalogID: canonical, storedKey: known.identityPublicKey)
                }
                return .reject(
                    "identity key mismatch for catalog \(claimed.uuidString.lowercased())")
            }
            // Unknown claimed id, but a known IDENTITY resumes its canonical
            // catalog: the Ed25519 key is the plugin's identity — catalog ids
            // are host bookkeeping a plugin can hold stale after the host has
            // deduped or migrated. (Claimed-nil connections still pair: a
            // plugin without a stored pairing has no host key pinned and
            // cannot answer a resume challenge.)
            if let byKey = await catalogue.catalogID(
                identityPublicKey: publicKey, name: pluginName),
                let known = catalogs[byKey], known.identityPublicKey == publicKey
            {
                return .resume(catalogID: byKey, storedKey: known.identityPublicKey)
            }
        }
        return .pair(newCatalogID: UUID.v7())
    }

    private func requestPairingApproval(info: KTPPPluginInfo, publicKey: String) async -> Bool {
        await approvePairing(info, KTPPCrypto.fingerprint(publicKeyB64: publicKey))
    }

    /// Validates a companion-signed endorsement of a plugin identity. Returns
    /// the endorser catalog id when the endorsement is trustworthy: the
    /// endorser must be an already-paired catalog with the companion role, the
    /// endorsement's keys must match both the endorser's stored key and the
    /// connecting plugin's hello identity, and the signature must verify.
    private func validateEndorsement(
        _ endorsement: Value, pluginPublicKey: String, pluginName: String
    ) -> UUID? {
        guard case .object(let fields) = endorsement,
            case .string(let domain)? = fields["domain"],
            domain == KTPPConstants.endorseDomain,
            case .string(let endorserCatalogRaw)? = fields["endorserCatalogID"],
            let endorserCatalogID = UUID(uuidString: endorserCatalogRaw.uppercased()),
            case .string(let endorserKey)? = fields["endorserPublicKey"],
            case .string(let endorsedKey)? = fields["pluginPublicKey"],
            case .string(let endorsedName)? = fields["pluginName"]
        else { return nil }
        guard let endorser = catalogs[endorserCatalogID],
            endorser.role == KTPPConstants.companionRole,
            endorser.identityPublicKey == endorserKey,
            endorsedKey == pluginPublicKey,
            endorsedName == pluginName
        else { return nil }
        guard (try? KTPPCrypto.verifySignedObject(endorsement, publicKeyB64: endorserKey)) == true
        else { return nil }
        return endorserCatalogID
    }

    private func commitPairing(
        catalogID: UUID, info: KTPPPluginInfo, publicKey: String,
        role: String?, endorsedBy: UUID?
    ) {
        catalogs[catalogID] = CatalogState(
            info: info, identityPublicKey: publicKey, role: role, endorsedBy: endorsedBy)
        let store = catalogue
        Task {
            await store.upsertCatalog(
                catalogID: catalogID, info: info, identityPublicKey: publicKey,
                role: role, endorsedBy: endorsedBy)
        }
        emit(
            .paired(
                catalogID: catalogID, info: info,
                fingerprint: KTPPCrypto.fingerprint(publicKeyB64: publicKey),
                endorsedBy: endorsedBy))
    }

    /// Attaches a connection as the catalog's CURRENT session and returns its
    /// token. Sessions need identity: two connections for one catalog overlap
    /// routinely (a child restart hands over before the old socket dies, and a
    /// misconfigured runtime can double-spawn) — and an un-tokened detach from
    /// the OLD connection was deregistering the SURVIVOR, flipping the catalog
    /// to "not connected" while a healthy session sat right there. Observed
    /// live as the Add-action sheet's "Nothing connected yet" with both
    /// plugins connected.
    private func attachSession(catalogID: UUID, writer: KTPPFrameWriter) -> UUID {
        let token = UUID()
        catalogs[catalogID]?.writer = writer
        catalogs[catalogID]?.sessionToken = token
        let store = catalogue
        Task { await store.setConnected(true, catalogID: catalogID) }
        return token
    }

    /// Clears the catalog's session ONLY when the ending connection still IS
    /// the current session — a superseded connection's teardown is a no-op.
    private func detachSession(catalogID: UUID, token: UUID) {
        guard catalogs[catalogID]?.sessionToken == token else { return }
        catalogs[catalogID]?.writer = nil
        catalogs[catalogID]?.sessionToken = nil
        let store = catalogue
        Task { await store.setConnected(false, catalogID: catalogID) }
        emit(.sessionClosed(catalogID: catalogID))
    }

    private func storeKinds(catalogID: UUID, kinds: KTPPKindsResult) {
        catalogs[catalogID]?.kinds = kinds
        let store = catalogue
        Task { await store.registerKinds(catalogID: catalogID, result: kinds) }
        emit(.kindsRegistered(catalogID: catalogID, kinds: kinds))
        for (index, waiter) in kindWaiters.enumerated().reversed() {
            if kinds.kinds.contains(where: { $0.kindName == waiter.kind }) {
                waiter.continuation.resume(returning: catalogID)
                kindWaiters.remove(at: index)
            }
        }
    }

    /// `host.action.create` — a plugin proposing that the user create an
    /// instance of one of its own kinds. Rejected unless the kind is one this
    /// very catalog declared: a plugin may only propose its own capabilities,
    /// never another's.
    private func handleActionCreate(_ frame: KTPPFrame, catalogID: UUID) async -> KTPPFrame {
        func reply(_ status: String, actionID: UUID? = nil, message: String? = nil) -> KTPPFrame {
            let payload = KTPPActionCreateResult(
                status: status,
                actionID: actionID?.uuidString.lowercased(),
                message: message
            )
            return KTPPFrame.response(to: frame, payload: try? .wrap(payload))
        }

        guard let handler = actionProposalHandler else {
            return reply("unsupported", message: "host does not accept action proposals")
        }
        guard let state = catalogs[catalogID],
            let request = try? (frame.payload ?? .null).decode(KTPPActionCreateRequest.self)
        else {
            return reply("declined", message: "malformed request")
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

    /// `host.act.request` — one bounded AI turn for a plugin currently
    /// servicing a call. The actor gates everything the design demands
    /// (§4.2/§4.5 of the resources doc): binding to a live call on THIS
    /// catalog's session, per-catalog user consent, the per-call budget, and
    /// attachment resolution against the bound call's own manifest — then
    /// delegates the model turn to the injected handler.
    private func handleActRequest(_ frame: KTPPFrame, catalogID: UUID) async -> KTPPFrame {
        func deny(_ code: String, _ message: String) -> KTPPFrame {
            .errorResponse(to: frame, code: code, message: message)
        }

        guard let request = try? (frame.payload ?? .null).decode(KTPPActRequest.self) else {
            return deny("act_unbound", "malformed act request")
        }
        guard let call = activeCalls[request.requestID], call.catalogID == catalogID else {
            return deny(
                "act_unbound",
                "no in-flight call \(request.requestID) on this catalog's session")
        }
        guard call.actPermitted else {
            return deny(
                "act_denied",
                "this kind/instance does not carry the 'act' capability")
        }
        guard await catalogue.allowsACT(catalogID) else {
            return deny(
                "act_denied",
                "the user has not allowed this plugin to use the AI provider")
        }
        guard let handler = actHandler else {
            return deny("act_unavailable", "host has no ACT handler configured")
        }
        // Re-read across the consent await: actor reentrancy means the call may
        // have finished while we were suspended. That is NOT a budget problem,
        // and reporting it as one sent plugin authors chasing a limit they had
        // not reached.
        guard var updated = activeCalls[request.requestID] else {
            return deny(
                "act_unbound",
                "call \(request.requestID) ended before its ACT turn could start")
        }
        guard updated.actRequests < Self.maxActRequestsPerCall else {
            return deny(
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
                return deny(
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
        // Automatic tracing, recorded BEFORE the turn runs. This handler is
        // answered on its own task, so a note appended after the await can land
        // once the call's ActiveCall entry is already gone — dropping it
        // precisely when the turn ran long, which is when the trace matters
        // most. The call is provably still bound here: we just charged it.
        recordElucidation(
            invocationID: request.requestID,
            message: "AI turn: \(request.task)",
            detail: nil)
        do {
            let result = try await handler(turn, context)
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
            // The turn's own text goes back to the plugin as this frame's
            // response; forward it to a live trace callback as detail on the
            // note already logged above, rather than as a second entry that
            // would double-count against the elucidation cap.
            activeCalls[request.requestID]?.onElucidation?(
                "AI turn: \(request.task)",
                String(result.text.prefix(Self.elucidationDetailCap)))
            return .response(to: frame, payload: try? .wrap(result))
        } catch {
            return deny("act_failed", error.localizedDescription)
        }
    }

    /// `host.act.elucidate` — fire-and-forget narration for an in-flight
    /// call. Capped and truncated, never answered, never an error.
    private func handleElucidation(_ frame: KTPPFrame, catalogID: UUID) {
        guard
            let note = try? (frame.payload ?? .null).decode(KTPPActElucidation.self),
            activeCalls[note.requestID]?.catalogID == catalogID
        else { return }
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

    private func refreshKinds(catalogID: UUID) async {
        do {
            let frame = KTPPFrame.request(KTPPFrameKind.kindsGet, payload: nil)
            let response = try await request(catalogID: catalogID, frame: frame, timeout: 30)
            let kinds = try (response.payload ?? .null).decode(KTPPKindsResult.self)
            storeKinds(catalogID: catalogID, kinds: kinds)
        } catch {
            log("kinds refresh failed for \(catalogID.uuidString.lowercased()): \(error.localizedDescription)")
        }
    }

    // MARK: Per-connection session

    private nonisolated func runSession(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                let writer = KTPPFrameWriter(outbound: outbound)
                var reader = KTPPLineReader(inbound: inbound)
                let catalogID = try await self.handshake(reader: &reader, writer: writer)
                let sessionToken = await self.attachSession(catalogID: catalogID, writer: writer)
                defer {
                    Task { await self.detachSession(catalogID: catalogID, token: sessionToken) }
                }

                // Initial kind registration, then steady-state dispatch.
                try await self.pullKinds(catalogID: catalogID, reader: &reader, writer: writer)
                while let frame = try await reader.next() {
                    if frame.re != nil {
                        await self.resolvePending(frame)
                    } else {
                        await self.handleHostFrame(frame, catalogID: catalogID, writer: writer)
                    }
                }
            }
        } catch {
            await log("session ended: \(error.localizedDescription)")
        }
    }

    /// Routes one steady-state plugin→host frame. Every reverse-direction
    /// operation is declared here in one place — its frame kind, its payload
    /// type, and its execution mode. Request/response kinds answer on their
    /// own task so a user-facing confirmation or a model turn cannot stall the
    /// session loop (the very loop that delivers the call's eventual result);
    /// `host.act.elucidate` is handled INLINE because frame order is the
    /// guarantee that a note sent before the call result is recorded before
    /// the result tears the ActiveCall down.
    private nonisolated func handleHostFrame(
        _ frame: KTPPFrame, catalogID: UUID, writer: KTPPFrameWriter
    ) async {
        switch frame.kind {
            case KTPPFrameKind.kindsChanged:
                Task { await self.refreshKinds(catalogID: catalogID) }
            case KTPPFrameKind.hostActionCreate where frame.id != nil:
                Task {
                    let response = await self.handleActionCreate(frame, catalogID: catalogID)
                    try? await writer.send(response)
                }
            case KTPPFrameKind.hostUIAddAction where frame.id != nil:
                Task {
                    let request = try? (frame.payload ?? .null).decode(KTPPUIAddActionRequest.self)
                    await self.addActionUIHandler?(request?.kindName, request?.pluginName)
                    try? await writer.send(
                        .response(to: frame, payload: .object(["status": .string("ok")])))
                }
            case KTPPFrameKind.hostActRequest where frame.id != nil:
                Task {
                    let response = await self.handleActRequest(frame, catalogID: catalogID)
                    try? await writer.send(response)
                }
            case KTPPFrameKind.hostActElucidate:
                await self.handleElucidation(frame, catalogID: catalogID)
            default:
                if frame.id != nil {
                    try? await writer.send(
                        .errorResponse(
                            to: frame, code: "unsupported",
                            message: "unsupported kind \(frame.kind)"))
                }
        }
    }

    /// Drives hello → (challenge-proof | pair) sequentially on a fresh connection.
    /// Returns the catalog id this session now speaks for.
    private nonisolated func handshake(
        reader: inout KTPPLineReader, writer: KTPPFrameWriter
    ) async throws -> UUID {
        guard let helloFrame = try await reader.next(), helloFrame.kind == KTPPFrameKind.hello else {
            throw KTPPHostError.handshakeFailure("expected plugin.hello as first frame")
        }
        let hello = try (helloFrame.payload ?? .null).decode(KTPPHello.self)
        let claimedCatalogID = hello.catalogID.flatMap(UUID.init(uuidString:))

        switch await evaluateHello(
            publicKey: hello.identityPublicKey,
            claimedCatalogID: claimedCatalogID,
            pluginName: hello.pluginInfo.name)
        {
            case .reject(let reason):
                try await writer.send(.errorResponse(to: helloFrame, code: "rejected", message: reason))
                throw KTPPHostError.handshakeFailure(reason)

            case .resume(let catalogID, let storedKey):
                let nonce = KTPPCrypto.randomNonce()
                try await writer.send(
                    .response(
                        to: helloFrame,
                        payload: try .wrap(KTPPHelloReply(status: "challenge", hostNonce: nonce))))
                guard let proofFrame = try await reader.next(),
                    proofFrame.kind == KTPPFrameKind.helloProof
                else {
                    throw KTPPHostError.handshakeFailure("expected plugin.hello.proof")
                }
                let proof = try (proofFrame.payload ?? .null).decode(KTPPHelloProof.self)
                // The plugin signs over the catalog id IT claimed — which may
                // be a stale alias of the canonical catalog this session will
                // actually resume. Verify its signature over its own claim;
                // the ok reply below hands it the canonical id to adopt.
                let transcript = KTPPCrypto.helloTranscript(
                    hostNonce: nonce,
                    catalogID: hello.catalogID ?? catalogID.uuidString.lowercased(),
                    identityPublicKey: storedKey
                )
                guard let signature = Data(base64Encoded: proof.signature),
                    let keyData = Data(base64Encoded: storedKey),
                    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                    key.isValidSignature(signature, for: try KTPPCanonicalJSON.canonicalData(transcript))
                else {
                    try await writer.send(
                        .errorResponse(
                            to: proofFrame, code: "rejected", message: "hello proof invalid"))
                    throw KTPPHostError.handshakeFailure("hello proof invalid")
                }
                var okFields: [String: Value] = [
                    "status": .string("ok"),
                    "hostNodeID": .string(hostNodeID.uuidString.lowercased()),
                    "catalogID": .string(catalogID.uuidString.lowercased()),
                    "hostIdentityPublicKey": .string(hostIdentityPublicKey),
                ]
                // Prove possession of the current host key over the plugin's
                // nonce so the SDK may re-pin after a legitimate key rotation
                // (trust-on-resume — the same posture as local auto-pairing).
                if let pluginNonce = hello.pluginNonce {
                    let rotation = Value.object([
                        "domain": .string("kt.plugin.hello.host.v1"),
                        "pluginNonce": .string(pluginNonce),
                        "catalogID": .string(catalogID.uuidString.lowercased()),
                        "hostIdentityPublicKey": .string(hostIdentityPublicKey),
                    ])
                    okFields["hostSignature"] = .string(
                        try KTPPCrypto.sign(rotation, with: identityKey))
                }
                try await writer.send(
                    .response(to: proofFrame, payload: .object(okFields)))
                return catalogID

            case .pair(let newCatalogID):
                try await writer.send(
                    .response(
                        to: helloFrame, payload: try .wrap(KTPPHelloReply(status: "pair", hostNonce: nil))))

                let hostNonce = KTPPCrypto.randomNonce()
                let catalogIDString = newCatalogID.uuidString.lowercased()
                let pairFrame = KTPPFrame.request(
                    KTPPFrameKind.pair,
                    payload: try .wrap(
                        KTPPPairRequest(
                            ktppVersion: KTPPConstants.protocolVersion,
                            hostNodeID: hostNodeID.uuidString.lowercased(),
                            hostIdentityPublicKey: hostIdentityPublicKey,
                            catalogID: catalogIDString,
                            hostNonce: hostNonce
                        )))
                try await writer.send(pairFrame)
                guard let pairResponseFrame = try await reader.next(),
                    pairResponseFrame.re == pairFrame.id
                else {
                    throw KTPPHostError.handshakeFailure("expected pair response")
                }
                let pairResponse = try (pairResponseFrame.payload ?? .null).decode(KTPPPairResponse.self)
                guard pairResponse.identityPublicKey == hello.identityPublicKey else {
                    throw KTPPHostError.handshakeFailure("pair identity differs from hello identity")
                }

                let transcript = KTPPCrypto.pairTranscript(
                    hostNodeID: hostNodeID.uuidString.lowercased(),
                    hostIdentityPublicKey: hostIdentityPublicKey,
                    catalogID: catalogIDString,
                    hostNonce: hostNonce,
                    pluginInfo: pairResponse.pluginInfo,
                    pluginIdentityPublicKey: pairResponse.identityPublicKey,
                    pluginNonce: pairResponse.pluginNonce,
                    manifestHash: pairResponse.manifestHash
                )
                let transcriptData = try KTPPCanonicalJSON.canonicalData(transcript)
                guard let signature = Data(base64Encoded: pairResponse.transcriptSignature),
                    let keyData = Data(base64Encoded: pairResponse.identityPublicKey),
                    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                    key.isValidSignature(signature, for: transcriptData)
                else {
                    throw KTPPHostError.handshakeFailure("pair transcript signature invalid")
                }

                // A valid companion endorsement stands in for interactive
                // consent — the user approved the companion once; its plugins
                // pair silently but still get their own catalog identity.
                var endorsedBy: UUID?
                if let endorsement = hello.endorsement {
                    endorsedBy = await validateEndorsement(
                        endorsement,
                        pluginPublicKey: hello.identityPublicKey,
                        pluginName: hello.pluginInfo.name
                    )
                }
                if endorsedBy == nil {
                    guard
                        await requestPairingApproval(
                            info: pairResponse.pluginInfo, publicKey: pairResponse.identityPublicKey)
                    else {
                        throw KTPPHostError.handshakeFailure("pairing declined")
                    }
                }

                let confirmFrame = KTPPFrame.request(
                    KTPPFrameKind.pairConfirm,
                    payload: try .wrap(
                        KTPPPairConfirm(
                            transcriptSignature: try identityKey.signature(for: transcriptData)
                                .base64EncodedString()
                        )))
                try await writer.send(confirmFrame)
                guard let confirmResponse = try await reader.next(),
                    confirmResponse.re == confirmFrame.id,
                    confirmResponse.kind != KTPPFrameKind.error
                else {
                    throw KTPPHostError.handshakeFailure("pair confirm rejected")
                }

                await commitPairing(
                    catalogID: newCatalogID,
                    info: pairResponse.pluginInfo,
                    publicKey: pairResponse.identityPublicKey,
                    role: hello.role,
                    endorsedBy: endorsedBy
                )
                return newCatalogID
        }
    }

    private nonisolated func pullKinds(
        catalogID: UUID, reader: inout KTPPLineReader, writer: KTPPFrameWriter
    ) async throws {
        let frame = KTPPFrame.request(KTPPFrameKind.kindsGet, payload: nil)
        try await writer.send(frame)
        // The protocol is symmetric: a freshly-connected plugin may fire its
        // own `host.*` request while our kinds pull is in flight. Treating
        // any non-matching frame as a violation KILLED such sessions
        // (observed live: a plugin issuing host.ui.addAction right after
        // handshake). Foreign requests get a retryable error so their futures
        // resolve promptly; notifications are dropped; the pull stays bounded.
        var skipped = 0
        while let response = try await reader.next() {
            if response.re == frame.id {
                let kinds = try (response.payload ?? .null).decode(KTPPKindsResult.self)
                await storeKinds(catalogID: catalogID, kinds: kinds)
                return
            }
            skipped += 1
            guard skipped <= 32 else {
                throw KTPPHostError.protocolViolation(
                    "no kinds response within \(skipped) frames")
            }
            if response.re == nil, response.id != nil {
                try await writer.send(
                    .errorResponse(
                        to: response, code: "busy",
                        message: "host is completing registration; retry shortly"))
            }
        }
        throw KTPPHostError.protocolViolation("connection ended before kinds response")
    }
}

// MARK: - Wire helpers

/// Sendable frame writer over the connection's outbound side; stored in the
/// host actor per catalog so `callKind` can write directly.
struct KTPPFrameWriter: Sendable {
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>

    func send(_ frame: KTPPFrame) async throws {
        let line = try KTPPFrameCoding.encodeLine(frame)
        try await outbound.write(ByteBuffer(string: line))
    }
}

/// Single-task NDJSON reader: accumulates raw bytes (so multi-byte UTF-8 can
/// split across chunks safely) and yields decoded frames.
struct KTPPLineReader {
    var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private var buffer: [UInt8] = []

    init(inbound: NIOAsyncChannelInboundStream<ByteBuffer>) {
        self.iterator = inbound.makeAsyncIterator()
    }

    mutating func next() async throws -> KTPPFrame? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                if lineBytes.isEmpty { continue }
                return try KTPPFrameCoding.decodeLine(String(decoding: lineBytes, as: UTF8.self))
            }
            guard var chunk = try await iterator.next() else {
                return nil
            }
            buffer.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
        }
    }
}

#endif
