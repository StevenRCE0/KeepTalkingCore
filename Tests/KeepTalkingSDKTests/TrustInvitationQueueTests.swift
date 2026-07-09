import Foundation
import Testing

@testable import KeepTalkingSDK

struct TrustInvitationQueueTests {
    @Test("pre-trusted relation stages grants but is not trusted")
    func preTrustedRelationStagesGrantsButIsNotTrusted() {
        let context = KeepTalkingContext(id: UUID())
        let relationship = KeepTalkingRelationship.preTrusted([context])

        #expect(!relationship.isTrustedOrOwner)
        #expect(!relationship.allows(context: context))
        #expect(relationship.allowsGrantStaging(context: context))
        #expect(!relationship.allowsGrantStaging(context: KeepTalkingContext(id: UUID())))
    }

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

    @Test("pending outgoing invitation creates and merges pre-trusted relation")
    func pendingOutgoingInvitationCreatesAndMergesPreTrustedRelation()
        async throws
    {
        let store = KeepTalkingInMemoryStore()
        let inviterID = UUID()
        let recipientID = UUID()
        let firstContextID = UUID()
        let secondContextID = UUID()

        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: firstContextID,
            inviterNodeID: inviterID,
            recipientNodeID: recipientID,
            direction: .outgoing,
            on: store.database
        )
        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: secondContextID,
            inviterNodeID: inviterID,
            recipientNodeID: recipientID,
            direction: .outgoing,
            on: store.database
        )

        let relations = try await KeepTalkingNodeRelation.query(on: store.database)
            .filter(\.$from.$id, .equal, inviterID)
            .filter(\.$to.$id, .equal, recipientID)
            .all()
        let relation = try #require(relations.first)

        guard case .preTrusted(let contexts) = relation.relationship else {
            Issue.record("Expected pre-trusted relation")
            return
        }

        #expect(relations.count == 1)
        #expect(Set(contexts.compactMap(\.id)) == Set([firstContextID, secondContextID]))
    }

    @Test("pending outgoing invitation does not downgrade trusted relation")
    func pendingOutgoingInvitationDoesNotDowngradeTrustedRelation() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(id: UUID())
        let inviter = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())

        try await context.save(on: store.database)
        try await inviter.save(on: store.database)
        try await recipient.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: inviter,
            to: recipient,
            relationship: .trusted([context])
        )
        try await relation.save(on: store.database)

        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: try #require(context.id),
            inviterNodeID: try #require(inviter.id),
            recipientNodeID: try #require(recipient.id),
            direction: .outgoing,
            on: store.database
        )

        let reloaded = try #require(
            try await KeepTalkingNodeRelation.find(
                try #require(relation.id),
                on: store.database
            )
        )
        #expect(reloaded.relationship == .trusted([context]))
    }

    @Test("failed outgoing invitation removes only matching pre-trusted context")
    func failedOutgoingInvitationRemovesOnlyMatchingPreTrustedContext()
        async throws
    {
        let store = KeepTalkingInMemoryStore()
        let inviter = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let first = KeepTalkingContext(id: UUID())
        let second = KeepTalkingContext(id: UUID())

        try await inviter.save(on: store.database)
        try await recipient.save(on: store.database)
        try await first.save(on: store.database)
        try await second.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: inviter,
            to: recipient,
            relationship: .preTrusted([first, second])
        )
        try await relation.save(on: store.database)

        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: try #require(first.id),
            inviterNodeID: try #require(inviter.id),
            recipientNodeID: try #require(recipient.id),
            direction: .outgoing,
            status: .failed,
            on: store.database
        )

        let reloaded = try #require(
            try await KeepTalkingNodeRelation.find(
                try #require(relation.id),
                on: store.database
            )
        )
        #expect(reloaded.relationship == .preTrusted([second]))
    }
}
