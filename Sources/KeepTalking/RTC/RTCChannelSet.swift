import Foundation
import LiveKitWebRTC

/// Manages outbound/inbound data channel pairs for each `KeepTalkingEnvelopeChannel`.
///
/// Both the SFU and P2P transports share the same pattern: each logical channel
/// (chat, blob, actionCall, signaling) has an outbound channel the local peer
/// created and an inbound channel opened by the remote side.
///
/// **Strict open-only policy**: `preferred(for:)` only returns a channel that
/// is currently `.open`.  Callers never receive a closed/closing channel.
struct RTCChannelSet {

    private var outbound: [KeepTalkingEnvelopeChannel: LKRTCDataChannel] = [:]
    private var inbound: [KeepTalkingEnvelopeChannel: LKRTCDataChannel] = [:]

    // MARK: - Mutation

    mutating func setOutbound(
        _ channel: LKRTCDataChannel,
        for kind: KeepTalkingEnvelopeChannel
    ) {
        outbound[kind] = channel
    }

    mutating func setInbound(
        _ channel: LKRTCDataChannel,
        for kind: KeepTalkingEnvelopeChannel
    ) {
        inbound[kind] = channel
    }

    /// Remove a channel that has closed/failed so `preferred()` no longer
    /// returns it.  Matches by object identity.
    mutating func removeChannel(_ channel: LKRTCDataChannel) {
        for (kind, ch) in outbound where ch === channel {
            outbound.removeValue(forKey: kind)
        }
        for (kind, ch) in inbound where ch === channel {
            inbound.removeValue(forKey: kind)
        }
    }

    // MARK: - Queries

    /// Returns the best **open** channel for sending on `kind`, or `nil`.
    /// Prefers inbound when open; falls back to outbound only if also open.
    func preferred(for kind: KeepTalkingEnvelopeChannel) -> LKRTCDataChannel? {
        if let ch = inbound[kind], ch.readyState == .open {
            return ch
        }
        if let ch = outbound[kind], ch.readyState == .open {
            return ch
        }
        return nil
    }

    /// True when at least one channel exists for `kind` and every present
    /// channel (outbound and/or inbound) is open.
    func isOpen(for kind: KeepTalkingEnvelopeChannel) -> Bool {
        let present = [outbound[kind], inbound[kind]].compactMap { $0 }
        guard !present.isEmpty else { return false }
        return present.allSatisfy { $0.readyState == .open }
    }

    /// True when a channel for `kind` exists (regardless of state).
    func hasChannel(for kind: KeepTalkingEnvelopeChannel) -> Bool {
        outbound[kind] != nil || inbound[kind] != nil
    }

    /// All channels currently stored (outbound + inbound).
    var allChannels: [LKRTCDataChannel] {
        Array(outbound.values) + Array(inbound.values)
    }

    var channelCount: Int {
        allChannels.count
    }

    // MARK: - Lifecycle

    mutating func clearDelegates() {
        for channel in allChannels {
            channel.delegate = nil
        }
    }

    mutating func closeAll() {
        for channel in allChannels {
            channel.close()
        }
    }

    mutating func removeAll() {
        outbound.removeAll()
        inbound.removeAll()
    }

    // MARK: - Diagnostics

    func stateSummary(for kinds: [KeepTalkingEnvelopeChannel]) -> String {
        kinds.map { kind in
            let name: String
            switch kind {
                case .chat: name = "chat"
                case .blob: name = "blob"
                case .actionCall: name = "action"
                case .signaling: name = "signaling"
            }
            let out = outbound[kind].map { String($0.readyState.rawValue) }
                ?? "nil"
            let `in` = inbound[kind].map { String($0.readyState.rawValue) }
                ?? "nil"
            return "\(name)[out=\(out) in=\(`in`)]"
        }.joined(separator: " ")
    }
}
