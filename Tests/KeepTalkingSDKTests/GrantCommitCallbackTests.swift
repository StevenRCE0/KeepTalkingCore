import Foundation
import Testing

@testable import KeepTalkingSDK

actor GrantCommitRecorder {
    private var batches: [[KeepTalkingGrantCommit]] = []

    func record(_ batch: [KeepTalkingGrantCommit]) {
        batches.append(batch)
    }

    func snapshot() -> [[KeepTalkingGrantCommit]] {
        batches
    }

    var flattened: [KeepTalkingGrantCommit] {
        batches.flatMap { $0 }
    }
}

/// `onGrantCommitted` is the telemetry seam for every grant mutation an
/// instance client performs. These tests pin what a consumer can rely on:
/// one commit per changed peer, the lane the caller passed, nothing on a
/// throw, and silence from scope-only updates.
struct GrantCommitCallbackTests {
    private struct Fixture {
        let store: KeepTalkingInMemoryStore
        let owner: KeepTalkingNode
        let recipient: KeepTalkingNode
        let context: KeepTalkingContext
        let action: KeepTalkingAction
        let client: KeepTalkingClient
        let recorder: GrantCommitRecorder

        var ownerID: UUID { owner.id! }
        var recipientID: UUID { recipient.id! }
        var contextID: UUID { context.id! }
        var actionID: UUID { action.id! }
    }

    private func makeFixture() async throws -> Fixture {
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
            relationship: .trustedInAllContext
        )
        try await relation.save(on: store.database)

        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                .init(
                    name: "commit-test",
                    indexDescription: "Commit test",
                    action: .openWithURL
                )),
            node: owner,
            on: store.database
        )

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try context.requireID(),
                node: try owner.requireID()
            ),
            localStore: store
        )
        let recorder = GrantCommitRecorder()
        client.onGrantCommitted = { await recorder.record($0) }

        return Fixture(
            store: store,
            owner: owner,
            recipient: recipient,
            context: context,
            action: action,
            client: client,
            recorder: recorder
        )
    }

    @Test("a transaction reports one commit per entry, grants and revokes alike, with the lane")
    func transactionReportsEveryEntry() async throws {
        let fixture = try await makeFixture()

        var grant = KeepTalkingGrantTransaction()
        grant.grant(in: fixture.contextID, actionID: fixture.actionID, to: fixture.recipientID)
        try await fixture.client.grantActionPermission(transaction: grant, lane: .workbench)

        var revoke = KeepTalkingGrantTransaction()
        revoke.revoke(in: fixture.contextID, actionID: fixture.actionID, from: fixture.recipientID)
        try await fixture.client.grantActionPermission(transaction: revoke, lane: .workbench)

        let commits = await fixture.recorder.flattened
        #expect(
            commits == [
                .init(
                    contextID: fixture.contextID,
                    toNodeID: fixture.recipientID,
                    change: .actionGranted(scope: nil),
                    lane: .workbench
                ),
                .init(
                    contextID: fixture.contextID,
                    toNodeID: fixture.recipientID,
                    change: .actionRevoked,
                    lane: .workbench
                ),
            ]
        )
        #expect(await fixture.recorder.snapshot().count == 2)
    }

    @Test("the lane defaults to .other when a caller does not say")
    func laneDefaultsToOther() async throws {
        let fixture = try await makeFixture()

        try await fixture.client.grantActionPermission(
            actionID: fixture.actionID,
            toNodeID: fixture.recipientID,
            scope: .all,
            grantScope: .verbs([])
        )

        let commits = await fixture.recorder.flattened
        #expect(commits.count == 1)
        #expect(commits.first?.lane == .other)
        #expect(commits.first?.contextID == nil)
        #expect(commits.first?.change == .actionGranted(scope: .verbs([])))
    }

    @Test("a row-level revert names the grantee it took access from")
    func rowRevertNamesGrantee() async throws {
        let fixture = try await makeFixture()

        var grant = KeepTalkingGrantTransaction()
        grant.grant(in: fixture.contextID, actionID: fixture.actionID, to: fixture.recipientID)
        try await fixture.client.grantActionPermission(transaction: grant, lane: .chat)

        let row = try #require(
            try await KeepTalkingNodeRelationActionRelation.query(on: fixture.store.database)
                .first()
        )
        try await fixture.client.revokeActionPermissionGrant(
            grantID: try row.requireID(),
            lane: .chat
        )

        let commits = await fixture.recorder.flattened
        #expect(commits.count == 2)
        #expect(
            commits.last
                == .init(
                    contextID: fixture.contextID,
                    toNodeID: fixture.recipientID,
                    change: .actionRevoked,
                    lane: .chat
                )
        )
    }

    @Test("a tag grant reports how many self-hosted actions it reaches")
    func aliasGrantReportsReach() async throws {
        let fixture = try await makeFixture()
        let secondAction = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                .init(
                    name: "commit-test-2",
                    indexDescription: "Commit test 2",
                    action: .openWithURL
                )),
            node: fixture.owner,
            on: fixture.store.database
        )
        let firstTag = KeepTalkingMapping(
            target: .action(fixture.actionID),
            kind: .tag,
            value: "Utilities"
        )
        let secondTag = KeepTalkingMapping(
            target: .action(try secondAction.requireID()),
            kind: .tag,
            value: "Utilities"
        )
        try await firstTag.save(on: fixture.store.database)
        try await secondTag.save(on: fixture.store.database)

        try await fixture.client.grantAliasPermission(
            aliasID: try firstTag.requireID(),
            toNodeID: fixture.recipientID,
            scope: .context(fixture.context),
            lane: .workbench
        )
        try await fixture.client.revokeAliasPermission(
            aliasID: try firstTag.requireID(),
            fromNodeID: fixture.recipientID,
            context: fixture.context,
            lane: .workbench
        )

        let commits = await fixture.recorder.flattened
        #expect(
            commits == [
                .init(
                    contextID: fixture.contextID,
                    toNodeID: fixture.recipientID,
                    change: .aliasGranted(reachesActionCount: 2),
                    lane: .workbench
                ),
                .init(
                    contextID: fixture.contextID,
                    toNodeID: fixture.recipientID,
                    change: .aliasRevoked,
                    lane: .workbench
                ),
            ]
        )
    }

    @Test("a throwing grant reports nothing")
    func throwingGrantReportsNothing() async throws {
        let fixture = try await makeFixture()
        let stranger = UUID()

        await #expect(throws: (any Error).self) {
            try await fixture.client.grantActionPermission(
                actionID: fixture.actionID,
                toNodeID: stranger,
                scope: .all,
                lane: .chat
            )
        }

        #expect(await fixture.recorder.flattened.isEmpty)
    }

    @Test("scope-only updates stay silent")
    func scopeUpdateIsSilent() async throws {
        let fixture = try await makeFixture()

        var grant = KeepTalkingGrantTransaction()
        grant.grant(in: fixture.contextID, actionID: fixture.actionID, to: fixture.recipientID)
        try await fixture.client.grantActionPermission(transaction: grant, lane: .chat)
        let row = try #require(
            try await KeepTalkingNodeRelationActionRelation.query(on: fixture.store.database)
                .first()
        )

        try await fixture.client.updateGrantPermission(
            grantID: try row.requireID(),
            grantScope: .verbs([])
        )

        #expect(await fixture.recorder.flattened.count == 1)
    }
}
