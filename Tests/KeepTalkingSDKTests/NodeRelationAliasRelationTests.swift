import Foundation
import Testing

@testable import KeepTalkingSDK

struct NodeRelationAliasRelationTests {
    @Test("alias grants share action grant context semantics")
    func sharedApprovingContext() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
        let store = try await KeepTalkingInMemoryStore.make()
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
            ).isEmpty
        )

        relation.relationship = .trusted([context])
        try await relation.save(on: store.database)
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

    @Test("allow gate drives alias execution and advertised state")
    func aliasGrantDrivesAllowGateAndAdvertisement() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await context.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .trusted([context])
        )
        try await relation.save(on: store.database)

        let action = try await makeAction(owner: owner, store: store)
        let tag = KeepTalkingMapping(
            target: .action(try action.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await tag.save(on: store.database)
        let grant = try KeepTalkingNodeRelationAliasRelation(
            relation: relation,
            alias: tag,
            approvingContext: .contexts([context]),
            permission: .verbs([.named("calendar")])
        )
        try await grant.save(on: store.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try context.requireID(),
                node: try owner.requireID()
            ),
            localStore: store
        )

        #expect(
            try await client.allowedActionScope(
                node: recipient,
                action: action,
                context: context
            ) == .verbs([.named("calendar")])
        )
        #expect(
            try await KeepTalkingClient.isActionGrantedToNode(
                node: recipient,
                action: action,
                context: context,
                selfNode: owner,
                on: store.database
            )
        )

        let advertised = try await client.currentNodeStatus(
            context: context,
            recipientNodeID: try recipient.requireID()
        )
        #expect(
            advertised.nodeRelations
                .flatMap(\.actions)
                .first { $0.actionID == action.id }?
                .grantScope == .verbs([.named("calendar")])
        )

        try await KeepTalkingClient.removeTag(
            tag.value,
            from: .action(try action.requireID()),
            on: store.database
        )
        #expect(
            try await client.allowedActionScope(
                node: recipient,
                action: action,
                context: context
            ) == nil
        )
        let removed = try await client.currentNodeStatus(
            context: context,
            recipientNodeID: try recipient.requireID()
        )
        #expect(
            !removed.nodeRelations
                .flatMap(\.actions)
                .contains(where: { $0.actionID == action.id })
        )
    }

    @Test("alias grant scope can switch between all and one context")
    func aliasGrantScopeCanSwitchBetweenAllAndContext() async throws {
        let store = try await KeepTalkingInMemoryStore.make()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        let otherContext = KeepTalkingContext(id: UUID())
        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await context.save(on: store.database)
        try await otherContext.save(on: store.database)

        let relation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .trustedInAllContext
        )
        try await relation.save(on: store.database)

        let action = try await makeAction(owner: owner, store: store)
        let tag = KeepTalkingMapping(
            target: .action(try action.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await tag.save(on: store.database)
        let tagID = try tag.requireID()
        let recipientID = try recipient.requireID()

        try await KeepTalkingClient.grantAliasPermission(
            aliasID: tagID,
            toNodeID: recipientID,
            scope: .all,
            node: owner,
            on: store.database
        )
        #expect(
            try await KeepTalkingClient.allowedActionScope(
                node: recipient,
                action: action,
                context: otherContext,
                on: store.database
            ) == .all
        )

        relation.relationship = .trusted([context])
        try await relation.save(on: store.database)
        let restrictedScopes = try await KeepTalkingClient.grantedAliasScopes(
            forAlias: tagID,
            node: owner,
            on: store.database
        )
        guard case .contexts(let restrictedContexts)? = restrictedScopes[recipientID] else {
            Issue.record("Expected trust to restrict the effective alias scope")
            return
        }
        #expect(restrictedContexts == [context])
        #expect(
            try await KeepTalkingClient.allowedActionScope(
                node: recipient,
                action: action,
                context: otherContext,
                on: store.database
            ) == nil
        )

        relation.relationship = .trustedInAllContext
        try await relation.save(on: store.database)
        let duplicateRelation = try KeepTalkingNodeRelation(
            from: owner,
            to: recipient,
            relationship: .trusted([otherContext])
        )
        try await duplicateRelation.save(on: store.database)
        try await KeepTalkingNodeRelationAliasRelation(
            relation: duplicateRelation,
            alias: tag,
            approvingContext: .contexts([otherContext])
        ).save(on: store.database)

        try await KeepTalkingClient.setAliasPermissionScope(
            aliasID: tagID,
            toNodeID: recipientID,
            scope: .context(context),
            node: owner,
            on: store.database
        )
        #expect(
            try await KeepTalkingClient.allowedActionScope(
                node: recipient,
                action: action,
                context: context,
                on: store.database
            ) == .all
        )
        #expect(
            try await KeepTalkingClient.allowedActionScope(
                node: recipient,
                action: action,
                context: otherContext,
                on: store.database
            ) == nil
        )
        #expect(
            try await KeepTalkingNodeRelationAliasRelation.query(on: store.database)
                .filter(\.$alias.$id, .equal, tagID)
                .count() == 1
        )

        let scopes = try await KeepTalkingClient.grantedAliasScopes(
            forAlias: tagID,
            node: owner,
            on: store.database
        )
        guard case .contexts(let contexts)? = scopes[recipientID] else {
            Issue.record("Expected a context-scoped alias grant")
            return
        }
        #expect(contexts == [context])
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
