//
//  ContextSyncHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerContextSyncHandlers(for client: KeepTalkingClient) {
        onContextSync { payload in
            try await client.handleIncomingContextSyncEnvelope(payload)
        }
    }
}
