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
        case .connectionTimedOut(let timeout):
            return "Timed out while connecting to MCP server after \(Int(timeout))s."
        case .toolCallTimedOut(let actionID, let timeout):
            return "Timed out waiting for MCP tool call action=\(actionID) after \(Int(timeout))s."
        case .stdioProcessExitedEarly(let command, let status):
            return "Stdio MCP process exited early (status=\(status)) for command: \(command.joined(separator: " "))"
        case .unknownMCPTool(let requested, let available):
            let options = available.joined(separator: ", ")
            return "Unknown MCP tool '\(requested)'. Available tools: [\(options)]"
        case .unregisteredAction(let actionID):
            return "Action is not registered in MCPManager: \(actionID)"
        }
    }
}

public actor MCPManager {
    private final class StdioProcessHandle: @unchecked Sendable {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe

        init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
        }
    }

    private let nodeConfig: KeepTalkingConfig
    private let connectTimeoutSeconds: TimeInterval
    private let toolCallTimeoutSeconds: TimeInterval
    private var clientsByActionID: [UUID: Client] = [:]
    private var stdioProcessesByActionID: [UUID: StdioProcessHandle] = [:]
    private var virtualToolNamesByActionID: [UUID: [String]] = [:]

    public init(
        nodeConfig: KeepTalkingConfig,
        connectTimeoutSeconds: TimeInterval = 10,
        toolCallTimeoutSeconds: TimeInterval = 20
    ) {
        self.nodeConfig = nodeConfig
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.toolCallTimeoutSeconds = toolCallTimeoutSeconds
    }

    public func registerMCPActions(_ actions: [KeepTalkingAction]) async throws {
        for action in actions {
            try await registerMCPAction(action)
        }
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

        try await withThrowingTaskGroup(of: Initialize.Result.self) { group in
            group.addTask {
                try await client.connect(transport: transport)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw MCPManagerError.connectionTimedOut(timeoutSeconds)
            }

            guard try await group.next() != nil else {
                throw MCPManagerError.connectionTimedOut(timeoutSeconds)
            }
            group.cancelAll()
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
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment) { _, new in new }
        process.environment = mergedEnvironment

        do {
            try process.run()
        } catch {
            terminateProcessIfRunning(process)
            throw error
        }

        // Parent only writes to child's stdin and reads from child's stdout.
        // Closing opposite ends prevents EOF/delimiter deadlocks if child exits.
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.connectClient(
                        client,
                        transport: transport,
                        timeoutSeconds: self.connectTimeoutSeconds
                    )
                }

                group.addTask {
                    while process.isRunning {
                        if Task.isCancelled { return }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    throw MCPManagerError.stdioProcessExitedEarly(
                        command: command,
                        status: process.terminationStatus
                    )
                }

                guard try await group.next() != nil else {
                    throw MCPManagerError.connectionTimedOut(self.connectTimeoutSeconds)
                }
                group.cancelAll()
            }

            stdioProcessesByActionID[actionID] = StdioProcessHandle(
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe
            )
        } catch {
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
            transportConfiguration.httpAdditionalHeaders = headers

            let transport = HTTPClientTransport(
                endpoint: url,
                configuration: transportConfiguration,
                streaming: true
            )
            try await Self.connectClient(
                client,
                transport: transport,
                timeoutSeconds: connectTimeoutSeconds
            )
        }

        clientsByActionID[actionID] = client
    }

    private func terminateStdioProcess(for actionID: UUID) {
        guard let handle = stdioProcessesByActionID.removeValue(forKey: actionID) else {
            return
        }
        terminateProcessIfRunning(handle.process)
        handle.stdinPipe.fileHandleForWriting.closeFile()
        handle.stdoutPipe.fileHandleForReading.closeFile()
    }

    private func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
    }

    private func isVirtualRemoteAction(_ action: KeepTalkingAction) -> Bool {
        guard let ownerNodeID = action.$node.id else {
            return false
        }
        return ownerNodeID != nodeConfig.node
    }

    private func virtualToolNames(for action: KeepTalkingAction) -> [String] {
        guard case .mcpBundle(let bundle) = action.payload else {
            return []
        }
        let trimmed = bundle.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.isEmpty {
            return ["remote_action"]
        }
        return [trimmed]
    }
}
