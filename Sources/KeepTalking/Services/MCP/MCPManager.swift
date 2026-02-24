//
//  MCPManager.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/02/2026.
//

import Foundation
import MCP

public enum MCPManagerError: Error {
    case invalidAction
}

public actor MCPManager {
    public let client: Client

    public init(nodeConfig: KeepTalkingConfig) {
        self.client = Client(
            name: "KeepTalking:\(nodeConfig.node.uuidString)",
            version: "1.0.0",
            title: "KeepTalking",
            configuration: .default
        )
    }

    public func registerMCPActions(_ actions: [KeepTalkingAction]) async throws
    {
        let client = self.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for action in actions {
                group.addTask {
                    if case .mcpBundle(let mcpBundle) = action.payload {
                        switch mcpBundle.service {
                        case .stdio(_):
                            let transport = StdioTransport()
                            _ = try await client.connect(
                                transport: transport
                            )
                        case .http(let url, _, let headers):
                            let transportConfiguration = URLSessionConfiguration
                                .default
                            transportConfiguration.httpAdditionalHeaders =
                                headers

                            let transport = HTTPClientTransport(
                                endpoint: url,
                                configuration: transportConfiguration,
                                streaming: true
                            )
                            _ = try await client.connect(
                                transport: transport
                            )
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    public func callAction(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard case .mcpBundle(let mcpBundle) = action.payload else {
            throw MCPManagerError.invalidAction
        }

        return
            try await client
            .callTool(
                name: mcpBundle.name,
                arguments: call.arguments as [String: Value]?,
                meta: call.metadata
            )
    }
}
