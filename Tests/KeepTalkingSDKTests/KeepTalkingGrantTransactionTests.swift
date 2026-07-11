import Foundation
import Testing

@testable import KeepTalkingSDK

struct KeepTalkingGrantTransactionTests {
    @Test("transactions merge by grant key and invalidate individually")
    func mergeAndInvalidate() {
        let contextID = UUID()
        let actionID = UUID()
        let firstNodeID = UUID()
        let secondNodeID = UUID()
        let firstKey = KeepTalkingGrantTransaction.Key(
            contextID: contextID,
            actionID: actionID,
            nodeID: firstNodeID
        )

        var transaction = KeepTalkingGrantTransaction()
        transaction.grant(in: contextID, actionID: actionID, to: firstNodeID)
        var latest = KeepTalkingGrantTransaction()
        latest.revoke(in: contextID, actionID: actionID, from: firstNodeID)
        latest.grant(in: contextID, actionID: actionID, to: secondNodeID)
        transaction.merge(latest)

        #expect(transaction.change(for: firstKey) == .revoke)
        let invalidated = transaction.invalidate(firstKey)
        #expect(invalidated)
        #expect(transaction.entries.count == 1)
        #expect(transaction.entries.first?.key.nodeID == secondNodeID)
    }

    @Test("grant transaction applies grants and revokes")
    func apply() async throws {
        let store = KeepTalkingInMemoryStore()
        let owner = KeepTalkingNode(id: UUID())
        let recipient = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await owner.save(on: store.database)
        try await recipient.save(on: store.database)
        try await context.save(on: store.database)
        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                .init(
                    name: "transaction-test",
                    indexDescription: "Transaction test",
                    action: .openWithURL
                )),
            node: owner,
            on: store.database
        )
        let contextID = try #require(context.id)
        let actionID = try #require(action.id)
        let recipientID = try #require(recipient.id)

        var transaction = KeepTalkingGrantTransaction()
        transaction.grant(in: contextID, actionID: actionID, to: recipientID)
        try await KeepTalkingClient.grantActionPermission(
            transaction: transaction,
            node: owner,
            on: store.database
        )
        #expect(
            try await KeepTalkingNodeRelationActionRelation.query(
                on: store.database
            ).count() == 1)

        transaction.revoke(in: contextID, actionID: actionID, from: recipientID)
        try await KeepTalkingClient.grantActionPermission(
            transaction: transaction,
            node: owner,
            on: store.database
        )
        #expect(
            try await KeepTalkingNodeRelationActionRelation.query(
                on: store.database
            ).count() == 0)

        let relation = try #require(
            try await KeepTalkingNodeRelation.query(on: store.database).first()
        )
        relation.relationship = .trustedInAllContext
        try await relation.save(on: store.database)
        transaction = KeepTalkingGrantTransaction()
        transaction.grant(actionID: actionID, to: recipientID)
        try await KeepTalkingClient.grantActionPermission(
            transaction: transaction,
            node: owner,
            on: store.database
        )
        #expect(transaction.entries.first?.key.contextID == nil)
        #expect(
            try await KeepTalkingNodeRelationActionRelation.query(
                on: store.database
            ).count() == 1)
    }
}
