import Foundation
import MCP

public enum MCPManagerError: LocalizedError {
    case invalidAction
    case missingActionID
    case unregisteredAction(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidAction:
            return "Action payload is not an MCP bundle."
        case .missingActionID:
            return "Action must have an ID before registration."
        case .unregisteredAction(let actionID):
            return "Action is not registered in MCPManager: \(actionID)"
        }
    }
}

public actor MCPManager {
    private let nodeConfig: KeepTalkingConfig
    private var clientsByActionID: [UUID: Client] = [:]
    private var actionsByID: [UUID: KeepTalkingAction] = [:]

    public init(nodeConfig: KeepTalkingConfig) {
        self.nodeConfig = nodeConfig
    }

    public func registerMCPActions(_ actions: [KeepTalkingAction]) async throws {
        for action in actions {
            try await registerMCPAction(action)
        }
    }

    public func registerMCPAction(_ action: KeepTalkingAction) async throws {
        guard case .mcpBundle(let mcpBundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }

        if clientsByActionID[actionID] != nil {
            actionsByID[actionID] = action
            return
        }

        let client = Client(
            name: "KeepTalking:\(nodeConfig.node.uuidString):\(actionID.uuidString)",
            version: "1.0.0",
            title: "KeepTalking",
            configuration: .default
        )

        switch mcpBundle.service {
        case .stdio:
            // NOTE: This transport currently uses current process stdio.
            let transport = StdioTransport()
            _ = try await client.connect(transport: transport)
        case .http(let url, _, let headers):
            let transportConfiguration = URLSessionConfiguration.default
            transportConfiguration.httpAdditionalHeaders = headers

            let transport = HTTPClientTransport(
                endpoint: url,
                configuration: transportConfiguration,
                streaming: true
            )
            _ = try await client.connect(transport: transport)
        }

        clientsByActionID[actionID] = client
        actionsByID[actionID] = action
    }

    public func refreshMCPAction(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        if let existingClient = clientsByActionID[actionID] {
            await existingClient.disconnect()
            clientsByActionID.removeValue(forKey: actionID)
        }
        actionsByID.removeValue(forKey: actionID)
        try await registerMCPAction(action)
    }

    public func unregisterAction(actionID: UUID) async {
        if let client = clientsByActionID[actionID] {
            await client.disconnect()
        }
        clientsByActionID.removeValue(forKey: actionID)
        actionsByID.removeValue(forKey: actionID)
    }

    public func registerIfNeeded(_ action: KeepTalkingAction) async throws {
        guard let actionID = action.id else {
            throw MCPManagerError.missingActionID
        }
        if clientsByActionID[actionID] == nil {
            try await registerMCPAction(action)
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
        return try await callAction(actionID: actionID, call: call)
    }

    public func callAction(
        actionID: UUID,
        call: KeepTalkingActionCall
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard let action = actionsByID[actionID] else {
            throw MCPManagerError.unregisteredAction(actionID)
        }
        guard case .mcpBundle(let mcpBundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }
        guard let client = clientsByActionID[actionID] else {
            throw MCPManagerError.unregisteredAction(actionID)
        }

        return try await client.callTool(
            name: mcpBundle.name,
            arguments: call.arguments as [String: Value]?,
            meta: call.metadata
        )
    }
}
