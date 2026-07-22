import Foundation
import Testing

@testable import KeepTalkingSDK

struct NodeRelationAliasRelationTests {
    @Test("alias grants share action grant context semantics")
    func sharedApprovingContext() async throws {
        let store = KeepTalkingInMemoryStore()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let approved = KeepTalkingContext(id: UUID())
        let unrelated = KeepTalkingContext(id: UUID())

        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await approved.save(on: store.database)
        try await unrelated.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .preTrusted([approved])
        )
        try await relation.save(on: store.database)
        let alias = KeepTalkingMapping(
            target: .node(try owner.requireID()),
            kind: .tag,
            namespace: " work ",
            value: " Tools ",
            colorHex: " #AABBCC "
        )
        try await alias.save(on: store.database)

        let approvingContext: KeepTalkingNodeRelationActionRelation.ApprovingContext =
            .contexts([approved])
        let grant = try KeepTalkingNodeRelationAliasRelation(
            relation: relation,
            alias: alias,
            approvingContext: approvingContext,
            permission: .verbs([.callTool])
        )
        try await grant.save(on: store.database)

        let stored = try #require(
            try await relation.$aliases.$pivots.query(on: store.database).first()
        )
        #expect(stored.$alias.id == alias.id)
        let storedAlias = try await stored.$alias.get(on: store.database)
        #expect(storedAlias.namespace == "work")
        #expect(storedAlias.value == "Tools")
        #expect(storedAlias.normalizedValue == "tools")
        #expect(storedAlias.colorHex == "#AABBCC")
        #expect(stored.applicable(in: approved))
        #expect(!stored.applicable(in: unrelated))
        #expect(!stored.applicable(in: nil))

        #expect(relation.relationship.allowsGrantStaging(context: approved))
        #expect(!relation.relationship.allows(context: approved))
    }

    @Test("deleting a node relation cascades to alias grants")
    func relationDeleteCascades() async throws {
        let store = KeepTalkingInMemoryStore()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())

        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .trustedInAllContext
        )
        try await relation.save(on: store.database)
        let alias = KeepTalkingMapping(
            target: .node(try owner.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await alias.save(on: store.database)

        let grant = try KeepTalkingNodeRelationAliasRelation(
            relation: relation,
            alias: alias,
            approvingContext: .all
        )
        try await grant.save(on: store.database)
        try await relation.delete(on: store.database)

        #expect(
            try await KeepTalkingNodeRelationAliasRelation.query(
                on: store.database
            ).count() == 0
        )
    }

    @Test("failed pre-trust keeps staged alias grants on a pending relation")
    func failedPreTrustRetainsStagedGrant() async throws {
        let store = KeepTalkingInMemoryStore()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())

        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await context.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .preTrusted([context])
        )
        try await relation.save(on: store.database)
        let alias = KeepTalkingMapping(
            target: .node(try owner.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await alias.save(on: store.database)

        let grant = try KeepTalkingNodeRelationAliasRelation(
            relation: relation,
            alias: alias,
            approvingContext: .contexts([context])
        )
        try await grant.save(on: store.database)

        try await KeepTalkingClient.upsertTrustInvitation(
            contextID: try context.requireID(),
            inviterNodeID: try owner.requireID(),
            recipientNodeID: try recipient.requireID(),
            direction: .outgoing,
            status: .failed,
            on: store.database
        )

        let retained = try #require(
            try await KeepTalkingNodeRelation.find(
                try relation.requireID(),
                on: store.database
            )
        )
        #expect(retained.relationship == .pending)
        #expect(
            try await retained.$aliases.$pivots.query(
                on: store.database
            ).count() == 1
        )
    }

    @Test("alias grants follow tag identity across action mappings")
    func aliasGrantUsesDynamicTagIdentity() async throws {
        let store = KeepTalkingInMemoryStore()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await context.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .preTrusted([context])
        )
        try await relation.save(on: store.database)

        let firstAction = try await makeAction(owner: owner, store: store)
        let secondAction = try await makeAction(owner: owner, store: store)
        let firstTag = KeepTalkingMapping(
            target: .action(try firstAction.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        let secondTag = KeepTalkingMapping(
            target: .action(try secondAction.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await firstTag.save(on: store.database)
        try await secondTag.save(on: store.database)

        try await KeepTalkingClient.grantAliasPermission(
            aliasID: try firstTag.requireID(),
            toNodeID: try recipient.requireID(),
            scope: .context(context),
            eligibility: .grantStaging,
            node: owner,
            on: store.database
        )

        #expect(
            try await KeepTalkingClient.grantedNodeIDs(
                forAlias: try secondTag.requireID(),
                context: context,
                node: owner,
                on: store.database
            ) == [try recipient.requireID()]
        )

        try await KeepTalkingClient.revokeAliasPermission(
            aliasID: try secondTag.requireID(),
            fromNodeID: try recipient.requireID(),
            context: context,
            eligibility: .grantStaging,
            node: owner,
            on: store.database
        )
        #expect(
            try await KeepTalkingNodeRelationAliasRelation.query(
                on: store.database
            ).count() == 0
        )
    }

    private func makeAction(
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
}
