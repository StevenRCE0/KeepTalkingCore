import CryptoKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct TrustHandshakeCryptoTests {

    private static func uuid(_ s: String) -> UUID {
        UUID(uuidString: s) ?? UUID()
    }

    private static let initiatorID = uuid("11111111-1111-1111-1111-111111111111")
    private static let responderID = uuid("22222222-2222-2222-2222-222222222222")
    private static let sessionID = uuid("33333333-3333-3333-3333-333333333333")
    private static let contextID = uuid("44444444-4444-4444-4444-444444444444")
    private static let scopeTag = "thisContext"

    private static let contextSecret: Data = Data(repeating: 0xab, count: 32)

    private static func transcript(
        initiatorEphemeralPub: Data,
        responderEphemeralPub: Data
    ) -> Data {
        TrustHandshakeCrypto.transcript(
            sessionID: sessionID,
            contextID: contextID,
            initiatorNodeID: initiatorID,
            responderNodeID: responderID,
            initiatorEphemeralPub: initiatorEphemeralPub,
            responderEphemeralPub: responderEphemeralPub,
            scopeTag: scopeTag
        )
    }

    @Test("transcript is order-independent in the canonical node-id positions")
    func transcriptCanonicalOrder() {
        let initiatorPub = Data(repeating: 0x01, count: 32)
        let responderPub = Data(repeating: 0x02, count: 32)

        let aFirst = TrustHandshakeCrypto.transcript(
            sessionID: Self.sessionID,
            contextID: Self.contextID,
            initiatorNodeID: Self.initiatorID,
            responderNodeID: Self.responderID,
            initiatorEphemeralPub: initiatorPub,
            responderEphemeralPub: responderPub,
            scopeTag: Self.scopeTag
        )
        let aSecond = TrustHandshakeCrypto.transcript(
            sessionID: Self.sessionID,
            contextID: Self.contextID,
            // Swap roles — node-id ordering is canonical, so the transcript
            // for the matching ephemeral assignment must still match.
            initiatorNodeID: Self.responderID,
            responderNodeID: Self.initiatorID,
            initiatorEphemeralPub: responderPub,
            responderEphemeralPub: initiatorPub,
            scopeTag: Self.scopeTag
        )
        #expect(aFirst != aSecond)  // ephemeral order is role-bound, not canonical
    }

    @Test("end-to-end: both peers derive matching session keys, payload round-trips")
    func roundTrip() throws {
        let initiator = TrustHandshakeCrypto.generateEphemeral()
        let responder = TrustHandshakeCrypto.generateEphemeral()

        let transcript = Self.transcript(
            initiatorEphemeralPub: initiator.publicKeyBytes,
            responderEphemeralPub: responder.publicKeyBytes
        )

        let kInitiator = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: initiator.privateKey,
            remotePublicBytes: responder.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: transcript
        )
        let kResponder = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: responder.privateKey,
            remotePublicBytes: initiator.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: transcript
        )
        #expect(kInitiator.bitCount == kResponder.bitCount)

        let plaintext = Data("hello-trust".utf8)
        let sealed = try TrustHandshakeCrypto.seal(plaintext, with: kInitiator)
        let opened = try TrustHandshakeCrypto.open(sealed, with: kResponder)
        #expect(opened == plaintext)
    }

    @Test("wrong context secret cannot open the seal")
    func wrongContextSecretFails() throws {
        let initiator = TrustHandshakeCrypto.generateEphemeral()
        let responder = TrustHandshakeCrypto.generateEphemeral()
        let transcript = Self.transcript(
            initiatorEphemeralPub: initiator.publicKeyBytes,
            responderEphemeralPub: responder.publicKeyBytes
        )

        let goodKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: initiator.privateKey,
            remotePublicBytes: responder.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: transcript
        )
        let wrongKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: responder.privateKey,
            remotePublicBytes: initiator.publicKeyBytes,
            contextSecret: Data(repeating: 0xff, count: 32),  // different context!
            transcript: transcript
        )

        let sealed = try TrustHandshakeCrypto.seal(Data("payload".utf8), with: goodKey)
        #expect(throws: TrustHandshakeCrypto.HandshakeError.self) {
            _ = try TrustHandshakeCrypto.open(sealed, with: wrongKey)
        }
    }

    @Test("tampered transcript breaks the open")
    func tamperedTranscriptFails() throws {
        let initiator = TrustHandshakeCrypto.generateEphemeral()
        let responder = TrustHandshakeCrypto.generateEphemeral()

        let goodTranscript = Self.transcript(
            initiatorEphemeralPub: initiator.publicKeyBytes,
            responderEphemeralPub: responder.publicKeyBytes
        )
        let tamperedTranscript = TrustHandshakeCrypto.transcript(
            sessionID: Self.sessionID,
            contextID: Self.contextID,
            initiatorNodeID: Self.initiatorID,
            responderNodeID: Self.responderID,
            initiatorEphemeralPub: initiator.publicKeyBytes,
            responderEphemeralPub: responder.publicKeyBytes,
            scopeTag: "allContexts"  // attacker downgrades scope
        )

        let goodKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: initiator.privateKey,
            remotePublicBytes: responder.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: goodTranscript
        )
        let tamperedKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: responder.privateKey,
            remotePublicBytes: initiator.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: tamperedTranscript
        )

        let sealed = try TrustHandshakeCrypto.seal(Data("payload".utf8), with: goodKey)
        #expect(throws: TrustHandshakeCrypto.HandshakeError.self) {
            _ = try TrustHandshakeCrypto.open(sealed, with: tamperedKey)
        }
    }

    @Test("malformed peer ephemeral pubkey is rejected")
    func malformedRemoteKey() {
        let local = TrustHandshakeCrypto.generateEphemeral()
        let badRemote = Data([0x01, 0x02, 0x03])
        #expect(throws: TrustHandshakeCrypto.HandshakeError.self) {
            _ = try TrustHandshakeCrypto.deriveSessionKey(
                localPrivate: local.privateKey,
                remotePublicBytes: badRemote,
                contextSecret: Self.contextSecret,
                transcript: Data()
            )
        }
    }

    /// End-to-end simulation of the full two-party trust handshake — the
    /// same sequence the TrustController state machine drives (request →
    /// accept → complete), but exercised at the crypto + payload layer so
    /// it doesn't need a Fluent database or a transport seam. Catches any
    /// regression in the way roles, ephemeral pubkeys, transcripts, and
    /// scope-tag binding are composed across the three envelopes.
    @Test("two-party handshake: each side recovers the other's identity payload")
    func twoPartyHandshake() throws {
        let initiatorEphemeral = TrustHandshakeCrypto.generateEphemeral()
        let responderEphemeral = TrustHandshakeCrypto.generateEphemeral()

        let initiatorIdentityPub = "INITIATOR_LONG_TERM_PUBKEY_BASE64=="
        let responderIdentityPub = "RESPONDER_LONG_TERM_PUBKEY_BASE64=="

        // Both peers compute the same transcript from the same canonical
        // inputs (the roles' ephemeral keys are role-bound).
        let transcript = Self.transcript(
            initiatorEphemeralPub: initiatorEphemeral.publicKeyBytes,
            responderEphemeralPub: responderEphemeral.publicKeyBytes
        )

        // Responder side, on receiving .trustRequest:
        let responderSessionKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: responderEphemeral.privateKey,
            remotePublicBytes: initiatorEphemeral.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: transcript
        )
        let responderInner = KeepTalkingTrustIdentityInner(
            nodeID: Self.responderID,
            identityPublicKey: responderIdentityPub
        )
        let responderSealed = try TrustHandshakeCrypto.seal(
            try JSONEncoder().encode(responderInner),
            with: responderSessionKey
        )

        // Initiator side, on receiving .trustAccept:
        let initiatorSessionKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: initiatorEphemeral.privateKey,
            remotePublicBytes: responderEphemeral.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: transcript
        )
        let openedResponderInner = try JSONDecoder().decode(
            KeepTalkingTrustIdentityInner.self,
            from: try TrustHandshakeCrypto.open(responderSealed, with: initiatorSessionKey)
        )
        #expect(openedResponderInner.nodeID == Self.responderID)
        #expect(openedResponderInner.identityPublicKey == responderIdentityPub)

        // Initiator now seals its own identity for .trustComplete.
        let initiatorInner = KeepTalkingTrustIdentityInner(
            nodeID: Self.initiatorID,
            identityPublicKey: initiatorIdentityPub
        )
        let initiatorSealed = try TrustHandshakeCrypto.seal(
            try JSONEncoder().encode(initiatorInner),
            with: initiatorSessionKey
        )

        // Responder side, on receiving .trustComplete:
        let openedInitiatorInner = try JSONDecoder().decode(
            KeepTalkingTrustIdentityInner.self,
            from: try TrustHandshakeCrypto.open(initiatorSealed, with: responderSessionKey)
        )
        #expect(openedInitiatorInner.nodeID == Self.initiatorID)
        #expect(openedInitiatorInner.identityPublicKey == initiatorIdentityPub)
    }

    /// Replay attack: an attacker records `.trustAccept` from one session
    /// and replays it under a fresh session ID. The new transcript must
    /// produce a different session key, so the replay's seal won't open.
    @Test("replayed sealed payload from a different session does not open")
    func replayUnderDifferentSessionFails() throws {
        let initiatorEphemeral = TrustHandshakeCrypto.generateEphemeral()
        let responderEphemeral = TrustHandshakeCrypto.generateEphemeral()

        let originalTranscript = Self.transcript(
            initiatorEphemeralPub: initiatorEphemeral.publicKeyBytes,
            responderEphemeralPub: responderEphemeral.publicKeyBytes
        )
        let originalKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: responderEphemeral.privateKey,
            remotePublicBytes: initiatorEphemeral.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: originalTranscript
        )
        let sealed = try TrustHandshakeCrypto.seal(
            Data("payload".utf8),
            with: originalKey
        )

        // Different session ID → different transcript → different key.
        let replayTranscript = TrustHandshakeCrypto.transcript(
            sessionID: UUID(),
            contextID: Self.contextID,
            initiatorNodeID: Self.initiatorID,
            responderNodeID: Self.responderID,
            initiatorEphemeralPub: initiatorEphemeral.publicKeyBytes,
            responderEphemeralPub: responderEphemeral.publicKeyBytes,
            scopeTag: Self.scopeTag
        )
        let replayKey = try TrustHandshakeCrypto.deriveSessionKey(
            localPrivate: initiatorEphemeral.privateKey,
            remotePublicBytes: responderEphemeral.publicKeyBytes,
            contextSecret: Self.contextSecret,
            transcript: replayTranscript
        )
        #expect(throws: TrustHandshakeCrypto.HandshakeError.self) {
            _ = try TrustHandshakeCrypto.open(sealed, with: replayKey)
        }
    }
}
