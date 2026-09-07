import FluentKit
import Foundation

// MARK: - Workspace plan records
//
// Storage surface for `KeepTalkingWorkspacePlanRecord`. Fulfilled records are
// deleted on completion (host-driven), so any stored record is pending by
// invariant — there is no completed/archived query.

extension KeepTalkingClient {
    /// The newest pending plan record established into the given context.
    public static func workspacePlanRecord(
        for contextID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingWorkspacePlanRecord? {
        try await KeepTalkingWorkspacePlanRecord.query(on: database)
            .filter(\.$context.$id == contextID)
            .sort(\.$updatedAt, .descending)
            .first()
    }

    public func workspacePlanRecord(
        for contextID: UUID
    ) async throws -> KeepTalkingWorkspacePlanRecord? {
        try await Self.workspacePlanRecord(
            for: contextID,
            on: localStore.database
        )
    }

    /// Plan records whose context hasn't been established yet (`context IS
    /// NULL`) — plans exist before their contexts do.
    public static func unestablishedWorkspacePlanRecords(
        on database: any Database
    ) async throws -> [KeepTalkingWorkspacePlanRecord] {
        try await KeepTalkingWorkspacePlanRecord.query(on: database)
            .filter(\.$context.$id == nil)
            .sort(\.$updatedAt, .descending)
            .all()
    }

    public func unestablishedWorkspacePlanRecords()
        async throws -> [KeepTalkingWorkspacePlanRecord]
    {
        try await Self.unestablishedWorkspacePlanRecords(on: localStore.database)
    }

    public static func saveWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord,
        on database: any Database
    ) async throws {
        try await record.save(on: database)
    }

    public func saveWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws {
        try await Self.saveWorkspacePlanRecord(record, on: localStore.database)
    }

    public static func deleteWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord,
        on database: any Database
    ) async throws {
        try await record.delete(on: database)
    }

    public func deleteWorkspacePlanRecord(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws {
        try await Self.deleteWorkspacePlanRecord(record, on: localStore.database)
    }
}

// MARK: - Plan progression
//
// The orchestration layer over the record's pure state ops: binding peers,
// fulfilling slots, applying grants, the `.fromPeer` sweep, and
// delete-on-complete. Instance-only — grants broadcast through this client
// and the trust gate reads the live relation rows, so a host drives these on
// the context's client rather than re-implementing them per surface.

extension KeepTalkingClient {
    /// Binds a ghost peer slot to a trusted node and runs the whole
    /// progression: DB-truth trust gate, binding (which also consumes any
    /// standing slot invite), save, grants of the peer's already-fulfilled
    /// `grantedActions`, the slot alias written as the node's per-context
    /// alias (scoped only — the global alias is untouched), the `.fromPeer`
    /// sweep, and delete-on-complete. Returns whether the record finalized.
    ///
    /// The binding persists even when grant application fails — the error is
    /// rethrown after the alias write and sweep so callers can surface it
    /// without losing the bind.
    @discardableResult
    public func bindWorkspacePlanPeer(
        _ record: KeepTalkingWorkspacePlanRecord,
        peerID: UUID,
        toNodeID nodeID: UUID
    ) async throws -> Bool {
        guard let contextID = record.contextID else {
            throw KeepTalkingWorkspacePlanError.contextNotEstablished
        }
        guard
            try await Self.trustAlreadyCovers(
                from: config.node,
                to: nodeID,
                contextID: contextID,
                on: localStore.database
            )
        else {
            throw KeepTalkingWorkspacePlanError.nodeNotTrusted(nodeID)
        }

        _ = try record.recordBinding(peerID: peerID, nodeID: nodeID)
        try await record.save(on: localStore.database)

        var grantError: (any Error)?
        do {
            try await applyWorkspacePlanPeerGrants(
                record,
                peerID: peerID,
                toNodeID: nodeID
            )
        } catch {
            grantError = error
        }

        if let alias = record.plan?.peers.first(where: { $0.id == peerID })?.alias {
            try? await setAlias(
                alias,
                for: .node(nodeID),
                scopeContextID: contextID
            )
        }

        _ = try await sweepWorkspacePlanFromPeerSlots(record)
        let finalized = try await finalizeWorkspacePlanRecordIfComplete(record)
        if let grantError { throw grantError }
        return finalized
    }

    /// Grants every already-fulfilled action in the peer's `grantedActions`
    /// to the bound node through the grant-transaction path (context-scoped
    /// entries ride the staging lane, like every workbench grant).
    public func applyWorkspacePlanPeerGrants(
        _ record: KeepTalkingWorkspacePlanRecord,
        peerID: UUID,
        toNodeID nodeID: UUID
    ) async throws {
        guard
            let contextID = record.contextID,
            let peer = record.plan?.peers.first(where: { $0.id == peerID }),
            !peer.grantedActions.isEmpty
        else { return }

        let fulfillments = record.fulfillment.actionFulfillments
        var transaction = KeepTalkingGrantTransaction()
        for slotID in peer.grantedActions {
            guard let realActionID = fulfillments[slotID] else { continue }
            transaction.grant(in: contextID, actionID: realActionID, to: nodeID)
        }
        guard !transaction.isEmpty else { return }
        try await grantActionPermission(transaction: transaction, lane: .plan)
    }

    /// Records a realized action against its plan slot, grants it to every
    /// bound peer whose slot lists it (best-effort, like all plan grants to
    /// already-bound peers), and finalizes. Returns whether the record
    /// finalized.
    @discardableResult
    public func fulfillWorkspacePlanSlot(
        _ record: KeepTalkingWorkspacePlanRecord,
        planActionID: UUID,
        withActionID actionID: UUID
    ) async throws -> Bool {
        try record.fulfill(planActionID: planActionID, withActionID: actionID)
        try await record.save(on: localStore.database)

        if let contextID = record.contextID, let plan = record.plan {
            let bindings = record.fulfillment.peerBindings
            var transaction = KeepTalkingGrantTransaction()
            for peer in plan.peers where peer.grantedActions.contains(planActionID) {
                guard let nodeID = bindings[peer.id] else { continue }
                transaction.grant(in: contextID, actionID: actionID, to: nodeID)
            }
            if !transaction.isEmpty {
                try? await grantActionPermission(transaction: transaction, lane: .plan)
            }
        }
        return try await finalizeWorkspacePlanRecordIfComplete(record)
    }

    /// Resolves pending `.fromPeer` slots whose peer is bound: when the bound
    /// node hosts an action whose label matches the slot name
    /// (case-insensitive — the same proxy capability matching uses), the slot
    /// fulfills with it. This is the only path that completes a plan
    /// containing peer-sourced actions. Returns the number fulfilled.
    @discardableResult
    public func sweepWorkspacePlanFromPeerSlots(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws -> Int {
        guard record.contextID != nil, let plan = record.plan else { return 0 }
        let state = record.fulfillment

        var fulfilled = 0
        for slot in plan.actions {
            guard
                state.actionFulfillments[slot.id] == nil,
                case .fromPeer(let peerID) = slot.source,
                let nodeID = state.peerBindings[peerID]
            else { continue }

            let hosted = try await KeepTalkingAction.query(on: localStore.database)
                .filter(\.$node.$id == nodeID)
                .all()
            guard
                let match = hosted.first(where: {
                    $0.actionLabel.caseInsensitiveCompare(slot.name) == .orderedSame
                }),
                let matchID = match.id
            else { continue }

            try record.fulfill(planActionID: slot.id, withActionID: matchID)
            fulfilled += 1
        }

        guard fulfilled > 0 else { return 0 }
        try await record.save(on: localStore.database)
        _ = try await finalizeWorkspacePlanRecordIfComplete(record)
        return fulfilled
    }

    /// Delete-on-complete: a totally fulfilled record is removed — every
    /// stored record is pending by invariant, and a vanished record is what
    /// hides the plan's slot surfaces. Returns whether it deleted. A later
    /// `revise` on a held instance re-creates the row (Fluent clears the
    /// id-exists flag on delete).
    @discardableResult
    public func finalizeWorkspacePlanRecordIfComplete(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws -> Bool {
        guard record.isComplete else { return false }
        try await record.delete(on: localStore.database)
        return true
    }

    /// Upserts the plan's pending side notes into the established context,
    /// recording each applied key. The caller saves the record.
    public func applyWorkspacePlanSideNotes(
        _ record: KeepTalkingWorkspacePlanRecord
    ) async throws {
        guard let contextID = record.contextID else {
            throw KeepTalkingWorkspacePlanError.contextNotEstablished
        }
        for note in record.pendingSideNotes {
            _ = try await upsertSideNote(
                key: note.key,
                value: note.value,
                in: contextID
            )
            record.recordSideNoteApplied(note.key)
        }
    }

    /// Asks the node bound to a `.fromPeer` slot's peer to build that action
    /// on their side — the slot's own auto-curation, run on their device
    /// through the shared action-creation capability.
    ///
    /// `nodeID` names who to ask; hosts pass the slot's bound node, or another
    /// bound peer the user picked instead. The peer grants the result back, so
    /// a named action id fulfills the slot outright; without one the label
    /// sweep still gets a chance. Returns the realized action id when the slot
    /// fulfilled.
    @discardableResult
    public func requestWorkspacePlanPeerAction(
        _ record: KeepTalkingWorkspacePlanRecord,
        planActionID: UUID,
        fromNodeID nodeID: UUID
    ) async throws -> UUID? {
        guard let contextID = record.contextID else {
            throw KeepTalkingWorkspacePlanError.contextNotEstablished
        }
        guard
            let plan = record.plan,
            let slot = plan.actions.first(where: { $0.id == planActionID })
        else {
            throw KeepTalkingWorkspacePlanError.unknownPlanAction(planActionID)
        }
        guard
            let context = try await KeepTalkingContext.find(
                contextID,
                on: localStore.database
            )
        else {
            throw KeepTalkingWorkspacePlanError.contextNotConnected(contextID)
        }

        let intention = [slot.name, slot.description ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{2014} ")
        let createdActionID = try await requestActionCreation(
            onNodeID: nodeID,
            intention: intention,
            in: context
        )

        guard let createdActionID else {
            // The peer built something but named no id; the label sweep is
            // the remaining route to a fulfilled slot.
            _ = try await sweepWorkspacePlanFromPeerSlots(record)
            return record.fulfillment.actionFulfillments[planActionID]
        }
        _ = try await fulfillWorkspacePlanSlot(
            record,
            planActionID: planActionID,
            withActionID: createdActionID
        )
        return createdActionID
    }
}
