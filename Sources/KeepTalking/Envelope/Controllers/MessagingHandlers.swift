//
//  RegisterMessagingHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerMessagingHandlers(for client: KeepTalkingClient) {
        onMessage { message in
            try await client.handleIncomingMessage(message)
            client.rtcClient.debug("Message cast to envelope")
        }
        onAttachment { attachment in
            try await client.handleIncomingAttachment(attachment)
        }
        onContext { context in
            client.mergeContext(context)
        }
    }
}
