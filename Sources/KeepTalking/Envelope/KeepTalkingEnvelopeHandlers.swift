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
    private var handlers: [KeepTalkingEnvelopeKind: @Sendable (any KeepTalkingEnvelope) async throws -> Bool] =
        [:]

    public init() {}

    public mutating func register<Envelope: KeepTalkingEnvelope>(
        _ envelopeType: Envelope.Type,
        _ handler: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        handlers[Envelope.kind] = { envelope in
            guard let typedEnvelope = envelope as? Envelope else {
                return true
            }
            try await handler(typedEnvelope)
            return true
        }
    }

    /// Register a handler that reports whether the envelope actually changed
    /// anything locally.
    ///
    /// Fan-out can deliver the same envelope over both a direct channel and the
    /// SFU, so redelivery is routine now rather than exceptional. Persistence
    /// already drops the duplicate by row id — but the outward `onEnvelope`
    /// publish would still fire twice, and the app turns that into a second
    /// user-facing notification. Kinds that can no-op report `false` so the
    /// publish is suppressed.
    public mutating func registerReportingApplied<Envelope: KeepTalkingEnvelope>(
        _ envelopeType: Envelope.Type,
        _ handler: @escaping @Sendable (Envelope) async throws -> Bool
    ) {
        handlers[Envelope.kind] = { envelope in
            guard let typedEnvelope = envelope as? Envelope else {
                return true
            }
            return try await handler(typedEnvelope)
        }
    }

    /// Returns whether the envelope should be published onward. Kinds with no
    /// registered handler always publish.
    @discardableResult
    public func handle(_ envelope: any KeepTalkingEnvelope) async throws -> Bool {
        guard let handler = handlers[envelope.kind] else { return true }
        return try await handler(envelope)
    }
}
