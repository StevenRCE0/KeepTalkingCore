import Foundation

/// Tracks **which contexts have a joinable voice call** and **who's in
/// each one**, fed by inbound `voiceCallStarted` / `voiceCallEnded`
/// envelopes on the client's regular transport.
///
/// This is the bystander side of the voice presence picture: a peer who
/// has NOT started their own voice session can still observe, via this
/// registry, that there's a call in progress in a given context. The
/// chat toolbar uses it to light the Voice button.
public final class KeepTalkingVoiceCallPresenceRegistry: @unchecked Sendable {
    /// One row per active call participant.
    public struct Participant: Hashable, Sendable {
        public let nodeID: UUID
        public init(nodeID: UUID) {
            self.nodeID = nodeID
        }
    }

    /// Fires after every mutation. Argument is the affected contextID;
    /// callers re-read the current set via `participants(in:)`.
    public var onChange: (@Sendable (UUID) -> Void)?

    private let lock = NSLock()
    private var byContext: [UUID: Set<Participant>] = [:]

    public init() {}

    /// Current participants in `contextID`. Returns an empty set when
    /// nothing is known.
    public func participants(in contextID: UUID) -> Set<Participant> {
        lock.withLock {
            byContext[contextID] ?? []
        }
    }

    /// True if any peer (other than `excluding`) has announced an active
    /// call in `contextID`. Convenience for the toolbar button glow.
    public func hasJoinableCall(in contextID: UUID, excluding self: UUID) -> Bool {
        lock.withLock {
            guard let entries = byContext[contextID] else { return false }
            return entries.contains { $0.nodeID != `self` }
        }
    }

    /// Called by the envelope handler when a `voiceCallStarted` lands.
    /// Returns true if state actually changed.
    @discardableResult
    public func recordStarted(contextID: UUID, nodeID: UUID) -> Bool {
        let participant = Participant(nodeID: nodeID)
        let changed: Bool = lock.withLock {
            byContext[contextID, default: []].insert(participant).inserted
        }
        if changed { onChange?(contextID) }
        return changed
    }

    /// Called on `voiceCallEnded`.
    @discardableResult
    public func recordEnded(contextID: UUID, nodeID: UUID) -> Bool {
        let participant = Participant(nodeID: nodeID)
        let changed: Bool = lock.withLock {
            guard byContext[contextID]?.remove(participant) != nil else { return false }
            if byContext[contextID]?.isEmpty == true {
                byContext.removeValue(forKey: contextID)
            }
            return true
        }
        if changed { onChange?(contextID) }
        return changed
    }

    /// Reconcile best-effort presence against ground-truth liveness: drop every
    /// participant whose node isn't in `online`, across all contexts. Returns the
    /// contexts whose membership changed.
    ///
    /// Presence is fed solely by `voiceCallStarted`/`voiceCallEnded` envelopes, so
    /// a peer that vanished (crash, network loss, app kill) WITHOUT a clean
    /// `ended` leaves a **ghost** participant. A ghost otherwise sticks forever:
    /// it keeps a call from ever sealing (it vetoes both the active leave-probe and
    /// the passive stale sweep) and keeps the toolbar's joinable-call glow lit.
    /// The maintenance heartbeat calls this with `onlineNodeIDs()`, so a ghost
    /// clears once it ages out of liveness (last-seen older than the online
    /// timeout). A peer that merely missed a beat stays online and is untouched.
    @discardableResult
    public func retainOnline(_ online: Set<UUID>) -> [UUID] {
        let touched: [UUID] = lock.withLock {
            var hits: [UUID] = []
            for (contextID, entries) in byContext {
                let live = entries.filter { online.contains($0.nodeID) }
                guard live.count != entries.count else { continue }
                if live.isEmpty {
                    byContext.removeValue(forKey: contextID)
                } else {
                    byContext[contextID] = live
                }
                hits.append(contextID)
            }
            return hits
        }
        for contextID in touched { onChange?(contextID) }
        return touched
    }

    /// Drops every entry tied to `nodeID` across all contexts. Used when
    /// a peer disconnects from the chat transport — a call that survives
    /// a disconnect is fine, but a call we *only* know about because of
    /// a Started from a peer who has since vanished is stale.
    public func forgetNode(_ nodeID: UUID) {
        let touched: [UUID] = lock.withLock {
            var hits: [UUID] = []
            for (contextID, entries) in byContext {
                let participant = Participant(nodeID: nodeID)
                guard entries.contains(participant) else { continue }
                byContext[contextID]?.remove(participant)
                if byContext[contextID]?.isEmpty == true {
                    byContext.removeValue(forKey: contextID)
                }
                hits.append(contextID)
            }
            return hits
        }
        for contextID in touched { onChange?(contextID) }
    }
}
