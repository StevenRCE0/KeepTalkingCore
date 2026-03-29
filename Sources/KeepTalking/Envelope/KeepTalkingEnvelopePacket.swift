import Foundation

public struct KeepTalkingEnvelopePacket: Codable, Sendable {
    public let envelope: any KeepTalkingEnvelope

    enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(_ envelope: any KeepTalkingEnvelope) {
        self.envelope = envelope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(
            KeepTalkingEnvelopeKind.self,
            forKey: .kind
        )
        envelope = try Self.decodeEnvelope(kind: kind, from: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(envelope.kind, forKey: .kind)

        switch envelope.kind {
            case .message:
                try container.encode(
                    try cast(KeepTalkingContextMessage.self),
                    forKey: .payload
                )
            case .attachment:
                try container.encode(
                    try cast(KeepTalkingContextAttachmentDTO.self),
                    forKey: .payload
                )
            case .context:
                try container.encode(
                    try cast(KeepTalkingContext.self),
                    forKey: .payload
                )
            case .node:
                try container.encode(
                    try cast(KeepTalkingNode.self),
                    forKey: .payload
                )
            case .nodeStatus:
                try container.encode(
                    try cast(KeepTalkingNodeStatus.self),
                    forKey: .payload
                )
            case .encryptedNodeStatus:
                try container.encode(
                    try cast(KeepTalkingEncryptedNodeStatusEnvelope.self),
                    forKey: .payload
                )
            case .contextSync:
                try container.encode(
                    try cast(KeepTalkingContextSyncEnvelope.self),
                    forKey: .payload
                )
            case .actionCallRequest:
                try container.encode(
                    try cast(KeepTalkingActionCallRequest.self),
                    forKey: .payload
                )
            case .requestAck:
                try container.encode(
                    try cast(KeepTalkingRequestAck.self),
                    forKey: .payload
                )
            case .actionCallResult:
                try container.encode(
                    try cast(KeepTalkingActionCallResult.self),
                    forKey: .payload
                )
            case .encryptedActionCallRequest:
                try container.encode(
                    try cast(KeepTalkingEncryptedActionCallRequestEnvelope.self),
                    forKey: .payload
                )
            case .encryptedRequestAck:
                try container.encode(
                    try cast(KeepTalkingEncryptedRequestAckEnvelope.self),
                    forKey: .payload
                )
            case .encryptedActionCallResult:
                try container.encode(
                    try cast(KeepTalkingEncryptedActionCallResultEnvelope.self),
                    forKey: .payload
                )
            case .actionCatalogRequest:
                try container.encode(
                    try cast(KeepTalkingActionCatalogRequest.self),
                    forKey: .payload
                )
            case .actionCatalogResult:
                try container.encode(
                    try cast(KeepTalkingActionCatalogResult.self),
                    forKey: .payload
                )
            case .encryptedActionCatalogRequest:
                try container.encode(
                    try cast(KeepTalkingEncryptedActionCatalogRequestEnvelope.self),
                    forKey: .payload
                )
            case .encryptedActionCatalogResult:
                try container.encode(
                    try cast(KeepTalkingEncryptedActionCatalogResultEnvelope.self),
                    forKey: .payload
                )
            case .p2pSignal:
                try container.encode(
                    try cast(KeepTalkingP2PSignalPayload.self),
                    forKey: .payload
                )
            case .p2pPresence:
                try container.encode(
                    try cast(KeepTalkingP2PPresencePayload.self),
                    forKey: .payload
                )
        }
    }

    private func cast<Envelope: KeepTalkingEnvelope>(
        _ type: Envelope.Type
    ) throws -> Envelope {
        guard let envelope = envelope as? Envelope else {
            throw DecodingError.typeMismatch(
                type,
                .init(
                    codingPath: [],
                    debugDescription: "Envelope kind \(self.envelope.kind.rawValue) did not match \(type)."
                )
            )
        }
        return envelope
    }

    private static func decodeEnvelope(
        kind: KeepTalkingEnvelopeKind,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> any KeepTalkingEnvelope {
        switch kind {
            case .message:
                return try container.decode(
                    KeepTalkingContextMessage.self,
                    forKey: .payload
                )
            case .attachment:
                return try container.decode(
                    KeepTalkingContextAttachmentDTO.self,
                    forKey: .payload
                )
            case .context:
                return try container.decode(
                    KeepTalkingContext.self,
                    forKey: .payload
                )
            case .node:
                return try container.decode(
                    KeepTalkingNode.self,
                    forKey: .payload
                )
            case .nodeStatus:
                return try container.decode(
                    KeepTalkingNodeStatus.self,
                    forKey: .payload
                )
            case .encryptedNodeStatus:
                return try container.decode(
                    KeepTalkingEncryptedNodeStatusEnvelope.self,
                    forKey: .payload
                )
            case .contextSync:
                return try container.decode(
                    KeepTalkingContextSyncEnvelope.self,
                    forKey: .payload
                )
            case .actionCallRequest:
                return try container.decode(
                    KeepTalkingActionCallRequest.self,
                    forKey: .payload
                )
            case .requestAck:
                return try container.decode(
                    KeepTalkingRequestAck.self,
                    forKey: .payload
                )
            case .actionCallResult:
                return try container.decode(
                    KeepTalkingActionCallResult.self,
                    forKey: .payload
                )
            case .encryptedActionCallRequest:
                return try container.decode(
                    KeepTalkingEncryptedActionCallRequestEnvelope.self,
                    forKey: .payload
                )
            case .encryptedRequestAck:
                return try container.decode(
                    KeepTalkingEncryptedRequestAckEnvelope.self,
                    forKey: .payload
                )
            case .encryptedActionCallResult:
                return try container.decode(
                    KeepTalkingEncryptedActionCallResultEnvelope.self,
                    forKey: .payload
                )
            case .actionCatalogRequest:
                return try container.decode(
                    KeepTalkingActionCatalogRequest.self,
                    forKey: .payload
                )
            case .actionCatalogResult:
                return try container.decode(
                    KeepTalkingActionCatalogResult.self,
                    forKey: .payload
                )
            case .encryptedActionCatalogRequest:
                return try container.decode(
                    KeepTalkingEncryptedActionCatalogRequestEnvelope.self,
                    forKey: .payload
                )
            case .encryptedActionCatalogResult:
                return try container.decode(
                    KeepTalkingEncryptedActionCatalogResultEnvelope.self,
                    forKey: .payload
                )
            case .p2pSignal:
                return try container.decode(
                    KeepTalkingP2PSignalPayload.self,
                    forKey: .payload
                )
            case .p2pPresence:
                return try container.decode(
                    KeepTalkingP2PPresencePayload.self,
                    forKey: .payload
                )
        }
    }
}
