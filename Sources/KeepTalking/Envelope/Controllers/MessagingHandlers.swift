//
//  RegisterMessagingHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerMessagingHandlers(for client: KeepTalkingClient) {
        onMessage { (message: KeepTalkingContextMessage) async throws -> Bool in
            let applied = try await client.handleIncomingMessage(message)
            client.rtcClient.debug("Message cast to envelope")
            return applied
        }
        onAttachment {
            (attachment: KeepTalkingContextAttachmentDTO) async throws -> Bool in
            try await client.handleIncomingAttachment(attachment)
        }
    }
}
