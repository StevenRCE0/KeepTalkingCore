import Foundation
import Testing

@testable import KeepTalkingSDK

struct TrustInvitationQueueTests {
    @Test("trust invitation upsert is idempotent per context, pair, and direction")
    func upsertIsIdempotent() async throws {
        let store = KeepTalkingInMemoryStore()
        let contextID = UUID()
        let inviterID = UUID()
        let recipientID = UUID()

        let first = try await KeepTalkingClient.upsertTrustInvitation(
            contextID: contextID,
            inviterNodeID: inviterID,
            recipientNodeID: recipientID,
            direction: .outgoing,
            on: store.database
        )
        let second = try await KeepTalkingClient.upsertTrustInvitation(
            contextID: contextID,
            inviterNodeID: inviterID,
            recipientNodeID: recipientID,
            direction: .outgoing,
            status: .accepted,
            on: store.database
        )

        #expect(first.id == second.id)
        #expect(second.status == .accepted)

        let rows = try await KeepTalkingTrustInvitation.query(on: store.database).all()
        #expect(rows.count == 1)
    }

    @Test("trust invitation skip detection accepts covering all-context trust")
    func skipDetectionUsesCoveringTrust() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let inviter = KeepTalkingNode(id: UUID())

        try await context.save(on: store.database)
        try await recipient.save(on: store.database)
        try await inviter.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: recipient,
            to: inviter,
            relationship: .trustedInAllContext
        )
        try await relation.save(on: store.database)

        let alreadyTrusted = try await KeepTalkingClient.trustAlreadyCovers(
            from: try recipient.requireID(),
            to: try inviter.requireID(),
            contextID: try context.requireID(),
            on: store.database
        )

        #expect(alreadyTrusted)
    }
}
