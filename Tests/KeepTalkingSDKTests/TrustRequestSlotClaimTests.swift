import Foundation
import Testing

@testable import KeepTalkingSDK

struct TrustRequestSlotClaimTests {
    /// The `slot` claim is an additive optional on the trust-request wire
    /// payload: requests from builds/links that predate it must decode with a
    /// nil claim, and a claimed request must round-trip it intact.
    @Test("trust request payload tolerates missing slot and round-trips it")
    func slotClaimWireCompat() throws {
        struct LegacyPayload: Codable {
            let sessionID: UUID
            let from: UUID
            let to: UUID
            let contextID: UUID
            let initiatorEphemeralPub: Data
        }

        let legacy = LegacyPayload(
            sessionID: UUID(),
            from: UUID(),
            to: UUID(),
            contextID: UUID(),
            initiatorEphemeralPub: Data([1, 2, 3])
        )
        let decoded = try JSONDecoder().decode(
            KeepTalkingTrustRequestPayload.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(decoded.sessionID == legacy.sessionID)
        #expect(decoded.initiatorEphemeralPub == legacy.initiatorEphemeralPub)
        #expect(decoded.slot == nil)

        let slotID = UUID()
        let claimed = KeepTalkingTrustRequestPayload(
            sessionID: UUID(),
            from: UUID(),
            to: UUID(),
            contextID: UUID(),
            initiatorEphemeralPub: Data([4, 5]),
            slot: slotID
        )
        let roundTripped = try JSONDecoder().decode(
            KeepTalkingTrustRequestPayload.self,
            from: JSONEncoder().encode(claimed)
        )
        #expect(roundTripped.slot == slotID)

        // And the reverse direction: an old build decoding a claimed request
        // simply ignores the unknown key.
        let downgraded = try JSONDecoder().decode(
            LegacyPayload.self,
            from: JSONEncoder().encode(claimed)
        )
        #expect(downgraded.sessionID == claimed.sessionID)
    }
}
