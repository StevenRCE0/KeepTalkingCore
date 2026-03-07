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

public actor MCPManager {
    private final class StdioProcessHandle: @unchecked Sendable {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe

        init(
            process: Process,
            stdinPipe: Pipe,
            stdoutPipe: Pipe,
            stderrPipe: Pipe
        ) {
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }
    }

    private final class ProcessExitState: @unchecked Sendable {
        private let lock = NSLock()
        private var terminated = false
        private var status: Int32 = 0

        func setTerminated(status: Int32) {
            lock.lock()
            terminated = true
            self.status = status
            lock.unlock()
        }

        func snapshot() -> (terminated: Bool, status: Int32) {
            lock.lock()
            let result = (terminated, status)
            lock.unlock()
            return result
        }
    }

    private let nodeConfig: KeepTalkingConfig
    private let connectTimeoutSeconds: TimeInterval
    private let toolCallTimeoutSeconds: TimeInterval
    private var clientsByActionID: [UUID: Client] = [:]
    private var stdioProcessesByActionID: [UUID: StdioProcessHandle] = [:]
    private var virtualToolNamesByActionID: [UUID: [String]] = [:]
    private var onActionToolsChanged: (@Sendable (UUID) async -> Void)?
    private var onLog: (@Sendable (String) -> Void)?
    private var onHTTPAuthURL:
        (@Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult)?

    public init(
        nodeConfig: KeepTalkingConfig,
        connectTimeoutSeconds: TimeInterval = 10,
        toolCallTimeoutSeconds: TimeInterval = 20
    ) {
        self.nodeConfig = nodeConfig
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.toolCallTimeoutSeconds = toolCallTimeoutSeconds
    }

    public func setActionToolsChangedHandler(
        _ handler: (@Sendable (UUID) async -> Void)?
    ) {
        onActionToolsChanged = handler
    }

    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        onLog = handler
    }

    public func setHTTPAuthURLHandler(
        _ handler: (@Sendable (UUID, URL, String) async -> KeepTalkingMCPHTTPAuthResult)?
    ) {
        onHTTPAuthURL = handler
    }

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

    public func unregisterAction(actionID: UUID) async {
        if let client = clientsByActionID[actionID] {
            await client.disconnect()
        }
        terminateStdioProcess(for: actionID)
        clientsByActionID.removeValue(forKey: actionID)
        virtualToolNamesByActionID.removeValue(forKey: actionID)
    }

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

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let exitState = ProcessExitState()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let actionIDLabel = actionID.uuidString.lowercased()
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment) { _, new in new }
        mergedEnvironment["PATH"] = Self.resolvePathEnvironment(
            command: command,
            environment: mergedEnvironment
        )
        mergedEnvironment["TMPDIR"] = Self.resolveWritableTempDirectory(
            environment: mergedEnvironment
        )
        if mergedEnvironment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        {
            mergedEnvironment["HOME"] = NSHomeDirectory()
        }
        process.environment = mergedEnvironment
        log(
            "[mcp][stdio] env action=\(actionIDLabel) path=\(mergedEnvironment["PATH"] ?? "<unset>") tmpdir=\(mergedEnvironment["TMPDIR"] ?? "<unset>") home=\(mergedEnvironment["HOME"] ?? "<unset>")"
        )
        log(
            "[mcp][stdio] launch action=\(actionIDLabel) command=\(command.joined(separator: " "))"
        )
        process.terminationHandler = { [weak self] process in
            let reason: String = switch process.terminationReason {
                case .exit:
                    "exit"
                case .uncaughtSignal:
                    "signal"
                @unknown default:
                    "unknown"
            }
            exitState.setTerminated(status: process.terminationStatus)
            Task {
                await self?.log(
                    "[mcp][stdio] exited action=\(actionIDLabel) status=\(process.terminationStatus) reason=\(reason)"
                )
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await self?.logStdioStderr(actionID: actionID, data: data)
            }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            terminateProcessIfRunning(process)
            throw error
        }
        log(
            "[mcp][stdio] launched action=\(actionIDLabel) pid=\(process.processIdentifier)"
        )

        // Parent only writes to child's stdin and reads from child's stdout.
        // Closing opposite ends prevents EOF/delimiter deadlocks if child exits.
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )

        do {
            log(
                "[mcp][stdio] connecting action=\(actionIDLabel) timeout=\(Int(connectTimeoutSeconds))s"
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.connectClient(
                        client,
                        transport: transport,
                        timeoutSeconds: self.connectTimeoutSeconds
                    )
                }

                group.addTask {
                    while true {
                        if Task.isCancelled { return }
                        let state = exitState.snapshot()
                        if state.terminated {
                            throw MCPManagerError.stdioProcessExitedEarly(
                                command: command,
                                status: state.status
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
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch {
            log(
                "[mcp][stdio] connect failed action=\(actionIDLabel) error=\(error.localizedDescription)"
            )
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            terminateProcessIfRunning(process)
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
            case .http(let url, _, let headers):
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

    public func preflightHTTPAuthentication(action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        guard case .mcpBundle(let bundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard case .http(let endpoint, _, let headers) = bundle.service else {
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
        terminateProcessIfRunning(handle.process)
        handle.stdinPipe.fileHandleForWriting.closeFile()
        handle.stdoutPipe.fileHandleForReading.closeFile()
        handle.stderrPipe.fileHandleForReading.readabilityHandler = nil
        handle.stderrPipe.fileHandleForReading.closeFile()
    }

    private func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
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

    private static func resolveWritableTempDirectory(
        environment: [String: String]
    ) -> String {
        let fileManager = FileManager.default
        let fallback = "/tmp"
        let candidates = [
            environment["TMPDIR"],
            ProcessInfo.processInfo.environment["TMPDIR"],
            NSTemporaryDirectory(),
            fallback,
        ]
        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                fileManager.isWritableFile(atPath: path)
            else {
                continue
            }
            return path
        }
        return fallback
    }

    private static func resolvePathEnvironment(
        command: [String],
        environment: [String: String]
    ) -> String {
        var components = (
            environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for candidate in defaults where !components.contains(candidate) {
            components.append(candidate)
        }

        if let executable = command.first,
            executable.hasPrefix("/")
        {
            let executableDirectory = URL(fileURLWithPath: executable)
                .deletingLastPathComponent().path
            if !executableDirectory.isEmpty,
                !components.contains(executableDirectory)
            {
                components.insert(executableDirectory, at: 0)
            }
        }

        if components.isEmpty {
            return defaults.joined(separator: ":")
        }
        return components.joined(separator: ":")
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
