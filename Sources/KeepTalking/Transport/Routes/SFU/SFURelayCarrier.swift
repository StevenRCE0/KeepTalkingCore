import Foundation
import KeepTalkingSFUProtocol

/// Carries application-frame payloads between two peers through an
/// SFU-mediated relay channel. Replaces the role coturn used to play —
/// the SFU is already authenticated end-to-end and has presence info, so
/// it can forward opaque relay payloads without a separate TURN process.
///
/// Wire shape on the SFU is `RELAY_DATA` frames whose payload is whatever
/// the caller passes to `send`. Length framing is the SFU frame's own
/// length prefix; this carrier hands raw bytes through.
///
/// Lifetime: an opener calls `KeepTalkingBroadcastChannel.openRelay(to:)`
/// (not yet wired in `DirectChannel` — see [[direct-channel-relay-wiring]])
/// which returns a `RelayHandle`; the carrier owns that handle and tears
/// it down on `close()`.
public final class KeepTalkingSFURelayCarrier: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case opening
        case ready
        case closed(reason: UInt8)
        case failed(String)
    }

    public var onMessage: (@Sendable (Data) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    public let relayID: Data
    public let remotePeerPubkey: Data

    private let sendFn: @Sendable (_ relayID: Data, _ payload: Data) -> Void
    private let closeFn: @Sendable (_ relayID: Data, _ reason: UInt8) -> Void

    private var state: State = .opening {
        didSet { onState?(state) }
    }

    public init(
        relayID: Data,
        remotePeerPubkey: Data,
        send: @escaping @Sendable (_ relayID: Data, _ payload: Data) -> Void,
        close: @escaping @Sendable (_ relayID: Data, _ reason: UInt8) -> Void
    ) {
        self.relayID = relayID
        self.remotePeerPubkey = remotePeerPubkey
        self.sendFn = send
        self.closeFn = close
    }

    /// Marks the relay as ready. The opener calls this immediately after
    /// `openRelay` returns; the responder calls it on receipt of the
    /// `RELAY_OPEN` notification.
    public func markReady() {
        state = .ready
    }

    public func send(_ data: Data) {
        sendFn(relayID, data)
    }

    /// Invoked by the owning client on an inbound `RELAY_DATA` frame
    /// addressed to `relayID`.
    public func deliverInbound(_ data: Data) {
        onMessage?(data)
    }

    /// Invoked when the SFU forwards a `RELAY_CLOSE` from the partner.
    public func remoteClosed(reason: UInt8) {
        state = .closed(reason: reason)
    }

    public func close(reason: UInt8 = SFURelayCloseReason.normal) {
        guard case .closed = state else {
            closeFn(relayID, reason)
            state = .closed(reason: reason)
            return
        }
        // Already closed — idempotent.
    }
}
