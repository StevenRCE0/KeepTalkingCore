import Foundation
import Testing

@testable import KeepTalkingSDK

struct WorkspacePlanRecordTests {
    private func makePlan(
        peerID: UUID,
        createID: UUID,
        fromPeerID: UUID
    ) -> KeepTalkingWorkspacePlan {
        KeepTalkingWorkspacePlan(
            contextName: "Paper Workspace",
            tags: ["research"],
            peers: [
                .init(
                    id: peerID,
                    alias: "Reviewer",
                    expectedCapabilities: ["Review Draft"],
                    grantedActions: [createID]
                )
            ],
            actions: [
                .init(id: createID, name: "Compile Draft", source: .create),
                .init(
                    id: fromPeerID,
                    name: "Review Draft",
                    source: .fromPeer(peerID: peerID)
                ),
            ],
            sideNotes: [.init(key: "sop", value: "Weekly review cadence")]
        )
    }

    @Test("records round-trip and are queryable by context")
    func queryByContext() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: localStore.database)
        let contextID = try #require(context.id)

        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: UUID(), createID: UUID(), fromPeerID: UUID())
        )
        try await KeepTalkingClient.saveWorkspacePlanRecord(
            record,
            on: localStore.database
        )

        // Unestablished until a context is recorded.
        #expect(
            try await KeepTalkingClient.workspacePlanRecord(
                for: contextID,
                on: localStore.database
            ) == nil
        )
        #expect(
            try await KeepTalkingClient.unestablishedWorkspacePlanRecords(
                on: localStore.database
            ).count == 1
        )

        record.recordContext(contextID)
        try await KeepTalkingClient.saveWorkspacePlanRecord(
            record,
            on: localStore.database
        )

        let fetched = try #require(
            try await KeepTalkingClient.workspacePlanRecord(
                for: contextID,
                on: localStore.database
            )
        )
        #expect(fetched.contextID == contextID)
        #expect(fetched.plan?.contextName == "Paper Workspace")
        #expect(fetched.unboundPeers.count == 1)
        #expect(fetched.pendingActions.count == 2)
        #expect(
            try await KeepTalkingClient.unestablishedWorkspacePlanRecords(
                on: localStore.database
            ).isEmpty
        )
    }

    @Test("binding unblocks fromPeer slots and completion flips at the end")
    func progressionSemantics() async throws {
        let peerID = UUID()
        let createID = UUID()
        let fromPeerID = UUID()
        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: peerID, createID: createID, fromPeerID: fromPeerID)
        )
        record.recordContext(UUID())

        let unblocked = try record.recordBinding(peerID: peerID, nodeID: UUID())
        #expect(unblocked.map(\.id) == [fromPeerID])
        #expect(record.unboundPeers.isEmpty)

        try record.fulfill(planActionID: createID, withActionID: UUID())
        #expect(!record.isComplete)

        try record.fulfill(planActionID: fromPeerID, withActionID: UUID())
        #expect(!record.isComplete)

        record.recordSideNoteApplied("sop")
        #expect(record.isComplete)

        #expect(throws: KeepTalkingWorkspacePlanError.self) {
            try record.fulfill(planActionID: UUID(), withActionID: UUID())
        }
        #expect(throws: KeepTalkingWorkspacePlanError.self) {
            try record.recordBinding(peerID: UUID(), nodeID: UUID())
        }
    }

    @Test("revise prunes stale fulfillments and reopens work")
    func revisePruning() async throws {
        let peerID = UUID()
        let createID = UUID()
        let fromPeerID = UUID()
        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: peerID, createID: createID, fromPeerID: fromPeerID)
        )
        record.recordContext(UUID())
        try record.fulfill(planActionID: createID, withActionID: UUID())
        try record.recordBinding(peerID: peerID, nodeID: UUID())

        // The revision drops the fromPeer slot and the side note, keeps the
        // create slot (same id) and the peer, and adds a fresh action.
        var revised = try #require(record.plan)
        revised.actions.removeAll { $0.id == fromPeerID }
        revised.sideNotes = []
        let addedID = UUID()
        revised.actions.append(
            .init(id: addedID, name: "Summarize Feedback", source: .create)
        )
        try record.revise(revised)

        #expect(record.fulfillment.actionFulfillments.keys.contains(createID))
        #expect(record.fulfillment.peerBindings.keys.contains(peerID))
        #expect(record.pendingActions.map(\.id) == [addedID])
        #expect(!record.isComplete)
    }

    @Test("context deletion cascades the plan; delete-then-save re-creates")
    func cascadeAndRecreate() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: localStore.database)
        let contextID = try #require(context.id)

        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: UUID(), createID: UUID(), fromPeerID: UUID())
        )
        record.recordContext(contextID)
        try await KeepTalkingClient.saveWorkspacePlanRecord(
            record,
            on: localStore.database
        )

        // Delete-then-save re-creates the row — the revise-after-complete edge
        // relies on Fluent clearing `_$idExists` on delete.
        try await KeepTalkingClient.deleteWorkspacePlanRecord(
            record,
            on: localStore.database
        )
        #expect(
            try await KeepTalkingClient.workspacePlanRecord(
                for: contextID,
                on: localStore.database
            ) == nil
        )
        try await KeepTalkingClient.saveWorkspacePlanRecord(
            record,
            on: localStore.database
        )
        #expect(
            try await KeepTalkingClient.workspacePlanRecord(
                for: contextID,
                on: localStore.database
            ) != nil
        )

        try await context.delete(on: localStore.database)
        let survivors =
            try await KeepTalkingWorkspacePlanRecord
            .query(on: localStore.database)
            .all()
        #expect(survivors.isEmpty)
    }
}
