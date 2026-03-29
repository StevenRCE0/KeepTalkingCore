import Foundation

extension KeepTalkingContextAttachmentDTO: KeepTalkingEnvelope {
    public static var kind: KeepTalkingEnvelopeKind { .attachment }

    public var transportContextID: UUID? {
        contextID
    }
}

extension KeepTalkingEnvelopeHandlers {
    public mutating func onAttachment(
        _ handler: @escaping @Sendable (KeepTalkingContextAttachmentDTO) -> Void
    ) {
        register(KeepTalkingContextAttachmentDTO.self, handler)
    }
}

extension KeepTalkingEnvelopeAsyncHandlers {
    public mutating func onAttachment(
        _ handler: @escaping @Sendable (KeepTalkingContextAttachmentDTO) async throws -> Void
    ) {
        register(KeepTalkingContextAttachmentDTO.self, handler)
    }
}
