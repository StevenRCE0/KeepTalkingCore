//
//  NodeHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerNodeHandlers(for client: KeepTalkingClient) {
        onNode { node in
            try await client.mergeDiscoveredNode(node)
        }
        onNodeStatus { status in
            try await client.mergeDiscoveredNodeStatus(status)
        }
        onEncryptedNodeStatus { payload in
            guard payload.recipientNodeID == client.config.node else {
                return
            }
            let status = try await client.decryptNodeStatusEnvelope(payload)
            try await client.mergeDiscoveredNodeStatus(status)
        }
        onP2PPresence { presence in
            guard presence.node != client.config.node else {
                return
            }
            try await client.handleIncomingP2PPresence(presence)
        }
    }
}
