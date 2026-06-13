import Foundation
import MCP

extension KeepTalkingClient {

    /// Reserved built-in action id for cross-node cancellation. A caller dispatches
    /// a call to this id (carrying the target requestID) over the ENCRYPTED
    /// action-call channel to ask a provider to stop an in-flight run — reusing the
    /// channel's auth + encryption rather than introducing a new envelope kind.
    static let cancelActionID = UUID(uuidString: "00000000-0000-0000-0000-000000434E4C")!

    static let cancelledBeforeArrivalCacheLimit = 256

    /// Cancelled result for a run stopped before/while running. `isError`, no
    /// content, and crucially NO `outputTransfers` — so a cancelled run never
    /// leaves a partial one-time-blob output for the caller to assemble.
    static func actionCallCancelledResult(
        _ request: KeepTalkingActionCallRequest
    ) -> KeepTalkingActionCallResult {
        KeepTalkingActionCallResult(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            actionID: request.call.action,
            content: [],
            isError: true,
            errorMessage: "cancelled"
        )
    }

    /// Provider-side handler for an incoming cancel (the reserved `cancelActionID`).
    /// Idempotent + authorized — only the run's ORIGINAL caller may cancel it.
    /// Runs entirely under `actionCallQueue` (the authority for the in-flight /
    /// completed / caller maps): completed → no-op; in-flight → `task.cancel()`
    /// (which cascades through the run's awaits into SkillScriptRunner's
    /// SIGTERM→SIGKILL); not-yet-arrived → recorded so the request short-circuits.
    func handleIncomingCancelRequest(
        _ request: KeepTalkingActionCallRequest
    ) -> KeepTalkingActionCallResult {
        guard
            let raw = request.call.arguments["target_request_id"]?.stringValue,
            let targetID = UUID(uuidString: raw)
        else {
            return Self.actionCallCancelledResult(request)
        }
        let canceller = request.callerNodeID
        var outcome = "before-arrival"
        actionCallQueue.sync {
            if completedIncomingActionCallResults[targetID] != nil {
                outcome = "already-completed"
                return  // already finished — idempotent no-op
            }
            if let task = inFlightIncomingActionCalls[targetID] {
                if incomingActionCallCallers[targetID] == canceller {
                    task.cancel()
                    outcome = "cancelled-in-flight"
                } else {
                    outcome = "caller-mismatch-ignored"
                }
            } else {
                recordCancelledBeforeArrivalLocked(targetID, canceller: canceller)
                outcome = "recorded-before-arrival"
            }
        }
        onLog?(
            "[action-cancel/recv] target=\(targetID.uuidString.prefix(8)) "
                + "caller=\(canceller.uuidString.prefix(8)) → \(outcome)")
        return KeepTalkingActionCallResult(
            requestID: request.id,
            contextID: request.contextID,
            callerNodeID: request.callerNodeID,
            targetNodeID: request.targetNodeID,
            actionID: Self.cancelActionID,
            content: [.text(text: "cancel accepted", annotations: nil, _meta: nil)],
            isError: false
        )
    }

    /// Consume a pre-arrival cancel for `request` iff it was issued by the SAME
    /// caller (authorization). Returns true when the request should short-circuit.
    func consumeCancelledBeforeArrival(
        for request: KeepTalkingActionCallRequest
    ) -> Bool {
        actionCallQueue.sync {
            guard cancelledBeforeArrival[request.id] == request.callerNodeID else {
                return false
            }
            cancelledBeforeArrival.removeValue(forKey: request.id)
            cancelledBeforeArrivalOrder.removeAll { $0 == request.id }
            return true
        }
    }

    /// MUST be called while holding `actionCallQueue`.
    private func recordCancelledBeforeArrivalLocked(_ targetID: UUID, canceller: UUID) {
        cancelledBeforeArrival[targetID] = canceller
        cancelledBeforeArrivalOrder.removeAll { $0 == targetID }
        cancelledBeforeArrivalOrder.append(targetID)
        while cancelledBeforeArrivalOrder.count > Self.cancelledBeforeArrivalCacheLimit {
            let evicted = cancelledBeforeArrivalOrder.removeFirst()
            cancelledBeforeArrival.removeValue(forKey: evicted)
        }
    }

    /// Tell a provider to stop an in-flight run (fire-and-forget). Sent over the
    /// encrypted action-call channel as the reserved `cancelActionID` call so a
    /// long remote run isn't orphaned when the caller's run is cancelled.
    func sendCancelFireAndForget(
        requestID: UUID,
        targetNodeID: UUID,
        contextID: UUID,
        reason: KeepTalkingActionCancelReason = .runAborted
    ) {
        let call = KeepTalkingActionCall(
            action: Self.cancelActionID,
            arguments: [
                "target_request_id": .string(requestID.uuidString.lowercased()),
                "reason": .string(reason.rawValue),
            ]
        )
        let request = KeepTalkingActionCallRequest(
            contextID: contextID,
            callerNodeID: config.node,
            targetNodeID: targetNodeID,
            call: call
        )
        onLog?(
            "[action-cancel/send] target_request=\(requestID.uuidString.prefix(8)) "
                + "to=\(targetNodeID.uuidString.prefix(8)) reason=\(reason.rawValue)")
        Task { [weak self] in
            try? await self?.sendRemoteActionCallRequest(
                request, deliveryDescription: "cancel")
        }
    }
}
