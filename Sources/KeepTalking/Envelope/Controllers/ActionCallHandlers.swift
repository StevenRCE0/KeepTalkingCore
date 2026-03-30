//
//  ActionCallHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerActionCallHandlers(for client: KeepTalkingClient) {
        onActionCallRequest { request in
            client.enqueueIncomingActionCallRequest(request)
        }
        onRequestAck { acknowledgement in
            guard acknowledgement.callerNodeID == client.config.node else {
                return
            }
            client.handleIncomingRequestAck(acknowledgement)
        }
        onActionCallResult { result in
            _ = client.resolvePendingActionCall(result)
        }
        onEncryptedActionCallRequest { encryptedRequest in
            let decrypted = try await client.decryptTrustedEnvelope(
                KeepTalkingEncryptedActionCallRequestEnvelope(encryptedRequest)
            )
            guard let request = decrypted.actionCallRequest else {
                return
            }
            client.enqueueIncomingActionCallRequest(request)
        }
        onEncryptedRequestAck { encryptedAcknowledgement in
            let decrypted = try await client.decryptTrustedEnvelope(
                KeepTalkingEncryptedRequestAckEnvelope(encryptedAcknowledgement)
            )
            guard
                let acknowledgement = decrypted.requestAck,
                acknowledgement.callerNodeID == client.config.node
            else {
                return
            }
            client.handleIncomingRequestAck(acknowledgement)
        }
        onEncryptedActionCallResult { encryptedResult in
            let decrypted = try await client.decryptTrustedEnvelope(
                KeepTalkingEncryptedActionCallResultEnvelope(encryptedResult)
            )
            guard let result = decrypted.actionCallResult else {
                return
            }
            _ = client.resolvePendingActionCall(result)
        }
    }
}
