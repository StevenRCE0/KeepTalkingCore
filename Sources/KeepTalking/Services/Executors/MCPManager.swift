import Foundation
import MCP

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
    case unregisteredAction(UUID)

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
            case .unregisteredAction(let actionID):
                return "Action is not registered in MCPManager: \(actionID)"
        }
    }
}

public enum KeepTalkingMCPHTTPAuthResult: Sendable {
    case completed(callbackURL: URL)
    case cancelled
    case declined
}

/// Manages MCP action registration, transport connections, and tool invocation.
public actor MCPManager {
    private final class StdioProcessHandle: @unchecked Sendable {
        let processHandler: any MCPStdioProcessHandling

        init(processHandler: any MCPStdioProcessHandling) {
            self.processHandler = processHandler
        }
    }

    private let nodeConfig: KeepTalkingConfig
    private let stdioTransportLauncher: (any MCPStdioTransportLaunching)?
    private let connectTimeoutSeconds: TimeInterval
    private let toolCallTimeoutSeconds: TimeInterval
    private var clientsByActionID: [UUID: Client] = [:]
    private var stdioProcessesByActionID: [UUID: StdioProcessHandle] = [:]
    private var virtualToolNamesByActionID: [UUID: [String]] = [:]
    private var onActionToolsChanged: (@Sendable (UUID) async -> Void)?
    private var onLog: (@Sendable (String) -> Void)?
    private var onHTTPAuthURL:
        (@Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult)?

    /// Creates an MCP manager for a node runtime.
    public init(
        nodeConfig: KeepTalkingConfig,
        stdioTransportLauncher: (any MCPStdioTransportLaunching)? =
            DefaultMCPStdioTransportLauncher.current,
        connectTimeoutSeconds: TimeInterval = 10,
        toolCallTimeoutSeconds: TimeInterval = 20
    ) {
        self.nodeConfig = nodeConfig
        self.stdioTransportLauncher = stdioTransportLauncher
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.toolCallTimeoutSeconds = toolCallTimeoutSeconds
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
        } else {
            virtualToolNamesByActionID.removeValue(forKey: actionID)
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
        try await registerMCPAction(action)
    }

    /// Removes an MCP action and tears down any live client state.
    public func unregisterAction(actionID: UUID) async {
        if let client = clientsByActionID[actionID] {
            await client.disconnect()
        }
        terminateStdioProcess(for: actionID)
        clientsByActionID.removeValue(forKey: actionID)
        virtualToolNamesByActionID.removeValue(forKey: actionID)
    }

    /// Ensures an MCP action is registered and connected before use.
    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        try await registerMCPAction(action)
        if virtualToolNamesByActionID[actionID] != nil {
            return
        }
        if clientsByActionID[actionID] == nil {
            try await connectActionClient(actionID: actionID, action: action)
        }
    }

    /// Invokes an MCP tool for the supplied action call.
    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall
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

        return try await Self.callToolWithTimeout(
            client: client,
            name: invocation.name,
            arguments: invocation.arguments as [String: Value]?,
            meta: call.metadata,
            actionID: actionID,
            timeoutSeconds: toolCallTimeoutSeconds
        )
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
        let listing = try await client.listTools()
        return listing.tools.map(\.name).sorted()
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
        let listing = try await client.listTools()
        return listing.tools.sorted { $0.name < $1.name }
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

    private nonisolated static func callToolWithTimeout(
        client: Client,
        name: String,
        arguments: [String: Value]?,
        meta: Metadata,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)

        return try await withThrowingTaskGroup(
            of: (content: [Tool.Content], isError: Bool?).self
        ) { group in
            group.addTask {
                try await client.callTool(
                    name: name,
                    arguments: arguments,
                    meta: meta
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw MCPManagerError.toolCallTimedOut(actionID, timeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw MCPManagerError.toolCallTimedOut(actionID, timeoutSeconds)
            }
            group.cancelAll()
            return result
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

        let actionIDLabel = actionID.uuidString.lowercased()
        log(
            "[mcp][stdio] launch action=\(actionIDLabel) command=\(command.joined(separator: " "))"
        )
        let launched = try await stdioTransportLauncher.launchTransport(
            command: command,
            environment: environment
        ) { [weak self] data in
            Task {
                await self?.logStdioStderr(actionID: actionID, data: data)
            }
        }
        let launchedTransport = launched.transport
        let launchedProcessHandler = launched.processHandler
        log(
            "[mcp][stdio] launched action=\(actionIDLabel)"
        )

        do {
            log(
                "[mcp][stdio] connecting action=\(actionIDLabel) timeout=\(Int(connectTimeoutSeconds))s"
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.connectClient(
                        client,
                        transport: launchedTransport,
                        timeoutSeconds: self.connectTimeoutSeconds
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
                    throw MCPManagerError.connectionTimedOut(self.connectTimeoutSeconds)
                }
                group.cancelAll()
            }
            log("[mcp][stdio] connected action=\(actionIDLabel)")

            stdioProcessesByActionID[actionID] = StdioProcessHandle(
                processHandler: launchedProcessHandler
            )
        } catch {
            log(
                "[mcp][stdio] connect failed action=\(actionIDLabel) error=\(error.localizedDescription)"
            )
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

        let client = Client(
            name: "KeepTalking:\(nodeConfig.node.uuidString):\(actionID.uuidString)",
            version: "1.0.0",
            title: "KeepTalking",
            capabilities: .init(
                elicitation: .init(form: nil, url: .init())
            ),
            configuration: .default
        )

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
                let sanitizedHeaders = Self.sanitizedHTTPHeaders(headers)

                let transport = HTTPClientTransport(
                    endpoint: url,
                    configuration: transportConfiguration,
                    streaming: true,
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
                    transport: transport,
                    timeoutSeconds: connectTimeoutSeconds
                )
        }

        await registerToolListChangeHandler(
            actionID: actionID,
            client: client
        )
        clientsByActionID[actionID] = client
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
        guard clientsByActionID[actionID] != nil else {
            return
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

        try await preflightHTTPAuthenticationViaMCP(
            actionID: actionID,
            endpoint: endpoint,
            headers: Self.sanitizedHTTPHeaders(headers)
        )
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
            log("[mcp][stdio][stderr] action=\(actionIDLabel) \(line)")
        }
    }

    private func preflightHTTPAuthenticationViaMCP(
        actionID: UUID,
        endpoint: URL,
        headers: [String: String]
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
                transport: transport,
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
