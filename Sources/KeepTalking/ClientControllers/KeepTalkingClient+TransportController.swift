import Foundation

extension KeepTalkingClient {
    /// Sends to the context's room, or to `envelope.targetPeerNodeID` alone.
    /// Throws `KeepTalkingTransportError` when the client isn't connected or
    /// the room can't take it.
    func sendEnvelope(_ envelope: any KeepTalkingEnvelope) throws {
        try connection.send(envelope)
    }

    /// Encrypts `envelope` for its recipient, then sends it.
    func sendTrustedEnvelope(
        _ envelope: any KeepTalkingEnvelope,
        cryptorSource: KeepTalkingTrustedEnvelopeCryptorSource
    ) async throws {
        guard let cryptor = try await cryptorSource(envelope) else {
            throw KeepTalkingTrustedEnvelopeCryptorError.missingCryptor(envelope.kind)
        }
        try sendEnvelope(try await cryptor.encrypt(envelope))
    }

    /// An envelope from the room. Trust handshake kinds go to the handshake,
    /// which runs before the sender is trusted; everything else to the
    /// envelope handlers.
    func handleTransportEnvelope(_ envelope: any KeepTalkingEnvelope) async {
        if envelope.kind.isTrustHandshake {
            await handleIncomingTrustEnvelope(envelope)
            return
        }
        do {
            try await handleIncomingEnvelope(envelope)
        } catch {
            onLog?("[client] failed handling \(envelope.kind.rawValue) envelope error=\(error.localizedDescription)")
        }
    }
}
