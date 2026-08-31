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

    @Test("fulfillment decoding tolerates old and minimal blobs")
    func fulfillmentBackCompatDecode() throws {
        // The exact wire shape written before `slotInvites` existed — a
        // synthesized-Codable mirror reproduces it faithfully (including the
        // alternating-array encoding of UUID-keyed dictionaries).
        struct LegacyFulfillment: Codable {
            var contextID: UUID?
            var actionFulfillments: [UUID: UUID] = [:]
            var peerBindings: [UUID: UUID] = [:]
            var appliedSideNoteKeys: [String] = []
        }

        var legacy = LegacyFulfillment()
        legacy.contextID = UUID()
        legacy.actionFulfillments = [UUID(): UUID()]
        legacy.peerBindings = [UUID(): UUID()]
        legacy.appliedSideNoteKeys = ["sop"]

        let decoded = try JSONDecoder().decode(
            KeepTalkingWorkspacePlanFulfillment.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(decoded.contextID == legacy.contextID)
        #expect(decoded.actionFulfillments == legacy.actionFulfillments)
        #expect(decoded.peerBindings == legacy.peerBindings)
        #expect(decoded.appliedSideNoteKeys == ["sop"])
        #expect(decoded.slotInvites.isEmpty)

        let minimal = try JSONDecoder().decode(
            KeepTalkingWorkspacePlanFulfillment.self,
            from: Data("{}".utf8)
        )
        #expect(minimal.contextID == nil)
        #expect(minimal.actionFulfillments.isEmpty)
        #expect(minimal.slotInvites.isEmpty)

        var full = KeepTalkingWorkspacePlanFulfillment()
        full.peerBindings = [UUID(): UUID()]
        full.slotInvites = [UUID(): Date(timeIntervalSince1970: 1_000)]
        let roundTripped = try JSONDecoder().decode(
            KeepTalkingWorkspacePlanFulfillment.self,
            from: JSONEncoder().encode(full)
        )
        #expect(roundTripped.peerBindings == full.peerBindings)
        #expect(roundTripped.slotInvites == full.slotInvites)
    }

    @Test("slot invites record and clear, and binding consumes them")
    func slotInviteLifecycle() throws {
        let peerID = UUID()
        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: peerID, createID: UUID(), fromPeerID: UUID())
        )
        record.recordContext(UUID())

        #expect(throws: KeepTalkingWorkspacePlanError.self) {
            try record.recordSlotInvite(UUID())
        }
        #expect(!record.hasOutstandingSlotInvites)

        try record.recordSlotInvite(peerID)
        #expect(record.hasOutstandingSlotInvites)
        #expect(record.outstandingSlotInvites.keys.contains(peerID))

        record.clearSlotInvite(peerID)
        #expect(!record.hasOutstandingSlotInvites)

        try record.recordSlotInvite(peerID)
        try record.recordBinding(peerID: peerID, nodeID: UUID())
        #expect(record.fulfillment.slotInvites[peerID] == nil)
        #expect(!record.hasOutstandingSlotInvites)
    }

    @Test("bind runs the whole progression: gate, grants, alias, sweep")
    func bindProgression() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let db = localStore.database

        let selfID = UUID()
        let peerNodeID = UUID()
        let selfNode = KeepTalkingNode(id: selfID)
        let peerNode = KeepTalkingNode(id: peerNodeID)
        try await selfNode.save(on: db)
        try await peerNode.save(on: db)
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: db)
        let contextID = try context.requireID()

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: selfID),
            localStore: localStore
        )

        // A local action fulfills the create slot; the peer hosts the action
        // the `.fromPeer` slot expects, matched by label.
        let localAction = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "Compile Draft",
                    indexDescription: "Compiles the draft",
                    action: .accessCalendar
                )
            ),
            node: selfNode,
            on: db
        )
        _ = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "Review Draft",
                    indexDescription: "Reviews the draft",
                    action: .accessCalendar
                )
            ),
            node: peerNode,
            on: db
        )

        let peerID = UUID()
        let createID = UUID()
        let fromPeerID = UUID()
        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: peerID, createID: createID, fromPeerID: fromPeerID)
        )
        record.recordContext(contextID)
        try record.recordSlotInvite(peerID)
        try await KeepTalkingClient.saveWorkspacePlanRecord(record, on: db)

        // Untrusted → the gate throws and nothing binds.
        await #expect(throws: KeepTalkingWorkspacePlanError.self) {
            try await client.bindWorkspacePlanPeer(
                record,
                peerID: peerID,
                toNodeID: peerNodeID
            )
        }
        #expect(record.unboundPeers.count == 1)

        // Trust the peer in this context, fulfill the create slot, then bind.
        let relation = try KeepTalkingNodeRelation(
            from: selfNode,
            to: peerNode,
            relationship: .trusted([context])
        )
        try await relation.save(on: db)
        _ = try await client.fulfillWorkspacePlanSlot(
            record,
            planActionID: createID,
            withActionID: localAction.requireID()
        )

        let finalized = try await client.bindWorkspacePlanPeer(
            record,
            peerID: peerID,
            toNodeID: peerNodeID
        )

        // Binding consumed the invite; the sweep resolved the `.fromPeer`
        // slot from the peer's hosted action; the side note keeps it pending.
        #expect(!finalized)
        #expect(record.fulfillment.slotInvites.isEmpty)
        #expect(record.fulfillment.peerBindings[peerID] == peerNodeID)
        #expect(record.fulfillment.actionFulfillments[fromPeerID] != nil)

        // The role alias landed scoped to this context — the global name is
        // untouched.
        #expect(
            try await KeepTalkingClient.alias(
                for: .node(peerNodeID),
                scopeContextID: contextID,
                on: db
            ) == "Reviewer"
        )
        #expect(
            try await KeepTalkingClient.alias(for: .node(peerNodeID), on: db) == nil
        )

        // The fulfilled create-slot action was granted to the bound peer.
        let grants =
            try await KeepTalkingNodeRelationActionRelation
            .query(on: db)
            .all()
        #expect(grants.count == 1)

        // The last pending item completes → delete-on-complete removes the row.
        record.recordSideNoteApplied("sop")
        _ = try await client.finalizeWorkspacePlanRecordIfComplete(record)
        #expect(
            try await KeepTalkingClient.workspacePlanRecord(
                for: contextID,
                on: db
            ) == nil
        )
    }

    @Test("revise prunes invites for dropped peers and keeps survivors")
    func revisePrunesSlotInvites() throws {
        let peerID = UUID()
        let createID = UUID()
        let fromPeerID = UUID()
        let record = try KeepTalkingWorkspacePlanRecord(
            prompt: "write a paper",
            plan: makePlan(peerID: peerID, createID: createID, fromPeerID: fromPeerID)
        )
        record.recordContext(UUID())
        try record.recordSlotInvite(peerID)

        // A revision that keeps the peer keeps its standing invite.
        var kept = try #require(record.plan)
        kept.sideNotes = []
        try record.revise(kept)
        #expect(record.outstandingSlotInvites.keys.contains(peerID))

        // A revision that drops the peer prunes the invite with it.
        var dropped = try #require(record.plan)
        dropped.peers = []
        dropped.actions.removeAll { $0.id == fromPeerID }
        try record.revise(dropped)
        #expect(record.fulfillment.slotInvites.isEmpty)
    }
}
