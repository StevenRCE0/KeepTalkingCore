//
//  CompanionLink.swift
//  KeepTalking
//
//  This process's attachment to the KT Companion, which owns the plugin socket
//  and talks to plugins itself. Each node this process runs attaches and stays
//  online by keepalive; calls name their node, and the companion addresses
//  its requests (ACT turns, proposals, Add Action) to one. Policy stays here:
//  attestation, ACT gating and budget, elucidation caps, the Catalogue.
//

#if os(macOS) || os(Linux)

import Foundation
import MCP

public struct KTPPHostActUsage: Sendable, Equatable {
    public var requests: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
}

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
    public let elucidations: [String]
    public let record: KTPPCallRecord
}

public struct KTPPActAttachment: Sendable {
    public let handle: String
    public let name: String
    public let path: URL
}

public struct KTPPActTurnRequest: Sendable {
    public let task: String
    public let system: String?
    public let expects: String?
    public let maxOutputTokens: Int?
    public let attachments: [KTPPActAttachment]
}

public struct KTPPActCallContext: Sendable {
    public let invocationID: String
    public let catalogID: UUID
    public let catalogName: String
    public let kindName: String
    public let instanceID: UUID
    public let contextID: UUID
    public let callerNodeID: UUID
}

/// Runs the model turns a plugin asks for while it serves one call.
public typealias KTPPActTurn = @Sendable (KTPPActTurnRequest, KTPPActCallContext) async throws -> KTPPActResult

public enum KTPPHostEvent: Sendable {
    case attached
    case detached
    case catalogChanged
    case log(String)
}

public enum KTPPHostError: LocalizedError {
    case companionUnavailable
    case unknownKind(String)
    case notConnected(UUID)
    case timeout(String)
    case protocolViolation(String)
    case pluginRefused(String)
    case callRefused(String)

    public var errorDescription: String? {
        switch self {
            case .companionUnavailable: "The KT Companion is not running."
            case .unknownKind(let name): "No connected plugin provides '\(name)'."
            case .notConnected(let id): "Plugin catalog \(id.uuidString.lowercased()) is not connected."
            case .timeout(let what): "Timed out waiting for \(what)."
            case .protocolViolation(let reason): "KTPP protocol violation: \(reason)"
            case .pluginRefused(let message), .callRefused(let message): message
        }
    }
}

public actor KeepTalkingCompanionLink {
    public typealias ActionProposalHandler = @Sendable (KeepTalkingPluginActionProposal) async -> UUID?
    public typealias AddActionUIHandler = @Sendable (_ kindName: String?, _ pluginName: String?) async -> Void

    private struct ActiveCall {
        let context: KTPPActCallContext
        let attachments: [String: KTPPActAttachment]
        let actPermitted: Bool
        let actTurn: KTPPActTurn?
        let onElucidation: (@Sendable (String, String?) -> Void)?
        var actRequests = 0
        var inputTokens: Int?
        var outputTokens: Int?
        var elucidations: [String] = []
    }

    static let maxActRequestsPerCall = 4
    static let maxActAttachmentBytes = 256 * 1024
    static let defaultActMaxOutputTokens = 4096
    static let maxElucidationsPerCall = 64
    static let elucidationMessageCap = 200
    static let elucidationDetailCap = 4096
    public static let maxScopeOptions = 500

    public static let shared = KeepTalkingCompanionLink(socketPath: socketPath())

    public nonisolated let socketPath: String
    public let catalogue: KeepTalkingPluginCatalogueStore
    private var attestor: any KeepTalkingCallAttestor
    public private(set) var isAttached = false
    private var nodes: [UUID: String?] = [:]
    private var proposalHandlers: [UUID: ActionProposalHandler] = [:]
    private var addActionHandlers: [UUID: AddActionUIHandler] = [:]
    private var outbox: AsyncStream<KTPPWire.AppMessage>.Continuation?
    private var pending: [UInt64: CheckedContinuation<KTPPWire.CompanionMessage, Error>] = [:]
    private var lastRequestID: UInt64 = 0
    private var calls: [String: ActiveCall] = [:]
    private var records: [KTPPCallRecord] = []
    private var tasks: [Task<Void, Never>] = []
    private var eventHandler: (@Sendable (KTPPHostEvent) -> Void)?

    public init(
        socketPath: String,
        catalogue: KeepTalkingPluginCatalogueStore? = nil,
        attestor: any KeepTalkingCallAttestor = KeepTalkingUnattestedCalls()
    ) {
        self.socketPath = socketPath
        self.attestor = attestor
        self.catalogue =
            catalogue ?? KeepTalkingPluginCatalogueStore(fileURL: KeepTalkingPluginCatalogueStore.defaultFileURL())
    }

    /// The companion's socket in the app group both apps share; past the Unix
    /// socket limit, the per-user path in /tmp the companion falls back to too.
    public static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["KT_PLUGIN_SOCKET"], !override.isEmpty {
            return override
        }
        #if canImport(Darwin)
        let directory =
            (Bundle.main.object(forInfoDictionaryKey: "KEEP_TALKING_APP_GROUP") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? URL.applicationSupportDirectory.appending(path: "KeepTalking")
        #else
        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        ).appending(path: "keeptalking")
        #endif
        let path = directory.appending(path: "ktpp.sock").path
        return path.utf8.count <= 100 ? path : "/tmp/ktpp-\(getuid()).sock"
    }

    public func setAttestor(_ attestor: any KeepTalkingCallAttestor) {
        self.attestor = attestor
    }

    public func setEventHandler(_ handler: (@Sendable (KTPPHostEvent) -> Void)?) {
        eventHandler = handler
    }

    private func emit(_ event: KTPPHostEvent) {
        if case .log = event {
        } else {
            let nodes = Array(nodes.keys)
            Task {
                for node in nodes {
                    await KeepTalkingActionCatalogCache.shared.invalidate(nodeID: node)
                }
            }
        }
        eventHandler?(event)
    }

    // MARK: Nodes

    public func attach(node: UUID, label: String?) {
        nodes.updateValue(label, forKey: node)
        send(KTPPWire.AppMessage(from: node.wire, keepalive: .init(label: label)))
    }

    public func detach(node: UUID) {
        proposalHandlers[node] = nil
        addActionHandlers[node] = nil
        guard nodes.removeValue(forKey: node) != nil else { return }
        send(KTPPWire.AppMessage(from: node.wire, leave: .init()))
    }

    public func setActionProposalHandler(_ handler: ActionProposalHandler?, forNode node: UUID) {
        proposalHandlers[node] = handler
    }

    public func setAddActionUIHandler(_ handler: AddActionUIHandler?, forNode node: UUID) {
        addActionHandlers[node] = handler
    }

    private func sendKeepalives() {
        for (node, label) in nodes {
            send(KTPPWire.AppMessage(from: node.wire, keepalive: .init(label: label)))
        }
    }

    // MARK: Attachment

    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { [weak self] in await self?.run() },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: KTPPWire.keepaliveInterval)
                    await self?.sendKeepalives()
                }
            },
        ]
    }

    public func stop() async {
        for node in nodes.keys {
            send(KTPPWire.AppMessage(from: node.wire, leave: .init()))
        }
        tasks.forEach { $0.cancel() }
        tasks = []
        await detached()
    }

    private func run() async {
        guard let client = try? KTPPWireClient(socketPath: socketPath) else {
            log("cannot dial the companion at \(socketPath)")
            return
        }
        let connections = Task { try? await client.runConnections() }
        defer {
            client.beginGracefulShutdown()
            connections.cancel()
        }
        let hello = KTPPWire.AppHello(
            app: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            instance: UUID().uuidString.lowercased())
        while !Task.isCancelled {
            let (queued, outbox) = AsyncStream.makeStream(of: KTPPWire.AppMessage.self)
            self.outbox = outbox
            do {
                try await client.attach(
                    outbound: { writer in
                        try await writer.write(KTPPWire.AppMessage(hello: hello))
                        for await message in queued {
                            try await writer.write(message)
                        }
                    },
                    inbound: { [weak self] messages in
                        defer { outbox.finish() }
                        for try await message in messages {
                            await self?.receive(message)
                        }
                    })
            } catch {
                if !Task.isCancelled { log("companion attachment ended: \(error.localizedDescription)") }
            }
            await detached()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func detached() async {
        outbox?.finish()
        outbox = nil
        for continuation in pending.values {
            continuation.resume(throwing: KTPPHostError.companionUnavailable)
        }
        pending = [:]
        await catalogue.disconnectAll()
        if isAttached {
            isAttached = false
            emit(.detached)
        }
    }

    /// Dropped while detached: the welcome re-announces every node, and
    /// requests refuse up front.
    private func send(_ message: KTPPWire.AppMessage) {
        guard isAttached else { return }
        outbox?.yield(message)
    }

    private func request(
        _ message: KTPPWire.AppMessage, from node: UUID, timeout: TimeInterval, awaiting what: String
    ) async throws -> KTPPWire.CompanionMessage {
        guard isAttached, let outbox else { throw KTPPHostError.companionUnavailable }
        lastRequestID += 1
        let id = lastRequestID
        var message = message
        message.id = id
        message.from = node.wire
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            outbox.yield(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.fail(id, KTPPHostError.timeout(what))
            }
        }
        if let failure = reply.failure { throw KTPPHostError.pluginRefused(failure.message) }
        return reply
    }

    private func fail(_ id: UInt64, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Handled in arrival order, so an elucidation sent before a call's result
    /// is recorded before the result closes the call.
    private func receive(_ message: KTPPWire.CompanionMessage) async {
        if let replyTo = message.replyTo {
            pending.removeValue(forKey: replyTo)?.resume(returning: message)
        } else if let welcome = message.welcome {
            guard welcome.protocolVersion == KTPPWire.protocolVersion else {
                log("the companion speaks KTPP v\(welcome.protocolVersion), this build v\(KTPPWire.protocolVersion)")
                outbox?.finish()
                return
            }
            isAttached = true
            sendKeepalives()
            emit(.attached)
        } else if let catalog = message.catalog {
            await catalogue.apply(catalog.plugins)
            emit(.catalogChanged)
        } else if let note = message.elucidation {
            recordElucidation(note.requestID, note.message, note.detail)
        } else if message.id != nil {
            Task { await self.answer(message) }
        }
    }

    private func answer(_ message: KTPPWire.CompanionMessage) async {
        var reply = KTPPWire.AppMessage(replyTo: message.id, from: message.to)
        if let node = message.to.flatMap(UUID.init(uuidString:)), nodes.keys.contains(node) {
            if let request = message.act {
                do {
                    reply.act = try await act(request)
                } catch let failure as KTPPWire.Failure {
                    reply.failure = failure
                } catch {
                    reply.failure = .init(code: "act_failed", message: error.localizedDescription)
                }
            } else if let request = message.actionCreate {
                reply.actionCreate = await proposeAction(request, node: node)
            } else if let request = message.addAction {
                await addActionHandlers[node]?(request.kindName, request.pluginName)
                reply.addAction = .init()
            } else {
                reply.failure = .init(code: "unsupported", message: "this app does not handle that request")
            }
        } else {
            reply.failure = .init(code: "not_connected", message: "\(message.to ?? "that node") is not attached here")
        }
        send(reply)
    }

    private func log(_ message: String) {
        emit(.log(message))
    }

    // MARK: Requests to plugins

    public func callRecords() -> [KTPPCallRecord] { records }

    @discardableResult
    public func revealCompanion(from node: UUID) async -> Bool {
        let reply = try? await request(.init(reveal: .init()), from: node, timeout: 5, awaiting: "reveal")
        return reply?.reveal?.revealed == true
    }

    private func connectedKind(
        _ catalogID: UUID, _ kindName: String
    ) async throws -> (KeepTalkingPluginCatalogueEntry, KTPPKindDeclaration) {
        guard isAttached else { throw KTPPHostError.companionUnavailable }
        guard await catalogue.isConnected(catalogID), let entry = await catalogue.catalogue(catalogID) else {
            throw KTPPHostError.notConnected(catalogID)
        }
        guard let kind = entry.kinds.first(where: { $0.kindName == kindName }) else {
            throw KTPPHostError.unknownKind(kindName)
        }
        return (entry, kind)
    }

    /// Live choices for one `x-ktpp-options.live` scope key — untrusted
    /// display data, capped and sanitized here.
    public func scopeOptions(
        catalogID: UUID, kindName: String, key: String, scope: [String: Value] = [:], query: String? = nil,
        from node: UUID
    ) async throws -> [KTPPScopeOption] {
        let (entry, kind) = try await connectedKind(catalogID, kindName)
        guard KTPPScopeOptionsSpec.parse(scopeSchema: kind.scopeSchema, key: key)?.isLive == true else {
            throw KTPPHostError.protocolViolation("kind '\(kindName)' declares no live options for '\(key)'")
        }
        let request = KTPPScopeOptionsRequest(
            kindName: kindName, key: key, scope: scope, query: query?.isEmpty == false ? query : nil)
        let reply = try await self.request(
            .init(scopeOptions: .init(plugin: entry.name, request: request)), from: node, timeout: 15,
            awaiting: "scope options")
        return Array((reply.scopeOptions?.options ?? []).compactMap { $0.sanitized() }.prefix(Self.maxScopeOptions))
    }

    /// Reads a resource the kind declares; undeclared uris are refused before
    /// anything is sent.
    public func readResource(
        catalogID: UUID, kindName: String, uri: String, from node: UUID
    ) async throws -> [Resource.Content] {
        let (entry, kind) = try await connectedKind(catalogID, kindName)
        guard kind.resources?.contains(where: { $0.uri == uri }) == true else {
            throw KTPPHostError.protocolViolation("'\(uri)' is not a resource \(kindName) declares")
        }
        let reply = try await request(
            .init(resourceRead: .init(plugin: entry.name, request: .init(kindName: kindName, uri: uri))),
            from: node, timeout: 30, awaiting: "resource read")
        return reply.resourceRead?.contents ?? []
    }

    /// One call to a kind on behalf of `node`. The attestor authorizes it and
    /// verifies the plugin's receipt; `manifest` projects into the call's
    /// resources (paths only — no bytes cross the socket).
    public func callKind(
        catalogID: UUID,
        kindName: String,
        tool: String? = nil,
        arguments: [String: Value],
        instanceID: UUID,
        instanceScope: Value?,
        node: UUID,
        contextID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        callerNodeID: UUID? = nil,
        manifest: KTResourceManifest? = nil,
        actTurn: KTPPActTurn? = nil,
        onElucidation: (@Sendable (String, String?) -> Void)? = nil,
        timeout: TimeInterval = 300
    ) async throws -> KTPPCallOutcome {
        let (entry, kind) = try await connectedKind(catalogID, kindName)
        let invocationID = UUID.v7().uuidString.lowercased()
        let callerNodeID = callerNodeID ?? node
        let arguments = Value.object(arguments)
        let resources = KTPPResources(manifest: manifest)
        let statement = KeepTalkingCallStatement(
            invocationID: invocationID, hostNodeID: node, callerNodeID: callerNodeID, contextID: contextID,
            executorID: catalogID, kindName: kindName, tool: tool, actionID: instanceID, scope: instanceScope,
            arguments: arguments, resources: resources?.entries ?? [], issuedAt: .now)
        let attestor = self.attestor
        let authorization = try await attestor.authorize(statement)

        let readable = (resources?.entries ?? []).compactMap { entry -> (String, KTPPActAttachment)? in
            guard entry.direction == .read, let path = entry.path else { return nil }
            return (
                entry.handle,
                KTPPActAttachment(handle: entry.handle, name: entry.name, path: URL(fileURLWithPath: path))
            )
        }
        calls[invocationID] = ActiveCall(
            context: KTPPActCallContext(
                invocationID: invocationID, catalogID: catalogID, catalogName: entry.name, kindName: kindName,
                instanceID: instanceID, contextID: contextID, callerNodeID: callerNodeID),
            attachments: Dictionary(readable, uniquingKeysWith: { first, _ in first }),
            actPermitted: Self.actCapabilityPermitted(kind: kind, instanceScope: instanceScope),
            actTurn: actTurn,
            onElucidation: onElucidation)
        defer { calls[invocationID] = nil }

        let call = KTPPCallRequest(
            requestID: invocationID, contextID: contextID.wire, callerNodeID: callerNodeID.wire,
            kindName: kindName, tool: tool, arguments: arguments,
            instance: KTPPInstanceRef(id: instanceID.wire, scope: instanceScope),
            resources: resources, authorization: authorization)
        let result: KTPPCallResult
        do {
            let reply = try await request(
                .init(call: .init(plugin: entry.name, request: call)), from: node, timeout: timeout,
                awaiting: "call result")
            guard let callResult = reply.callResult else {
                throw KTPPHostError.protocolViolation("expected a call result")
            }
            result = callResult
        } catch {
            send(KTPPWire.AppMessage(from: node.wire, cancel: .init(requestID: invocationID)))
            throw error
        }
        let usage = result.usage ?? []
        let verdict = await attestor.verify(
            receipt: result.receipt,
            result: KeepTalkingCallResultStatement(
                invocationID: invocationID, content: result.content, isError: result.isError, usage: usage),
            statement: statement,
            authorization: authorization)
        let finished = calls[invocationID]
        let record = KTPPCallRecord(
            invocationID: invocationID, catalogID: catalogID, kindName: kindName, authorization: authorization,
            receipt: result.receipt, verdict: verdict, usage: usage,
            hostActUsage: finished.flatMap {
                $0.actRequests > 0
                    ? KTPPHostActUsage(
                        requests: $0.actRequests, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
                    : nil
            })
        records.append(record)
        return KTPPCallOutcome(
            content: result.content, isError: result.isError, usage: usage,
            elucidations: finished?.elucidations ?? [], record: record)
    }

    // MARK: Requests from plugins

    /// A plugin may only propose instances of its own kinds.
    private func proposeAction(_ request: KTPPActionCreateRequest, node: UUID) async -> KTPPActionCreateResult {
        guard let handler = proposalHandlers[node] else {
            return .init(status: "unsupported", actionID: nil, message: "this identity takes no proposals")
        }
        let catalogID = await catalogue.catalogID(forPluginName: request.pluginName)
        guard await catalogue.isConnected(catalogID),
            let entry = await catalogue.catalogue(catalogID),
            entry.kinds.contains(where: { $0.kindName == request.kindName })
        else {
            return .init(status: "declined", actionID: nil, message: "'\(request.kindName)' is not yours to propose")
        }
        let proposal = KeepTalkingPluginActionProposal(
            catalogID: catalogID, catalogName: entry.name, kindName: request.kindName,
            suggestedName: request.suggestedName ?? request.kindName.beautifulName,
            reason: request.reason, suggestedScope: request.suggestedScope)
        guard let actionID = await handler(proposal) else {
            return .init(status: "declined", actionID: nil, message: "user declined")
        }
        return .init(status: "created", actionID: actionID.wire, message: nil)
    }

    /// The kind must declare `act`, and an instance's `capabilities` narrowing
    /// must keep it; an unreadable narrowing denies.
    static func actCapabilityPermitted(kind: KTPPKindDeclaration?, instanceScope: Value?) -> Bool {
        guard kind?.declaredCapabilities.contains(.act) == true else { return false }
        guard case .object(let fields)? = instanceScope, let narrowing = fields["capabilities"] else { return true }
        guard case .array(let kept) = narrowing else { return false }
        return kept.contains(.string(KTPPPluginCapability.act.rawValue))
    }

    /// One bounded model turn for a running call: bound to the call, gated by
    /// the capability and the user's per-plugin consent, budgeted, and given
    /// only attachments the call was handed to read.
    private func act(_ request: KTPPActRequest) async throws -> KTPPActResult {
        guard let call = calls[request.requestID] else {
            throw KTPPWire.Failure(code: "act_unbound", message: "no in-flight call \(request.requestID)")
        }
        guard call.actPermitted else {
            throw KTPPWire.Failure(code: "act_denied", message: "this kind or instance lacks the 'act' capability")
        }
        guard await catalogue.allowsACT(call.context.catalogID) else {
            throw KTPPWire.Failure(code: "act_denied", message: "the user has not let this plugin use the AI provider")
        }
        guard let actTurn = call.actTurn else {
            throw KTPPWire.Failure(code: "act_unavailable", message: "this call carries no ACT connector")
        }
        guard let current = calls[request.requestID] else {
            throw KTPPWire.Failure(code: "act_unbound", message: "call \(request.requestID) already ended")
        }
        guard current.actRequests < Self.maxActRequestsPerCall else {
            throw KTPPWire.Failure(
                code: "act_budget_exhausted", message: "per-call ACT budget (\(Self.maxActRequestsPerCall)) exhausted")
        }
        let attachments = try (request.attachments ?? []).map { handle in
            guard let attachment = call.attachments[handle] else {
                throw KTPPWire.Failure(
                    code: "act_denied", message: "attachment \(handle) is not provisioned for this call")
            }
            return attachment
        }
        calls[request.requestID]?.actRequests += 1
        recordElucidation(request.requestID, "AI turn: \(request.task)", nil)
        let result: KTPPActResult
        do {
            result = try await actTurn(
                KTPPActTurnRequest(
                    task: request.task, system: request.system, expects: request.expects,
                    maxOutputTokens: min(
                        request.maxOutputTokens ?? Self.defaultActMaxOutputTokens, Self.defaultActMaxOutputTokens),
                    attachments: attachments),
                call.context)
        } catch {
            throw KTPPWire.Failure(code: "act_failed", message: error.localizedDescription)
        }
        if let usage = result.usage {
            calls[request.requestID]?.inputTokens =
                (calls[request.requestID]?.inputTokens ?? 0) + (usage.inputTokens ?? 0)
            calls[request.requestID]?.outputTokens =
                (calls[request.requestID]?.outputTokens ?? 0) + (usage.outputTokens ?? 0)
        }
        call.onElucidation?("AI turn: \(request.task)", String(result.text.prefix(Self.elucidationDetailCap)))
        return result
    }

    private func recordElucidation(_ invocationID: String, _ message: String, _ detail: String?) {
        guard let call = calls[invocationID], call.elucidations.count < Self.maxElucidationsPerCall else { return }
        let message = String(message.prefix(Self.elucidationMessageCap))
        calls[invocationID]?.elucidations.append(message)
        call.onElucidation?(message, detail.map { String($0.prefix(Self.elucidationDetailCap)) })
    }
}

extension UUID {
    fileprivate var wire: String { uuidString.lowercased() }
}

#endif
