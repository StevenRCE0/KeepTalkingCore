import Foundation

/// Wire-level fragmentation for envelope data channels.
///
/// WebRTC/SCTP enforces a per-message size ceiling that can be as low as
/// 16 KB depending on the libwebrtc/browser implementation. Encrypted
/// envelopes — particularly `messagesResult` carrying chat history with
/// large tool outputs or `sideNotesResult` with many notes — easily exceed
/// this and get silently dropped by `LKRTCDataChannel.sendData`.
///
/// `PacketFragmenter` splits outgoing encrypted payloads into fixed-size
/// frames prefixed with a small header (group UUID + index + total) and the
/// receiver reassembles them before handing the payload to the envelope
/// crypto. Single-fragment sends are wrapped too, so the receive path is
/// uniform: every envelope-channel buffer goes through the reassembler.
///
/// The blob channel is exempt — blobs have their own chunking model at a
/// higher level and use the binary data-buffer path directly.
enum PacketFragmenter {
    /// 4-byte magic prefix: ASCII "KTFR". Distinguishes fragment frames from
    /// arbitrary encrypted payload bytes; 32 bits of magic keeps random
    /// collision probability below ~10⁻⁹.
    static let magic: [UInt8] = [0x4B, 0x54, 0x46, 0x52]
    static let version: UInt8 = 0x01
    /// 4 magic + 1 version + 16 group UUID + 4 index BE + 4 total BE.
    static let headerBytes: Int = 4 + 1 + 16 + 4 + 4
    /// Conservative per-fragment ceiling used before SDP negotiation reveals
    /// the peer's `a=max-message-size`. 16 KB is the universal-safe baseline
    /// — most libwebrtc builds negotiate up to ~256 KB, which the RTC client
    /// picks up via `parseMaxMessageSize(fromSDP:)` after each
    /// `setRemoteDescription`.
    static let defaultMaxFragmentBytes: Int = 16 * 1024
    /// Hard upper bound regardless of what the peer advertises. Bounds the
    /// reassembler memory cost (`total * maxPayloadPerFragment` per group).
    static let absoluteMaxFragmentBytes: Int = 256 * 1024

    /// Splits `payload` into one or more fragment frames, each safely below
    /// the per-message ceiling for this peer. Returns at least one frame
    /// even for an empty payload so the receiver still observes the group.
    static func fragments(
        for payload: Data,
        id: UUID = UUID(),
        maxFragmentBytes: Int = defaultMaxFragmentBytes
    ) -> [Data] {
        let cap = max(
            headerBytes + 1,
            min(maxFragmentBytes, absoluteMaxFragmentBytes)
        )
        let chunkSize = cap - headerBytes
        if payload.isEmpty {
            return [makeFrame(id: id, index: 0, total: 1, payload: Data())]
        }
        var chunks: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            chunks.append(payload.subdata(in: offset..<end))
            offset = end
        }
        let total = UInt32(chunks.count)
        return chunks.enumerated().map { idx, chunk in
            makeFrame(
                id: id,
                index: UInt32(idx),
                total: total,
                payload: chunk
            )
        }
    }

    /// Extracts `a=max-message-size:N` from an SDP blob, per RFC 8841.
    /// Returns nil if the attribute is absent or unparseable, in which case
    /// callers should keep using `defaultMaxFragmentBytes` (libwebrtc's own
    /// internal default if missing is ~256 KB, but we stay conservative).
    static func parseMaxMessageSize(fromSDP sdp: String) -> Int? {
        for line in sdp.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "a=max-message-size:"
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
            guard let parsed = Int(value), parsed > 0 else { return nil }
            return parsed
        }
        return nil
    }

    private static func makeFrame(
        id: UUID,
        index: UInt32,
        total: UInt32,
        payload: Data
    ) -> Data {
        var frame = Data(capacity: headerBytes + payload.count)
        frame.append(contentsOf: magic)
        frame.append(version)
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { frame.append(contentsOf: $0) }
        var indexBE = index.bigEndian
        withUnsafeBytes(of: &indexBE) { frame.append(contentsOf: $0) }
        var totalBE = total.bigEndian
        withUnsafeBytes(of: &totalBE) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    struct Frame {
        let groupID: UUID
        let index: UInt32
        let total: UInt32
        let payload: Data
    }

    /// Parses a single received frame. Returns `nil` when the data doesn't
    /// match the fragment wire format — callers should drop those buffers.
    static func parseFrame(_ data: Data) -> Frame? {
        guard data.count >= headerBytes else { return nil }
        let base = data.startIndex
        guard Array(data[base..<(base + 4)]) == magic else { return nil }
        guard data[base + 4] == version else { return nil }
        let uuidBase = base + 5
        let uuidBytes: uuid_t = (
            data[uuidBase], data[uuidBase + 1], data[uuidBase + 2], data[uuidBase + 3],
            data[uuidBase + 4], data[uuidBase + 5], data[uuidBase + 6], data[uuidBase + 7],
            data[uuidBase + 8], data[uuidBase + 9], data[uuidBase + 10], data[uuidBase + 11],
            data[uuidBase + 12], data[uuidBase + 13], data[uuidBase + 14], data[uuidBase + 15]
        )
        let groupID = UUID(uuid: uuidBytes)
        let indexStart = uuidBase + 16
        let totalStart = indexStart + 4
        let payloadStart = totalStart + 4
        let index = UInt32(
            bigEndian: data.subdata(in: indexStart..<totalStart).withUnsafeBytes {
                $0.load(as: UInt32.self)
            })
        let total = UInt32(
            bigEndian: data.subdata(in: totalStart..<payloadStart).withUnsafeBytes {
                $0.load(as: UInt32.self)
            })
        guard total > 0, index < total else { return nil }
        let payload = data.subdata(in: payloadStart..<data.endIndex)
        return Frame(groupID: groupID, index: index, total: total, payload: payload)
    }

    /// Receive-side reassembler. Holds incomplete groups keyed by UUID and
    /// emits the concatenated payload once every fragment of a group has
    /// arrived. Thread-safe; safe to call from any data-channel delegate.
    final class Reassembler: @unchecked Sendable {
        private struct PartialGroup {
            let total: Int
            var fragments: [Int: Data]
            let createdAt: Date
        }

        private var groups: [UUID: PartialGroup] = [:]
        private let ttl: TimeInterval = 30
        private let queue = DispatchQueue(label: "KeepTalking.PacketFragmenter.Reassembler")

        /// Feeds an inbound data-channel buffer. Returns the complete
        /// payload when the final fragment of a group arrives; returns
        /// `nil` when the buffer is not a fragment frame, or when the
        /// group is still incomplete.
        func feed(_ data: Data) -> Data? {
            guard let frame = PacketFragmenter.parseFrame(data) else { return nil }
            return queue.sync {
                evictExpired()
                if frame.total == 1 {
                    return frame.payload
                }
                var group =
                    groups[frame.groupID]
                    ?? PartialGroup(
                        total: Int(frame.total),
                        fragments: [:],
                        createdAt: Date()
                    )
                group.fragments[Int(frame.index)] = frame.payload
                if group.fragments.count == group.total {
                    groups[frame.groupID] = nil
                    var reassembled = Data()
                    for i in 0..<group.total {
                        guard let chunk = group.fragments[i] else { return nil }
                        reassembled.append(chunk)
                    }
                    return reassembled
                }
                groups[frame.groupID] = group
                return nil
            }
        }

        private func evictExpired() {
            let cutoff = Date().addingTimeInterval(-ttl)
            for (id, group) in groups where group.createdAt < cutoff {
                groups[id] = nil
            }
        }
    }
}
