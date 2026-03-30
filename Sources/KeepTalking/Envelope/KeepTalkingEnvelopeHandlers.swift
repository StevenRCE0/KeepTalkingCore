import Foundation

public struct KeepTalkingEnvelopeHandlers: Sendable {
    private var handlers: [KeepTalkingEnvelopeKind: @Sendable (any KeepTalkingEnvelope) -> Void] = [:]

    public init() {}

    public mutating func register<Envelope: KeepTalkingEnvelope>(
        _ envelopeType: Envelope.Type,
        _ handler: @escaping @Sendable (Envelope) -> Void
    ) {
        handlers[Envelope.kind] = { envelope in
            guard let typedEnvelope = envelope as? Envelope else {
                return
            }
            handler(typedEnvelope)
        }
    }

    public func handle(_ envelope: any KeepTalkingEnvelope) {
        handlers[envelope.kind]?(envelope)
    }
}

public struct KeepTalkingEnvelopeAsyncHandlers: Sendable {
    private var handlers: [KeepTalkingEnvelopeKind: @Sendable (any KeepTalkingEnvelope) async throws -> Void] = [:]

    public init() {}

    public mutating func register<Envelope: KeepTalkingEnvelope>(
        _ envelopeType: Envelope.Type,
        _ handler: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        handlers[Envelope.kind] = { envelope in
            guard let typedEnvelope = envelope as? Envelope else {
                return
            }
            try await handler(typedEnvelope)
        }
    }

    public func handle(_ envelope: any KeepTalkingEnvelope) async throws {
        try await handlers[envelope.kind]?(envelope)
    }
}
