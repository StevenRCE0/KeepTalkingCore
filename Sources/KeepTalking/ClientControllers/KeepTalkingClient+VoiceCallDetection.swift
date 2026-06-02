import Foundation

// Hybrid "is a voice call happening here?" detection. Combines the three signals
// the client holds — a peer's announced presence, our in-memory active call
// records, and our own live session — into one answer. This is the single source
// of truth for both the toolbar Voice-button glow AND the gate that decides
// whether ContextMaintenance bothers running transcriptSyncing (no ongoing call ⇒
// no transcript sync, by construction — that's the "no passive heartbeat" rule).
extension KeepTalkingClient {

    /// True if a voice call is ongoing in `contextID`: a peer announced one
    /// (presence), we're tracking an active call record, or we have a live local
    /// session. Bystanders (not joined) still see `true` via presence.
    public func hasOngoingVoiceCall(in contextID: UUID) -> Bool {
        if voiceCallPresence.hasJoinableCall(in: contextID, excluding: config.node) {
            return true
        }
        if !ongoingVoiceSessionIDs(in: contextID).isEmpty {
            return true
        }
        if activeVoiceSession != nil, contextID == config.contextID {
            return true
        }
        return false
    }

    /// Session ids of in-memory active calls scoped to `contextID` — the sessions
    /// transcriptSyncing reconciles. Covers a participant and any bystander that
    /// has already received ≥1 line (which created the local record); a silent
    /// late-joining bystander self-heals on the next maintenance pass once a line
    /// arrives.
    public func ongoingVoiceSessionIDs(in contextID: UUID) -> [UUID] {
        voiceCalls.activeCalls()
            .filter { $0.contextID == contextID }
            .map(\.id)
    }
}
