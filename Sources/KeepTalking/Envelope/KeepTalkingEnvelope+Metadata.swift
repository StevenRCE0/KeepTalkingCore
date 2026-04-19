import Foundation

extension KeepTalkingEnvelope {
    public var message: KeepTalkingContextMessage? {
        self as? KeepTalkingContextMessage
    }

    public var attachment: KeepTalkingContextAttachmentDTO? {
        self as? KeepTalkingContextAttachmentDTO
    }

    public var context: KeepTalkingContext? {
        self as? KeepTalkingContext
    }

    public var node: KeepTalkingNode? {
        self as? KeepTalkingNode
    }

    public var nodeStatus: KeepTalkingNodeStatus? {
        self as? KeepTalkingNodeStatus
    }

    public var encryptedNodeStatus: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedNodeStatusEnvelope)?.payload
    }

    public var contextSync: KeepTalkingContextSyncEnvelope? {
        self as? KeepTalkingContextSyncEnvelope
    }

    public var actionCallRequest: KeepTalkingActionCallRequest? {
        self as? KeepTalkingActionCallRequest
    }

    public var requestAck: KeepTalkingRequestAck? {
        self as? KeepTalkingRequestAck
    }

    public var actionCallResult: KeepTalkingActionCallResult? {
        self as? KeepTalkingActionCallResult
    }

    public var encryptedActionCallRequest: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedActionCallRequestEnvelope)?.payload
    }

    public var encryptedRequestAck: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedRequestAckEnvelope)?.payload
    }

    public var encryptedActionCallResult: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedActionCallResultEnvelope)?.payload
    }

    public var actionCatalogRequest: KeepTalkingActionCatalogRequest? {
        self as? KeepTalkingActionCatalogRequest
    }

    public var actionCatalogResult: KeepTalkingActionCatalogResult? {
        self as? KeepTalkingActionCatalogResult
    }

    public var encryptedActionCatalogRequest: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedActionCatalogRequestEnvelope)?.payload
    }

    public var encryptedActionCatalogResult: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedActionCatalogResultEnvelope)?.payload
    }

    public var agentTurnContinuationResponse: KeepTalkingAgentTurnContinuationResponse? {
        self as? KeepTalkingAgentTurnContinuationResponse
    }

    public var encryptedAgentTurnContinuationResponse: KeepTalkingAsymmetricCipherEnvelope? {
        (self as? KeepTalkingEncryptedAgentTurnContinuationResponseEnvelope)?.payload
    }

    public var p2pSignal: KeepTalkingP2PSignalPayload? {
        self as? KeepTalkingP2PSignalPayload
    }

    public var p2pPresence: KeepTalkingP2PPresencePayload? {
        self as? KeepTalkingP2PPresencePayload
    }
}
