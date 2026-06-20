import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

public enum MCPManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case invalidStdioCommand
    case stdioUnavailableOnThisPlatform
    case missingHTTPAuthURLHandler(UUID)
    case httpAuthCancelled(UUID)
    case httpAuthDeclined(UUID)
    case connectionTimedOut(TimeInterval)
    case toolCallTimedOut(UUID, TimeInterval)
    case stdioProcessExitedEarly(command: [String], status: Int32)
    case unknownMCPTool(requested: String, available: [String])
    case toolNotPermitted(String)
    case unregisteredAction(UUID)
    /// The action's executor went away (server torn down / health failed) while
    /// we were patiently waiting on an in-flight tool call.
    case executorUnavailable(UUID)

    public var errorDescription: String? {
        switch self {
            case .invalidAction:
                return "Action payload is not an MCP bundle."
            case .missingActionID:
                return "Action must have an ID before registration."
            case .invalidStdioCommand:
                return "Stdio MCP command must include an executable."
            case .stdioUnavailableOnThisPlatform:
                return "Stdio MCP is unavailable on this platform."
            case .missingHTTPAuthURLHandler(let actionID):
                return "HTTP MCP action requires auth flow, but no auth handler is registered. action=\(actionID)"
            case .httpAuthCancelled(let actionID):
                return "HTTP MCP auth flow was cancelled. action=\(actionID)"
            case .httpAuthDeclined(let actionID):
                return "HTTP MCP auth flow was declined. action=\(actionID)"
            case .connectionTimedOut(let timeout):
                return "Timed out while connecting to MCP server after \(Int(timeout))s."
            case .toolCallTimedOut(let actionID, let timeout):
                return "Timed out waiting for MCP tool call action=\(actionID) after \(Int(timeout))s."
            case .stdioProcessExitedEarly(let command, let status):
                return
                    "Stdio MCP process exited early (status=\(status)) for command: \(command.joined(separator: " "))"
            case .unknownMCPTool(let requested, let available):
                let options = available.joined(separator: ", ")
                return "Unknown MCP tool '\(requested)'. Available tools: [\(options)]"
            case .toolNotPermitted(let name):
                return "MCP tool '\(name)' is not permitted by the caller's grant."
            case .unregisteredAction(let actionID):
                return "Action is not registered in MCPManager: \(actionID)"
            case .executorUnavailable(let actionID):
                return "MCP executor became unavailable while the tool call was running: \(actionID)"
        }
    }
}

public enum KeepTalkingMCPHTTPAuthResult: Sendable {
    case completed(callbackURL: URL)
    case cancelled
    case declined
}

/// Live runtime health of an MCP-backed action inside `MCPManager`.
///
/// Exposed publicly so node-status assembly and the app UI can surface real
/// availability rather than a binary registered/unregistered guess.
public enum MCPActionHealth: Sendable, Equatable {
    /// MCPManager has no record of this action — it has never been registered
    /// or has been torn down.
    case notRegistered
    /// User has flipped `KeepTalkingAction.disabled = true`. The MCP server is
    /// not running. Persisted; survives across app launches.
    case disabled
    /// Connection handshake in progress. Receivers may briefly retry.
    case connecting
    /// Server is connected. `tools` is the cached tool-name set from the
    /// most recent `listTools` (or tool-list-changed notification).
    case connected(tools: [String])
    /// Server registered but failed to come up. `reason` is suitable for UI.
    case failed(reason: String)
    /// Action is a virtual remote stub on this node — no local server runs.
    case virtualRemote
}

/// Manages MCP action registration, transport connections, and tool invocation.
public actor MCPManager {
    private actor IncrementingRequestIDTransport: Transport {
        nonisolated let logger: Logger

        private let base: any Transport
        private var adapter = IncrementingRequestIDAdapter()

        init(base: any Transport) {
            self.base = base
            self.logger = Logger(label: "keepTalking.transport.logging") { _ in
                SwiftLogNoOpLogHandler()
            }
        }

        func connect() async throws {
            try await base.connect()
        }

        func disconnect() async {
            await base.disconnect()
        }

        func send(_ data: Data) async throws {
            try await base.send(rewriteOutgoingMessageData(data))
        }

        func receive() -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        let stream = await base.receive()
                        for try await data in stream {
                            continuation.yield(await self.rewriteIncomingMessageData(data))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        private func rewriteOutgoingMessageData(_ data: Data) -> Data {
            adapter.rewriteOutgoingMessageData(data)
        }

        private func rewriteIncomingMessageData(_ data: Data) async -> Data {
            adapter.rewriteIncomingMessageData(data)
        }
    }

    private struct IncrementingRequestIDAdapter: Sendable {
        private var nextNumericRequestID = 1
        private var numericRequestIDByOriginalID: [String: Int] = [:]
        private var originalRequestIDByNumericID: [Int: String] = [:]

        mutating func rewriteOutgoingMessageData(_ data: Data) -> Data {
            rewriteMessageData(data, direction: .outgoing)
        }

        mutating func rewriteIncomingMessageData(_ data: Data) -> Data {
            rewriteMessageData(data, direction: .incoming)
        }

        private enum Direction {
            case outgoing
            case incoming
        }

        private mutating func rewriteMessageData(
            _ data: Data,
            direction: Direction
        ) -> Data {
            guard
                let object = try? JSONSerialization.jsonObject(with: data),
                let rewrittenData = serializeRewrittenObject(
                    rewriteTopLevelMessageObject(object, direction: direction)
                )
            else {
                return data
            }

            return rewrittenData
        }

        private mutating func rewriteTopLevelMessageObject(
            _ object: Any,
            direction: Direction
        ) -> Any {
            if var message = object as? [String: Any] {
                rewriteMessageDictionary(&message, direction: direction)
                return message
            }

            if let batch = object as? [Any] {
                return batch.map { element in
                    guard var message = element as? [String: Any] else {
                        return element
                    }
                    rewriteMessageDictionary(&message, direction: direction)
                    return message
                }
            }

            return object
        }

        private mutating func rewriteMessageDictionary(
            _ message: inout [String: Any],
            direction: Direction
        ) {
            switch direction {
                case .outgoing:
                    if let originalID = message["id"] as? String {
                        message["id"] = numericRequestID(for: originalID)
                    }
                    rewriteRequestIdentifierField(
                        in: &message,
                        direction: .outgoing
                    )
                case .incoming:
                    if let numericID = integerValue(from: message["id"]),
                        let originalID = originalRequestIDByNumericID[numericID]
                    {
                        message["id"] = originalID
                    }
                    rewriteRequestIdentifierField(
                        in: &message,
                        direction: .incoming
                    )
            }
        }

        private mutating func rewriteRequestIdentifierField(
            in message: inout [String: Any],
            direction: Direction
        ) {
            guard var params = message["params"] as? [String: Any] else {
                return
            }

            switch direction {
                case .outgoing:
                    if let originalID = params["requestId"] as? String,
                        let numericID = numericRequestIDByOriginalID[originalID]
                    {
                        params["requestId"] = numericID
                        message["params"] = params
                    }
                case .incoming:
                    if let numericID = integerValue(from: params["requestId"]),
                        let originalID = originalRequestIDByNumericID[numericID]
                    {
                        params["requestId"] = originalID
                        message["params"] = params
                    }
            }
        }

        private mutating func numericRequestID(for originalID: String) -> Int {
            if let numericID = numericRequestIDByOriginalID[originalID] {
                return numericID
            }

            let numericID = nextNumericRequestID
            nextNumericRequestID += 1
            numericRequestIDByOriginalID[originalID] = numericID
            originalRequestIDByNumericID[numericID] = originalID
            return numericID
        }

        private func integerValue(from value: Any?) -> Int? {
            switch value {
                case let value as Int:
                    return value
                case let value as NSNumber:
                    return value.intValue
                default:
                    return nil
            }
        }

        private func serializeRewrittenObject(_ object: Any) -> Data? {
            guard JSONSerialization.isValidJSONObject(object) else {
                return nil
            }
            return try? JSONSerialization.data(withJSONObject: object)
        }
    }

    private final class StdioProcessHandle: @unchecked Sendable {
        let processHandler: any MCPStdioProcessHandling

        init(processHandler: any MCPStdioProcessHandling) {
            self.processHandler = processHandler
        }
    }

    private let nodeConfig: KeepTalkingConfig
    private let stdioTransportLauncher: (any MCPStdioTransportLaunching)?
    /// Keychain-backed source of per-action HTTP MCP credentials. Headers are
    /// re-hydrated from here at connect/preflight time instead of being carried
    /// in the (database-persisted) bundle.
    private let credentialStore: KeepTalkingMCPCredentialStore?
    private let connectTimeoutSeconds: TimeInterval
    /// How long a tool call waits silently before it switches to patient
    /// liveness-polling. After this it waits indefinitely while the executor
    /// stays healthy (see `callToolPatiently`).
    private let toolCallGraceSeconds: TimeInterval
    /// Liveness poll cadence once a tool call exceeds its grace period.
    private let toolCallPollSeconds: TimeInterval
    private var clientsByActionID: [UUID: Client] = [:]
    /// In-flight connect tasks, keyed by action, so concurrent callers
    /// (callAction / listTools / lazy registration) share one connect instead of
    /// each building a second Client+transport+authorizer — which would otherwise
    /// double-prompt OAuth and leak the loser's transport.
    private var connectingByActionID: [UUID: Task<Void, Error>] = [:]
    /// Connect timeout for the per-action handshake. Generous because the
    /// `initialize` request can drive interactive OAuth — the SDK HTTP authorizer
    /// presenting a browser, or a stdio server (e.g. `npx mcp-remote`) running its
    /// own browser + loopback callback flow — which must be allowed to complete
    /// instead of being cancelled at the short default timeout.
    private let interactiveConnectTimeoutSeconds: TimeInterval = 300
    private var stdioProcessesByActionID: [UUID: StdioProcessHandle] = [:]
    private var virtualToolNamesByActionID: [UUID: [String]] = [:]
    private var healthByActionID: [UUID: MCPActionHealth] = [:]
    private var onActionToolsChanged: (@Sendable (UUID) async -> Void)?
    private var onLog: (@Sendable (String) -> Void)?
    private var onHTTPAuthURL: (@Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult)?
    /// Supplies a per-action OAuth authorizer for HTTP MCP transports so OAuth is
    /// driven in-protocol (the transport reacts to 401/403 → the authorizer →
    /// discovery/token/retry) instead of a bespoke preflight gate.
    private var authorizerProvider: (@Sendable (UUID, URL) async -> (any HTTPClientAuthorizer)?)?

    /// Creates an MCP manager for a node runtime.
    public init(
        nodeConfig: KeepTalkingConfig,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        credentialStore: KeepTalkingMCPCredentialStore? = nil,
        connectTimeoutSeconds: TimeInterval = 10,
        toolCallGraceSeconds: TimeInterval = 10,
        toolCallPollSeconds: TimeInterval = 5
    ) {
        self.nodeConfig = nodeConfig
        self.stdioTransportLauncher = stdioTransportLauncher
        self.credentialStore = credentialStore
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.toolCallGraceSeconds = toolCallGraceSeconds
        self.toolCallPollSeconds = toolCallPollSeconds
    }

    /// Sets a callback invoked when a registered action's tool list changes.
    public func setActionToolsChangedHandler(
        _ handler: (@Sendable (UUID) async -> Void)?
    ) {
        onActionToolsChanged = handler
    }

    /// Sets a log sink for MCP lifecycle events.
    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        onLog = handler
    }

    /// Sets the callback used to drive HTTP authentication flows for MCP actions.
    public func setHTTPAuthURLHandler(
        _ handler: (@Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult)?
    ) {
        onHTTPAuthURL = handler
    }

    /// Installs a factory that supplies a per-action `HTTPClientAuthorizer` for
    /// HTTP MCP transports. When set, the SDK transport performs OAuth in-band on
    /// a 401/403 challenge via the authorizer, rather than relying on a separate
    /// preflight gate.
    public func setAuthorizerProvider(
        _ provider: (@Sendable (UUID, URL) async -> (any HTTPClientAuthorizer)?)?
    ) {
        authorizerProvider = provider
    }

    /// Registers an MCP-backed action with the runtime manager.
    public func registerMCPAction(_ action: KeepTalkingAction) async throws {
        guard case .mcpBundle = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }

        if isVirtualRemoteAction(action) {
            virtualToolNamesByActionID[actionID] = virtualToolNames(for: action)
            healthByActionID[actionID] = .virtualRemote
        } else {
            virtualToolNamesByActionID.removeValue(forKey: actionID)
            // Preserve `.connected`/`.failed` if a live client is already
            // tracked; otherwise mark it pending so the next `registerIfNeeded`
            // transitions it to `.connecting`.
            if action.disabled == true {
                healthByActionID[actionID] = .disabled
            } else if case .connected = healthByActionID[actionID] {
                // keep
            } else if case .failed = healthByActionID[actionID] {
                // keep
            } else {
                healthByActionID[actionID] = .notRegistered
            }
        }

        // Action metadata is source-of-truth in Fluent models. We only
        // track runtime client/process state here.
    }

    /// Reconnects an MCP action after its configuration changes.
    public func refreshMCPAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        if let existingClient = clientsByActionID[actionID] {
            await existingClient.disconnect()
            clientsByActionID.removeValue(forKey: actionID)
        }
        terminateStdioProcess(for: actionID)
        // Reset prior health so registerMCPAction starts from a clean slate
        // rather than preserving a stale `.connected`/`.failed`.
        healthByActionID.removeValue(forKey: actionID)
        try await registerMCPAction(action)
    }

    /// Removes an MCP action and tears down any live client state.
    public func unregisterAction(actionID: UUID) async {
        let client = clientsByActionID.removeValue(forKey: actionID)
        let process = stdioProcessesByActionID.removeValue(forKey: actionID)
        virtualToolNamesByActionID.removeValue(forKey: actionID)
        healthByActionID.removeValue(forKey: actionID)
        Self.teardownClientDetached(client: client, process: process)
    }

    /// Tears down any live client/process for a user-disabled action while
    /// keeping the manager aware that the action exists. Used by the action
    /// controller when the persisted `disabled` flag flips to true.
    public func disableAction(actionID: UUID) async {
        let client = clientsByActionID.removeValue(forKey: actionID)
        let process = stdioProcessesByActionID.removeValue(forKey: actionID)
        virtualToolNamesByActionID.removeValue(forKey: actionID)
        healthByActionID[actionID] = .disabled
        Self.teardownClientDetached(client: client, process: process)
    }

    /// Tears a live MCP client/process down best-effort, detached from the
    /// caller's task. `Client.disconnect()` ends by awaiting the message-loop
    /// task, which a wedged STDIO process or stuck HTTP stream can stall
    /// indefinitely — so disabling/removing must never wait on it: a failed
    /// action has to stay disableable and removable. The manager's in-memory
    /// state is already updated by the caller before this runs, so the action
    /// is effectively off the moment it returns. We terminate the process
    /// first (unblocking the read loop so the disconnect can actually drain),
    /// then disconnect.
    private static func teardownClientDetached(
        client: Client?,
        process: StdioProcessHandle?
    ) {
        guard client != nil || process != nil else {
            return
        }
        Task.detached {
            process?.processHandler.terminate()
            await client?.disconnect()
        }
    }

    /// Live runtime health for an MCP action. Returns `.notRegistered` when
    /// the manager has never seen this action ID.
    public func actionHealth(actionID: UUID) -> MCPActionHealth {
        healthByActionID[actionID] ?? .notRegistered
    }

    /// Live runtime health for a batch of actions. Convenience for the
    /// node-status builder so it can compute availability for the entire
    /// outgoing relation in one actor hop.
    public func actionHealthMap(
        actionIDs: some Sequence<UUID>
    ) -> [UUID: MCPActionHealth] {
        var out: [UUID: MCPActionHealth] = [:]
        for id in actionIDs {
            out[id] = healthByActionID[id] ?? .notRegistered
        }
        return out
    }

    /// Ensures an MCP action is registered and connected before use.
    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        // Honour the user's disable flag — never spin a server up for an
        // action the user has explicitly turned off.
        if action.disabled == true {
            await disableAction(actionID: actionID)
            return
        }
        try await registerMCPAction(action)
        if virtualToolNamesByActionID[actionID] != nil {
            return
        }
        guard clientsByActionID[actionID] == nil else {
            return
        }
        // Coalesce concurrent connects for the same action onto one task so a
        // single OAuth consent runs (not one per caller) and no transport leaks.
        if let existing = connectingByActionID[actionID] {
            try await existing.value
            return
        }
        let connectTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.connectActionClient(actionID: actionID, action: action)
        }
        connectingByActionID[actionID] = connectTask
        do {
            try await connectTask.value
            connectingByActionID[actionID] = nil
        } catch {
            connectingByActionID[actionID] = nil
            throw error
        }
    }

    /// Invokes an MCP tool for the supplied action call.
    ///
    /// - Parameter scope: The caller's grant scope. `.all` or a `.verbs` set
    ///   containing the `.callTool` class wildcard permits all tools; otherwise
    ///   only tools named by `.named(...)` tokens are permitted (an empty set
    ///   rejects every call).
    ///
    /// MCP tool calls do NOT receive a per-call resource manifest (the
    /// `KT_<KIND>_<H8>` env vars Skills and ACP get): the stdio server is launched
    /// once with a static environment and reused for every call, so per-call
    /// resource injection is not applicable. Pass resources as tool arguments, or
    /// stage them via the filesystem actions, instead.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        scope: KeepTalkingActionScope
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        try await registerIfNeeded(action)
        guard case .mcpBundle(let mcpBundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard let client = clientsByActionID[actionID] else {
            throw MCPManagerError.unregisteredAction(actionID)
        }
        let invocation = try await resolveValidatedToolInvocation(
            client: client,
            defaultToolName: mcpBundle.name,
            rawArguments: call.arguments
        )

        // `.callTool` (or `.all`) = all tools allowed → `nil`; otherwise the
        // explicit `.named(...)` tool allowlist (possibly empty = none).
        let allowedTools = scope.allowedNames(classWildcard: .callTool).map { Set($0) }
        if let allowedTools, !allowedTools.contains(invocation.name) {
            throw MCPManagerError.toolNotPermitted(invocation.name)
        }

        let log = onLog
        return try await Self.callToolPatiently(
            client: client,
            name: invocation.name,
            arguments: invocation.arguments as [String: Value]?,
            meta: call.metadata,
            actionID: actionID,
            graceSeconds: toolCallGraceSeconds,
            pollSeconds: toolCallPollSeconds,
            log: log,
            isAlive: { [weak self] in await self?.isActionExecutorLive(actionID) ?? false }
        )
    }

    /// Whether the executor backing `actionID` is still alive enough to keep
    /// waiting on. Used by `callToolPatiently` once a tool call exceeds its
    /// grace period. A dead transport makes `callTool` throw on its own; this
    /// is the secondary net that catches an explicit teardown / failed health.
    func isActionExecutorLive(_ actionID: UUID) -> Bool {
        guard clientsByActionID[actionID] != nil else { return false }
        if case .failed = healthByActionID[actionID] { return false }
        return true
    }

    /// Returns the sorted tool names currently exposed by an MCP action.
    public func listActionToolNames(action: KeepTalkingAction) async throws -> [String] {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        try await registerIfNeeded(action)
        if let virtualToolNames = virtualToolNamesByActionID[actionID] {
            return virtualToolNames.sorted()
        }
        guard let client = clientsByActionID[actionID] else {
            throw MCPManagerError.unregisteredAction(actionID)
        }
        let names = try await client.listTools().tools.map(\.name).sorted()

        return names
    }

    /// Returns the full tool metadata currently exposed by an MCP action.
    public func listActionTools(action: KeepTalkingAction) async throws -> [Tool] {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        try await registerIfNeeded(action)
        if virtualToolNamesByActionID[actionID] != nil {
            return []
        }
        guard let client = clientsByActionID[actionID] else {
            throw MCPManagerError.unregisteredAction(actionID)
        }
        let tools = try await client.listTools().tools.sorted { $0.name < $1.name }

        return tools
    }

    private func resolveToolInvocation(
        defaultToolName: String,
        rawArguments: [String: Value]
    ) -> (name: String, arguments: [String: Value]) {
        let specifiedToolName =
            rawArguments["tool"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = {
            guard let specifiedToolName, !specifiedToolName.isEmpty else {
                return defaultToolName
            }
            return specifiedToolName
        }()

        // Wrapper shape: { "tool": "...", "arguments": { ... } }
        if let nestedArguments = rawArguments["arguments"]?.objectValue {
            return (toolName, nestedArguments)
        }

        // Backward-compatible passthrough for existing action calls.
        var passthrough = rawArguments
        passthrough.removeValue(forKey: "tool")
        passthrough.removeValue(forKey: "arguments")
        return (toolName, passthrough)
    }

    private func resolveValidatedToolInvocation(
        client: Client,
        defaultToolName: String,
        rawArguments: [String: Value]
    ) async throws -> (name: String, arguments: [String: Value]) {
        var invocation = resolveToolInvocation(
            defaultToolName: defaultToolName,
            rawArguments: rawArguments
        )
        let explicitlySelectedTool = rawArguments["tool"]?.stringValue != nil

        let listing = try await client.listTools()
        let availableNames = listing.tools.map(\.name)

        guard !availableNames.isEmpty else {
            return invocation
        }
        if availableNames.contains(invocation.name) {
            return invocation
        }
        if !explicitlySelectedTool, availableNames.count == 1,
            let onlyTool = availableNames.first
        {
            invocation.name = onlyTool
            return invocation
        }
        throw MCPManagerError.unknownMCPTool(
            requested: invocation.name,
            available: availableNames
        )
    }

    /// Invokes an MCP tool *patiently*: it waits silently for `graceSeconds`,
    /// then keeps waiting indefinitely as long as the executor stays alive,
    /// polling liveness every `pollSeconds`. It gives up only if the executor
    /// dies (`executorUnavailable`), `callTool` itself throws, or the
    /// surrounding task is cancelled — in which case the in-flight request is
    /// resumed locally with `CancellationError` and a `notifications/cancelled`
    /// is sent to the server, so an aborted agent run stops the running tool.
    private nonisolated static func callToolPatiently(
        client: Client,
        name: String,
        arguments: [String: Value]?,
        meta: Metadata,
        actionID: UUID,
        graceSeconds: TimeInterval,
        pollSeconds: TimeInterval,
        log: (@Sendable (String) -> Void)?,
        isAlive: @escaping @Sendable () async -> Bool
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try await patientWait(
            label: "mcp tool \(name) action=\(actionID.uuidString.lowercased())",
            graceSeconds: graceSeconds,
            pollSeconds: pollSeconds,
            log: log,
            isAlive: isAlive,
            onDeath: { MCPManagerError.executorUnavailable(actionID) }
        ) {
            // Use the cancellation-tracking RequestContext variant so an aborted
            // agent run actually stops the tool: on cancel we resume the local
            // wait with CancellationError AND send the MCP notifications/cancelled
            // so the server stops processing (advisory, per the MCP spec).
            let requestContext: RequestContext<CallTool.Result> =
                try await client.callTool(
                    name: name,
                    arguments: arguments,
                    meta: meta
                )
            let result = try await withTaskCancellationHandler {
                try await requestContext.value
            } onCancel: {
                Task {
                    try? await client.cancelRequest(
                        requestContext.requestID,
                        reason: "KeepTalking agent run cancelled"
                    )
                }
            }
            return (content: result.content, isError: result.isError)
        }
    }

    private nonisolated static func connectClient(
        _ client: Client,
        transport: any Transport,
        timeoutSeconds: TimeInterval
    ) async throws {
        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
        actor CompletionState {
            private var completed = false

            func markCompleted() -> Bool {
                guard !completed else {
                    return false
                }
                completed = true
                return true
            }
        }

        let state = CompletionState()

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let connectTask = Task {
                do {
                    _ = try await client.connect(transport: transport)
                    guard await state.markCompleted() else {
                        return
                    }
                    continuation.resume(returning: ())
                } catch {
                    guard await state.markCompleted() else {
                        return
                    }
                    continuation.resume(throwing: error)
                }
            }

            Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                } catch {
                    return
                }
                connectTask.cancel()
                guard await state.markCompleted() else {
                    return
                }
                continuation.resume(
                    throwing: MCPManagerError.connectionTimedOut(timeoutSeconds)
                )
            }
        }
    }

    private func connectStdioAction(
        actionID: UUID,
        client: Client,
        command: [String],
        environment: [String: String]
    ) async throws {
        guard !command.isEmpty else {
            throw MCPManagerError.invalidStdioCommand
        }
        guard let stdioTransportLauncher else {
            throw MCPManagerError.stdioUnavailableOnThisPlatform
        }

        #if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
        let launched = try await stdioTransportLauncher.launchTransport(
            command: command,
            environment: environment,
            stderrHandler: { [weak self] data in
                Task { await self?.logStdioStderr(actionID: actionID, data: data) }
            },
            sandboxPolicy: nil
        )
        #else
        let launched = try await stdioTransportLauncher.launchTransport(
            command: command,
            environment: environment
        ) { [weak self] data in
            Task { await self?.logStdioStderr(actionID: actionID, data: data) }
        }
        #endif
        let launchedTransport = IncrementingRequestIDTransport(
            base: launched.transport
        )
        let launchedProcessHandler = launched.processHandler

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.connectClient(
                        client,
                        transport: launchedTransport,
                        timeoutSeconds: self.interactiveConnectTimeoutSeconds
                    )
                }

                group.addTask {
                    while true {
                        if Task.isCancelled { return }
                        if let status = launchedProcessHandler.terminationStatus() {
                            throw MCPManagerError.stdioProcessExitedEarly(
                                command: command,
                                status: status
                            )
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                guard try await group.next() != nil else {
                    throw MCPManagerError.connectionTimedOut(self.interactiveConnectTimeoutSeconds)
                }
                group.cancelAll()
            }

            stdioProcessesByActionID[actionID] = StdioProcessHandle(
                processHandler: launchedProcessHandler
            )
        } catch {
            launchedProcessHandler.terminate()
            throw error
        }
    }

    private func connectActionClient(
        actionID: UUID,
        action: KeepTalkingAction
    ) async throws {
        guard clientsByActionID[actionID] == nil else {
            return
        }
        guard case .mcpBundle(let mcpBundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }

        healthByActionID[actionID] = .connecting

        let client = Client(
            name: "KeepTalking:\(nodeConfig.node.uuidString):\(actionID.uuidString)",
            version: "1.0.0",
            title: "KeepTalking",
            capabilities: .init(
                elicitation: .init(form: nil, url: .init())
            ),
            configuration: .default
        )

        do {
            switch mcpBundle.service {
                case .stdio(let command, let environment):
                    try await connectStdioAction(
                        actionID: actionID,
                        client: client,
                        command: command,
                        environment: environment
                    )
                case .http(let url, _, let headers, _):
                    let transportConfiguration = URLSessionConfiguration.default
                    let authorizer = await authorizerProvider?(actionID, url)
                    // When an authorizer owns the bearer it injects the
                    // `Authorization` header itself (before requestModifier runs),
                    // so the static-header modifier must not re-set it.
                    let sanitizedHeaders = await injectedHTTPHeaders(
                        actionID: actionID,
                        bundleHeaders: headers,
                        excludingAuthorization: authorizer != nil
                    )

                    let transport = HTTPClientTransport(
                        endpoint: url,
                        configuration: transportConfiguration,
                        streaming: true,
                        authorizer: authorizer,
                        requestModifier: { request in
                            var modifiedRequest = request
                            for (key, value) in sanitizedHeaders {
                                modifiedRequest.setValue(
                                    value,
                                    forHTTPHeaderField: key
                                )
                            }
                            return modifiedRequest
                        }
                    )
                    try await Self.connectClient(
                        client,
                        transport: IncrementingRequestIDTransport(base: transport),
                        timeoutSeconds: interactiveConnectTimeoutSeconds
                    )
            }
        } catch {
            // Surface the failure so node-status sync can advertise the
            // action as `.failed(reason:)` instead of silently going dark.
            healthByActionID[actionID] = .failed(reason: Self.failureReason(error))
            throw error
        }

        await registerToolListChangeHandler(
            actionID: actionID,
            client: client
        )
        clientsByActionID[actionID] = client

        // Cache initial tool list eagerly so node-status broadcasts can
        // include `tools` without paying a network round-trip per build.
        // Failure here downgrades to `.connected(tools: [])` rather than
        // `.failed` — the connection itself is up.
        let initialTools = (try? await client.listTools().tools.map(\.name).sorted()) ?? []
        healthByActionID[actionID] = .connected(tools: initialTools)
    }

    private static func failureReason(_ error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
            !localized.isEmpty
        {
            return localized
        }
        return error.localizedDescription
    }

    private func registerToolListChangeHandler(
        actionID: UUID,
        client: Client
    ) async {
        await client.onNotification(ToolListChangedNotification.self) {
            [weak self] _ in
            await self?.notifyActionToolsChanged(actionID: actionID)
        }
    }

    private func notifyActionToolsChanged(actionID: UUID) async {
        guard let client = clientsByActionID[actionID] else {
            return
        }
        // Refresh the cached tool list so health stays consistent with what
        // node-status will advertise on the next broadcast.
        if let refreshed = try? await client.listTools().tools.map(\.name).sorted() {
            healthByActionID[actionID] = .connected(tools: refreshed)
        }
        guard let onActionToolsChanged else {
            return
        }
        await onActionToolsChanged(actionID)
    }

    /// Performs any required HTTP authentication flow ahead of tool invocation.
    public func preflightHTTPAuthentication(action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        guard case .mcpBundle(let bundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard case .http(let endpoint, _, let headers, _) = bundle.service else {
            return
        }

        try await registerMCPAction(action)

        let authorizer = await authorizerProvider?(actionID, endpoint)
        try await preflightHTTPAuthenticationViaMCP(
            actionID: actionID,
            endpoint: endpoint,
            headers: await injectedHTTPHeaders(
                actionID: actionID,
                bundleHeaders: headers,
                excludingAuthorization: authorizer != nil
            ),
            authorizer: authorizer
        )
    }

    /// Resolves the request headers for an HTTP MCP action by overlaying the
    /// keychain-stored credential headers (bearer tokens, API keys) onto any
    /// headers still carried in the bundle. Credentials take precedence; in the
    /// post-refactor model the bundle headers are empty and this is purely the
    /// stored set.
    private func injectedHTTPHeaders(
        actionID: UUID,
        bundleHeaders: [String: String],
        excludingAuthorization: Bool = false
    ) async -> [String: String] {
        var headers = Self.sanitizedHTTPHeaders(bundleHeaders)
        if let credentialStore,
            let credentials = try? await credentialStore.load(actionID: actionID)
        {
            for (key, value) in Self.sanitizedHTTPHeaders(credentials.headers) {
                headers[key] = value
            }
        }
        if excludingAuthorization {
            for key in headers.keys
            where key.caseInsensitiveCompare("Authorization") == .orderedSame {
                headers.removeValue(forKey: key)
            }
        }
        return headers
    }

    private func terminateStdioProcess(for actionID: UUID) {
        guard let handle = stdioProcessesByActionID.removeValue(forKey: actionID) else {
            return
        }
        handle.processHandler.terminate()
    }

    private func log(_ message: String) {
        onLog?("\(message)")
    }

    private func logStdioStderr(actionID: UUID, data: Data) {
        guard !data.isEmpty else {
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let actionIDLabel = actionID.uuidString.lowercased()
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            log("[ACT/mcp/stderr] action=\(actionIDLabel) \(line)")
        }
    }

    private func preflightHTTPAuthenticationViaMCP(
        actionID: UUID,
        endpoint: URL,
        headers: [String: String],
        authorizer: (any HTTPClientAuthorizer)? = nil
    ) async throws {
        let client = Client(
            name: "KeepTalking:preflight:\(nodeConfig.node.uuidString):\(actionID.uuidString)",
            version: "1.0.0",
            title: "KeepTalking",
            capabilities: .init(
                elicitation: .init(form: nil, url: .init())
            ),
            configuration: .default
        )

        let transport = HTTPClientTransport(
            endpoint: endpoint,
            configuration: .default,
            streaming: true,
            authorizer: authorizer,
            requestModifier: { request in
                var modifiedRequest = request
                for (key, value) in headers {
                    modifiedRequest.setValue(value, forHTTPHeaderField: key)
                }
                return modifiedRequest
            }
        )

        do {
            try await Self.connectClient(
                client,
                transport: IncrementingRequestIDTransport(base: transport),
                timeoutSeconds: connectTimeoutSeconds
            )
            _ = try await client.listTools()
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func isVirtualRemoteAction(_ action: KeepTalkingAction) -> Bool {
        guard let ownerNodeID = action.$node.id else {
            return false
        }
        return ownerNodeID != nodeConfig.node
    }

    private func virtualToolNames(for action: KeepTalkingAction) -> [String] {
        guard let actionID = action.id else {
            return []
        }
        guard case .mcpBundle(let bundle) = action.payload else {
            return []
        }
        if let cached = bundle.cachedTools, !cached.isEmpty {
            return cached.sorted()
        }
        let trimmed = bundle.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let baseName = trimmed.isEmpty ? "remote_action" : trimmed
        let suffix = String(
            actionID.uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(8)
        )
        return ["\(baseName)__\(suffix)"]
    }

    private static func sanitizedHTTPHeaders(
        _ rawHeaders: [String: String]
    ) -> [String: String] {
        var headers: [String: String] = [:]
        headers.reserveCapacity(rawHeaders.count)
        for (rawKey, rawValue) in rawHeaders {
            let key = rawKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !key.isEmpty else {
                continue
            }
            headers[key] = rawValue
        }
        return headers
    }
}
