import Foundation
import SwiftJUICE

/// Public P2P session backed by `swift-libjuice`. The whole point is to
/// prove a KT client can move bytes peer-to-peer with no LiveKitWebRTC
/// in the picture — just ICE for connectivity + raw UDP datagrams from
/// libjuice for the payload.
///
/// Phase-1 surface area: manual SDP exchange (same pattern Voice Lab uses
/// for WebRTC). The session emits its local SDP once gathering completes;
/// the caller pastes it to the peer via any side channel and feeds the
/// peer's SDP back in via `applyRemoteSDP`. Once both sides have done
/// that, ICE connectivity checks complete and `send(_:)` works.
///
/// Datagram semantics are *exactly* UDP — no streams, no retransmission,
/// no ordering guarantees beyond what the OS provides. A real production
/// route layered on top of this would wrap envelopes with the existing
/// `PacketFragmenter` + sequence numbers + acks. For the lab, raw send is
/// enough to demonstrate "the path works."
public final class KeepTalkingJuiceP2PSession: @unchecked Sendable {
    public enum State: Sendable, Equatable, CustomStringConvertible {
        case idle
        case gathering
        case localSDPReady
        case negotiating
        case connected
        case failed(String)
        case closed

        public var description: String {
            switch self {
                case .idle: return "idle"
                case .gathering: return "gathering"
                case .localSDPReady: return "localSDPReady"
                case .negotiating: return "negotiating"
                case .connected: return "connected"
                case .failed(let reason): return "failed(\(reason))"
                case .closed: return "closed"
            }
        }
    }

    public var onState: (@Sendable (State) -> Void)?
    public var onMessage: (@Sendable (Data) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    /// Fires exactly once, the moment libjuice produces a complete
    /// local SDP description (i.e. `localSDP` becomes non-empty). The
    /// `onState` callback is unreliable for this purpose: when remote
    /// SDP is applied before gathering finishes — the standard answerer
    /// path — libjuice's state can race past `.gathering` into
    /// `.negotiating` or `.connected` before `handleGatheringDone`
    /// runs, and that handler's `if case .gathering = state` guard
    /// silently drops the state-change emission. Callers who need to
    /// send their SDP to the peer should subscribe here, not to
    /// `onState(.localSDPReady)`.
    public var onLocalSDPReady: (@Sendable (String) -> Void)?

    public private(set) var state: State = .idle {
        didSet { onState?(state) }
    }
    public private(set) var localSDP: String = ""

    private let agent: ICEAgent
    private let lock = NSLock()
    private var localGatheringDone = false

    public init(
        stunServer: (host: String, port: UInt16)? = ("stun.l.google.com", 19302)
    ) throws {
        let config = ICEAgent.Configuration(
            concurrencyMode: .poll,
            stunServer: stunServer,
            turnServers: []
        )
        self.agent = try ICEAgent(configuration: config)

        agent.onStateChange = { [weak self] _, agentState in
            self?.handleAgentState(agentState)
        }
        agent.onCandidate = { [weak self] _, sdpLine in
            self?.emit("candidate: \(sdpLine)")
        }
        agent.onGatheringDone = { [weak self] _ in
            self?.handleGatheringDone()
        }
        agent.onReceive = { [weak self] _, data in
            self?.onMessage?(data)
        }
    }

    public func start() {
        do {
            try agent.gatherCandidates()
            state = .gathering
            emit("gathering candidates")
        } catch {
            state = .failed("gather: \(error.localizedDescription)")
        }
    }

    public func applyRemoteSDP(_ sdp: String) {
        do {
            try agent.setRemoteDescription(sdp)
            // libjuice's setRemoteDescription parses out remote candidates
            // and starts connectivity checks immediately, so we don't need
            // to additionally call addRemoteCandidate for each.
            state = .negotiating
            emit("applied remote SDP (\(sdp.count) bytes)")
        } catch {
            state = .failed("applyRemoteSDP: \(error.localizedDescription)")
        }
    }

    public func send(_ data: Data) throws {
        try agent.send(data)
    }

    public func sendText(_ text: String) throws {
        try send(Data(text.utf8))
    }

    public func close() {
        // ICEAgent cleans up on deinit; nothing to do here right now.
        // Keeping the method on the public surface so callers can request
        // a clean teardown when we wire one in later.
        state = .closed
        emit("closed")
    }

    public func selectedAddresses() -> (local: String, remote: String)? {
        agent.selectedAddresses()
    }

    // MARK: - Internal

    private func handleAgentState(_ s: ICEAgent.State) {
        emit("ice state=\(s)")
        switch s {
            case .disconnected:
                break
            case .gathering:
                state = .gathering
            case .connecting:
                state = .negotiating
            case .connected, .completed:
                state = .connected
            case .failed:
                state = .failed("ice failed")
        }
    }

    private func handleGatheringDone() {
        lock.lock()
        if localGatheringDone {
            lock.unlock()
            return
        }
        localGatheringDone = true
        do {
            let sdp = try agent.localDescription()
            localSDP = sdp
            // Don't downgrade if we're already connected/negotiating.
            let shouldFlipState: Bool
            if case .gathering = state {
                state = .localSDPReady
                shouldFlipState = true
            } else {
                shouldFlipState = false
            }
            lock.unlock()
            emit("local SDP ready (\(sdp.count) bytes)")
            // Fire the dedicated SDP-ready callback regardless of
            // whether the state label flipped. The state-flip is just
            // for UI; the SDP bytes are what callers actually need to
            // ship to the peer. Doing this outside the lock keeps
            // re-entrancy safe (callbacks often turn around and call
            // back into the session).
            _ = shouldFlipState  // value retained for clarity; both paths emit
            onLocalSDPReady?(sdp)
        } catch {
            state = .failed("localDescription: \(error.localizedDescription)")
            lock.unlock()
        }
    }

    private func emit(_ message: String) {
        let line = "[juice-p2p] \(message)"
        onLog?(line)
    }
}
