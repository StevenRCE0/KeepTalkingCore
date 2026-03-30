//
//  ActionCatalogHandlers.swift
//  KeepTalking
//
//  Created by 砚渤 on 29/03/2026.
//

import Foundation

extension KeepTalkingEnvelopeAsyncHandlers {
    mutating func registerActionCatalogHandlers(for client: KeepTalkingClient) {
        onActionCatalogRequest { request in
            client.enqueueIncomingActionCatalogRequest(request)
        }
        onActionCatalogResult { result in
            _ = client.resolvePendingActionCatalogResult(result)
        }
        onEncryptedActionCatalogRequest { encryptedRequest in
            let decrypted = try await client.decryptTrustedEnvelope(
                KeepTalkingEncryptedActionCatalogRequestEnvelope(encryptedRequest)
            )
            guard let request = decrypted.actionCatalogRequest else {
                return
            }
            client.enqueueIncomingActionCatalogRequest(request)
        }
        onEncryptedActionCatalogResult { encryptedResult in
            let decrypted = try await client.decryptTrustedEnvelope(
                KeepTalkingEncryptedActionCatalogResultEnvelope(encryptedResult)
            )
            guard let result = decrypted.actionCatalogResult else {
                return
            }
            _ = client.resolvePendingActionCatalogResult(result)
        }
    }
}
