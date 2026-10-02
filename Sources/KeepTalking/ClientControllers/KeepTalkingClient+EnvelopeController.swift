import Foundation

extension KeepTalkingClient {
    func handleIncomingEnvelope(_ envelope: any KeepTalkingEnvelope)
        async throws
    {
        var handlers = KeepTalkingEnvelopeAsyncHandlers()
        handlers.registerMessagingHandlers(for: self)
        handlers.registerNodeHandlers(for: self)
        handlers.registerContextSyncHandlers(for: self)
        handlers.registerActionCallHandlers(for: self)
        handlers.registerActionCatalogHandlers(for: self)
        handlers.registerVoiceCallHandlers(for: self)
        handlers.registerBlobTransferHandlers(for: self)
        let applied = try await handlers.handle(envelope)
        // The voice session always sees the envelope: its own handlers do their
        // own duplicate classification, and suppressing here would hide call
        // presence re-announcements it relies on.
        activeVoiceSession?.receiveVoiceEnvelope(envelope)
        // A redelivered envelope that changed nothing locally is not published
        // onward — otherwise a resync's second copy raises a second notification.
        guard applied else { return }
        signals.envelopes.send(envelope)
    }
}
