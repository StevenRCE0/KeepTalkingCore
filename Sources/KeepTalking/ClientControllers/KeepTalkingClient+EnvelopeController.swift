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
        try await handlers.handle(envelope)
        onEnvelope?(envelope)
    }
}
