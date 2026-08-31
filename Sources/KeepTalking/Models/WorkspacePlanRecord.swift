import FluentKit
import Foundation

// MARK: - Fulfillment state

/// Everything the plan has realized so far. Ids reference plan items; a pruned
/// plan item (after `revise`) drops its fulfillment with it.
public struct KeepTalkingWorkspacePlanFulfillment: Codable, Sendable {
    /// The established context, once the host records it. Mirrors the record's
    /// `context` column; the column is the queryable source of truth.
    public var contextID: UUID?
    /// Plan action id → realized `KeepTalkingAction` id.
    public var actionFulfillments: [UUID: UUID] = [:]
    /// Peer slot id → bound node id. An entry here is what turns a ghost into
    /// a real peer.
    public var peerBindings: [UUID: UUID] = [:]
    /// Side-note keys already upserted into the context.
    public var appliedSideNoteKeys: [String] = []
    /// Peer slot id → when an invite link for that slot was last shared. An
    /// entry is a standing newcomer invite (the host auto-accepts trust
    /// requests in the context while any exist); binding the slot clears it.
    public var slotInvites: [UUID: Date] = [:]

    public init() {}

    /// Tolerant decoding: every field falls back to its default so blobs
    /// written before a field existed keep the progress they recorded. The
    /// record's `fulfillment` accessor treats a decode failure as a FRESH
    /// state, so a thrown missing-key error here would silently wipe
    /// fulfillment. Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextID = try container.decodeIfPresent(UUID.self, forKey: .contextID)
        actionFulfillments =
            try container.decodeIfPresent(
                [UUID: UUID].self,
                forKey: .actionFulfillments
            ) ?? [:]
        peerBindings =
            try container.decodeIfPresent(
                [UUID: UUID].self,
                forKey: .peerBindings
            ) ?? [:]
        appliedSideNoteKeys =
            try container.decodeIfPresent(
                [String].self,
                forKey: .appliedSideNoteKeys
            ) ?? []
        slotInvites =
            try container.decodeIfPresent(
                [UUID: Date].self,
                forKey: .slotInvites
            ) ?? [:]
    }
}

public enum KeepTalkingWorkspacePlanError: LocalizedError, Sendable {
    case corruptPlan
    case contextNotEstablished
    case contextNotConnected(UUID)
    case unknownPlanAction(UUID)
    case unknownPeerSlot(UUID)
    case nodeNotTrusted(UUID)

    public var errorDescription: String? {
        switch self {
            case .corruptPlan:
                return "The stored workspace plan couldn't be read."
            case .contextNotEstablished:
                return "Set up the context before applying this step."
            case .contextNotConnected:
                return "The plan's context isn't connected."
            case .unknownPlanAction, .unknownPeerSlot:
                return "This item is no longer part of the plan."
            case .nodeNotTrusted:
                return "Trust this peer before binding them."
        }
    }
}

// MARK: - Record

/// Persistent record for one powerhouse workspace plan. The
/// `KeepTalkingWorkspacePlan` value is the immutable shape the plan agent
/// produced; this record wraps it with fulfillment state and the pure state
/// ops the host drives as pieces get realized (context established, actions
/// created, ghost peers bound to real nodes).
///
/// The SDK value types are encoded verbatim into Data columns so a payload
/// that stops decoding degrades to `corruptPlan` instead of failing every
/// query. Ghost peers never touch `kt_nodes` — binding records the mapping
/// here and the host runs the normal trust/grant flows against the realized
/// node.
///
/// A totally fulfilled record is deleted rather than kept: every stored row is
/// pending by invariant, and completion is the host's cue to remove it.
public final class KeepTalkingWorkspacePlanRecord: Model, @unchecked Sendable {
    public static let schema = "kt_workspace_plans"

    @ID(key: .id)
    public var id: UUID?

    /// The established context. Nil until the plan's context is created or
    /// adopted — a plan exists before its context does. Deleting the context
    /// cascades the plan away with it.
    @OptionalParent(key: "context")
    public var context: KeepTalkingContext?

    /// The user's original intent, verbatim — what the plan agent decomposed.
    @Field(key: "prompt")
    public var prompt: String

    /// Encoded `KeepTalkingWorkspacePlan` (the agent's current revision).
    @Field(key: "plan_data")
    public var planData: Data

    /// Encoded `KeepTalkingWorkspacePlanFulfillment`.
    @Field(key: "state_data")
    public var stateData: Data

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(prompt: String, plan: KeepTalkingWorkspacePlan) throws {
        self.id = UUID.v7()
        self.prompt = prompt
        self.planData = try JSONEncoder().encode(plan)
        self.stateData = try JSONEncoder().encode(
            KeepTalkingWorkspacePlanFulfillment()
        )
    }
}

// MARK: - Decoded accessors

extension KeepTalkingWorkspacePlanRecord {
    /// Decodes the stored plan. Nil if the data is corrupt.
    public var plan: KeepTalkingWorkspacePlan? {
        try? JSONDecoder().decode(KeepTalkingWorkspacePlan.self, from: planData)
    }

    public var fulfillment: KeepTalkingWorkspacePlanFulfillment {
        (try? JSONDecoder().decode(
            KeepTalkingWorkspacePlanFulfillment.self,
            from: stateData
        ))
            ?? KeepTalkingWorkspacePlanFulfillment()
    }

    private func write(_ fulfillment: KeepTalkingWorkspacePlanFulfillment) {
        if let data = try? JSONEncoder().encode(fulfillment) {
            stateData = data
        }
    }

    // MARK: Progress

    /// The established context id, read from the queryable column.
    public var contextID: UUID? { $context.id }

    /// Plan actions not yet realized. `.fromPeer` slots whose peer slot is
    /// still unbound (a "ghost") are pending by definition — they can't be
    /// requested yet.
    public var pendingActions: [KeepTalkingWorkspacePlan.Action] {
        guard let plan else { return [] }
        let state = fulfillment
        return plan.actions.filter { state.actionFulfillments[$0.id] == nil }
    }

    /// Peer slots not yet bound to a real node — the plan's ghosts.
    public var unboundPeers: [KeepTalkingWorkspacePlan.Peer] {
        guard let plan else { return [] }
        let state = fulfillment
        return plan.peers.filter { state.peerBindings[$0.id] == nil }
    }

    public var pendingSideNotes: [KeepTalkingWorkspacePlan.SideNoteEntry] {
        guard let plan else { return [] }
        let applied = Set(fulfillment.appliedSideNoteKeys)
        return plan.sideNotes.filter { !applied.contains($0.key) }
    }

    /// True once every plan item is realized — the host's cue to delete the
    /// record (fulfilled plans aren't kept).
    public var isComplete: Bool {
        guard let plan else { return false }
        guard contextID != nil else { return false }
        let state = fulfillment
        return plan.actions.allSatisfy { state.actionFulfillments[$0.id] != nil }
            && plan.peers.allSatisfy { state.peerBindings[$0.id] != nil }
            && pendingSideNotes.isEmpty
    }

    /// Realized items over total items, for progress affordances.
    public var progressFraction: Double {
        guard let plan else { return 0 }
        let state = fulfillment
        // Context counts as one item alongside actions, peers, and notes.
        let total = 1 + plan.actions.count + plan.peers.count + plan.sideNotes.count
        var done = contextID == nil ? 0 : 1
        done += state.actionFulfillments.count
        done += state.peerBindings.count
        done += state.appliedSideNoteKeys.count
        return total == 0 ? 1 : Double(done) / Double(total)
    }

    // MARK: State progression (pure)

    /// Records the established context — both the queryable column and the
    /// fulfillment mirror.
    public func recordContext(_ contextID: UUID) {
        $context.id = contextID
        var state = fulfillment
        state.contextID = contextID
        write(state)
    }

    /// Records one applied side note key.
    public func recordSideNoteApplied(_ key: String) {
        var state = fulfillment
        guard !state.appliedSideNoteKeys.contains(key) else { return }
        state.appliedSideNoteKeys.append(key)
        write(state)
    }

    /// Records that an invite link was shared for a peer slot. The entry is a
    /// standing newcomer invite; `recordBinding` clears it when the slot
    /// resolves.
    public func recordSlotInvite(_ peerID: UUID) throws {
        guard let plan else { throw KeepTalkingWorkspacePlanError.corruptPlan }
        guard plan.peers.contains(where: { $0.id == peerID }) else {
            throw KeepTalkingWorkspacePlanError.unknownPeerSlot(peerID)
        }
        var state = fulfillment
        state.slotInvites[peerID] = Date()
        write(state)
    }

    /// Withdraws a slot's standing invite.
    public func clearSlotInvite(_ peerID: UUID) {
        var state = fulfillment
        guard state.slotInvites.removeValue(forKey: peerID) != nil else { return }
        write(state)
    }

    /// Shared invites whose slots are still unbound — the ones a newcomer's
    /// trust request can claim.
    public var outstandingSlotInvites: [UUID: Date] {
        let unbound = Set(unboundPeers.map(\.id))
        return fulfillment.slotInvites.filter { unbound.contains($0.key) }
    }

    public var hasOutstandingSlotInvites: Bool {
        !outstandingSlotInvites.isEmpty
    }

    /// Records a realized action against its plan slot. The action may have
    /// come from Auto Curate (create), an existing pick, or a peer grant — the
    /// record doesn't care how it materialized, only that it now exists.
    public func fulfill(planActionID: UUID, withActionID actionID: UUID) throws {
        guard let plan else { throw KeepTalkingWorkspacePlanError.corruptPlan }
        guard plan.actions.contains(where: { $0.id == planActionID }) else {
            throw KeepTalkingWorkspacePlanError.unknownPlanAction(planActionID)
        }
        var state = fulfillment
        state.actionFulfillments[planActionID] = actionID
        write(state)
    }

    /// Records a peer-slot → node binding and returns the plan actions the
    /// binding unblocks (`.fromPeer` slots), so the caller can kick grant
    /// requests toward the bound node. Trust validation happens host-side.
    @discardableResult
    public func recordBinding(
        peerID: UUID,
        nodeID: UUID
    ) throws -> [KeepTalkingWorkspacePlan.Action] {
        guard let plan else { throw KeepTalkingWorkspacePlanError.corruptPlan }
        guard plan.peers.contains(where: { $0.id == peerID }) else {
            throw KeepTalkingWorkspacePlanError.unknownPeerSlot(peerID)
        }

        var state = fulfillment
        state.peerBindings[peerID] = nodeID
        state.slotInvites[peerID] = nil
        write(state)

        let fulfilled = state.actionFulfillments
        return plan.actions.filter {
            if case .fromPeer(let slotID) = $0.source {
                return slotID == peerID && fulfilled[$0.id] == nil
            }
            return false
        }
    }

    /// Replaces the plan with the agent's revision (follow-up turns). Realized
    /// work survives where the revised plan kept the item; fulfillments whose
    /// items were dropped are pruned. A revision that adds work reopens a plan
    /// the host was about to complete.
    public func revise(_ newPlan: KeepTalkingWorkspacePlan) throws {
        planData = try JSONEncoder().encode(newPlan)

        var state = fulfillment
        let actionIDs = Set(newPlan.actions.map(\.id))
        let peerIDs = Set(newPlan.peers.map(\.id))
        let noteKeys = Set(newPlan.sideNotes.map(\.key))
        state.actionFulfillments = state.actionFulfillments.filter {
            actionIDs.contains($0.key)
        }
        state.peerBindings = state.peerBindings.filter {
            peerIDs.contains($0.key)
        }
        state.slotInvites = state.slotInvites.filter {
            peerIDs.contains($0.key)
        }
        state.appliedSideNoteKeys = state.appliedSideNoteKeys.filter {
            noteKeys.contains($0)
        }
        write(state)
    }
}
