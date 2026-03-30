import Foundation
import Testing

@testable import KeepTalkingSDK

struct PushWakeNotificationCryptoTests {
    @Test("action wake notifications round-trip through context secret crypto")
    func actionWakePayloadRoundTripsThroughContextSecret() throws {
        let payload = KeepTalkingPushWakeActionPayload(
            contextID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            senderNodeID: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!,
            actionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let secret = Data("transport-secret-32-bytes-length!!".utf8)

        let envelope = try KeepTalkingPushWakeActionEnvelope.encrypt(
            payload,
            secret: secret
        )

        #expect(envelope.contextID == payload.contextID)
        #expect(!envelope.ciphertext.isEmpty)

        let decrypted = try envelope.decrypt(secret: secret)

        #expect(decrypted == payload)
    }
}
