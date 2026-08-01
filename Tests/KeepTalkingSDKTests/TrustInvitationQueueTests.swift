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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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

    // MARK: Invitation lifetime is bound to the grants it authorises

    @Test("revoking the last grant deletes the pending invitation")
    func revokingLastGrantDeletesPendingInvitation() async throws {
        let fixture = try await GrantFixture.make()
        try await fixture.stageActionGrant()

        #expect(try await fixture.pendingInvitationCount() == 1)

        try await fixture.revokeActionGrant()

        #expect(try await fixture.pendingInvitationCount() == 0)
        // The pre-trusted context the invitation introduced goes with it, so
        // the peer stops reading as "trust pending" in the UI.
        #expect(try await fixture.relationship() == nil)
    }

    @Test("invitation survives while another action grant remains")
    func invitationSurvivesWhileAnotherActionGrantRemains() async throws {
        let fixture = try await GrantFixture.make()
        let second = try await fixture.makeAction()
        try await fixture.stageActionGrant()
        try await fixture.stageActionGrant(action: second)

        try await fixture.revokeActionGrant()

        #expect(try await fixture.pendingInvitationCount() == 1)
        #expect(try await fixture.relationship() == .preTrusted([fixture.context]))
    }

    @Test("invitation survives on a tag-inherited grant after the direct grant goes")
    func invitationSurvivesOnTagInheritedGrant() async throws {
        let fixture = try await GrantFixture.make()
        try await fixture.stageActionGrant()
        let tagID = try await fixture.tagAction()
        try await fixture.stageAliasGrant(aliasID: tagID)

        try await fixture.revokeActionGrant()

        // The direct row is gone but the tag still grants the same action —
        // the invitation is keyed on the union of both, not on action rows.
        #expect(try await fixture.pendingInvitationCount() == 1)

        try await fixture.revokeAliasGrant(aliasID: tagID)

        #expect(try await fixture.pendingInvitationCount() == 0)
        #expect(try await fixture.relationship() == nil)
    }

    @Test("tag grants can reach a peer that no other grant has pre-trusted")
    func tagGrantsReachAPeerWithNoOtherGrant() async throws {
        let fixture = try await GrantFixture.make()
        let tagID = try await fixture.tagAction()

        // `.grantStaging` eligibility rejects a bare `.pending` relation, so
        // this only works because the alias path raises the invitation itself.
        try await fixture.stageAliasGrant(aliasID: tagID)

        #expect(try await fixture.pendingInvitationCount() == 1)
        #expect(try await fixture.relationship() == .preTrusted([fixture.context]))
    }

    @Test("terminal invitations are history and survive reconciliation")
    func terminalInvitationsSurviveReconciliation() async throws {
        let fixture = try await GrantFixture.make()
        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: try #require(fixture.context.id),
            inviterNodeID: try #require(fixture.owner.id),
            recipientNodeID: try #require(fixture.recipient.id),
            direction: .outgoing,
            status: .declined,
            on: fixture.store.database
        )

        try await KeepTalkingClient.reconcilePendingTrustInvitations(
            from: try #require(fixture.owner.id),
            to: try #require(fixture.recipient.id),
            in: fixture.context,
            on: fixture.store.database
        )

        let rows = try await KeepTalkingTrustInvitation.query(
            on: fixture.store.database
        ).all()
        #expect(rows.count == 1)
        #expect(rows.first?.status == .declined)
    }

    @Test("revoking the grant row directly also clears the invitation")
    func revokingGrantRowDirectlyClearsInvitation() async throws {
        let fixture = try await GrantFixture.make()
        try await fixture.stageActionGrant()
        let grantID = try #require(
            try await KeepTalkingNodeRelationActionRelation.query(
                on: fixture.store.database
            ).first()?.id
        )

        // The panels revoke by grant-row id rather than by (action, node), so
        // that path has to hold the invariant too.
        try await fixture.makeClient().revokeActionPermissionGrant(
            grantID: grantID
        )

        #expect(try await fixture.pendingInvitationCount() == 0)
        #expect(try await fixture.relationship() == nil)
    }

    @Test("deleting a node locally takes its invitations with it")
    func deletingNodeLocallyTakesItsInvitations() async throws {
        let fixture = try await GrantFixture.make()
        try await fixture.stageActionGrant()
        #expect(try await fixture.pendingInvitationCount() == 1)

        try await KeepTalkingClient.deleteNodeLocally(
            try #require(fixture.recipient.id),
            localNodeID: try #require(fixture.owner.id),
            on: fixture.store.database
        )

        let rows = try await KeepTalkingTrustInvitation.query(
            on: fixture.store.database
        ).count()
        #expect(rows == 0)
    }

    /// An owner, a peer they haven't trusted, and one context to grant in.
    private struct GrantFixture {
        let store: KeepTalkingInMemoryStore
        let owner: KeepTalkingNode
        let recipient: KeepTalkingNode
        let context: KeepTalkingContext
        let action: KeepTalkingAction

        static func make() async throws -> GrantFixture {
            let store = try await KeepTalkingInMemoryStore.make()
            let owner = KeepTalkingNode(id: UUID())
            let recipient = KeepTalkingNode(id: UUID())
            let context = KeepTalkingContext(id: UUID())
            try await owner.save(on: store.database)
            try await recipient.save(on: store.database)
            try await context.save(on: store.database)

            let fixture = GrantFixture(
                store: store,
                owner: owner,
                recipient: recipient,
                context: context,
                action: try await Self.makeAction(owner: owner, store: store)
            )
            return fixture
        }

        static func makeAction(
            owner: KeepTalkingNode,
            store: KeepTalkingInMemoryStore
        ) async throws -> KeepTalkingAction {
            try await KeepTalkingClient.registerAction(
                payload: .primitive(
                    KeepTalkingPrimitiveBundle(
                        name: UUID().uuidString,
                        indexDescription: "Test action",
                        action: .accessCalendar
                    )
                ),
                node: owner,
                on: store.database
            )
        }

        func makeAction() async throws -> KeepTalkingAction {
            try await Self.makeAction(owner: owner, store: store)
        }

        func makeClient() throws -> KeepTalkingClient {
            KeepTalkingClient(
                config: KeepTalkingConfig(
                    contextID: try context.requireID(),
                    node: try owner.requireID()
                ),
                localStore: store
            )
        }

        func stageActionGrant(action: KeepTalkingAction? = nil) async throws {
            try await KeepTalkingClient.stageActionPermissionWithTrustInvitation(
                contextID: try context.requireID(),
                actionID: try (action ?? self.action).requireID(),
                toNodeID: try recipient.requireID(),
                node: owner,
                on: store.database
            )
        }

        func revokeActionGrant(action: KeepTalkingAction? = nil) async throws {
            try await KeepTalkingClient.revokeActionPermission(
                actionID: try (action ?? self.action).requireID(),
                fromNodeID: try recipient.requireID(),
                context: context,
                eligibility: .grantStaging,
                node: owner,
                on: store.database
            )
        }

        func tagAction(value: String = "Utilities") async throws -> UUID {
            let tag = KeepTalkingMapping(
                target: .action(try action.requireID()),
                kind: .tag,
                value: value
            )
            try await tag.save(on: store.database)
            return try tag.requireID()
        }

        func stageAliasGrant(aliasID: UUID) async throws {
            try await KeepTalkingClient.stageAliasPermissionWithTrustInvitation(
                contextID: try context.requireID(),
                aliasID: aliasID,
                toNodeID: try recipient.requireID(),
                node: owner,
                on: store.database
            )
        }

        func revokeAliasGrant(aliasID: UUID) async throws {
            try await KeepTalkingClient.revokeAliasPermission(
                aliasID: aliasID,
                fromNodeID: try recipient.requireID(),
                context: context,
                eligibility: .grantStaging,
                node: owner,
                on: store.database
            )
        }

        func pendingInvitationCount() async throws -> Int {
            try await KeepTalkingTrustInvitation.query(on: store.database)
                .filter(\.$context.$id, .equal, try context.requireID())
                .filter(\.$inviterNodeID, .equal, try owner.requireID())
                .filter(\.$recipientNodeID, .equal, try recipient.requireID())
                .filter(\.$direction, .equal, .outgoing)
                .filter(\.$status, .equal, .pending)
                .count()
        }

        func relationship() async throws -> KeepTalkingRelationship? {
            try await KeepTalkingNodeRelation.query(on: store.database)
                .filter(\.$from.$id, .equal, try owner.requireID())
                .filter(\.$to.$id, .equal, try recipient.requireID())
                .first()?
                .relationship
        }
    }
}
