import Foundation

/// Frames on a peer link (ALPN `keeptalking/peer/2`).
///
/// Every unidirectional stream starts with one byte saying what it carries:
///
/// - a **lane** (`KeepTalkingEnvelopeDelivery.Lane`): control and interactive
///   are long-lived, one per direction; a bulk stream carries one frame and
///   ends, so a large page never blocks anything. Frames on a lane are
///   `[u32 BE length][kind][topic(32)][payload]`.
/// - a **blob transfer** (`blobStream`), followed by its topic: one transfer
///   per stream, `[u32 BE length][sealed]` frames, the first being the
///   header; finishing the stream completes the transfer, resetting it
///   cancels.
///
/// Envelopes are sealed with the topic's key, so only members produce
/// anything that opens. A hello carries no topic (all zeros):
/// it lists freshly sealed presence for every context the sender is attached
/// to, which is how two devices learn — without the SFU — which contexts they
/// share.
enum KeepTalkingIrohPeerFrame {
    static let alpn = Data("keeptalking/peer/2".utf8)

    enum Kind: UInt8, Sendable {
        case envelope = 0x01
        case hello = 0x05
        /// Empty, no topic, every `pingInterval` on network links: proves the
        /// peer is still there faster than QUIC notices it isn't.
        case ping = 0x06
    }

    static let ping = encode(kind: .ping, topic: Data(count: KeepTalkingIrohSFUFrame.topicLength), payload: Data())

    typealias Lane = KeepTalkingEnvelopeDelivery.Lane

    /// What a stream carries, from its first byte.
    enum StreamType: Equatable, Sendable {
        case lane(Lane)
        case blob

        static let blobPreamble: UInt8 = 0x10

        init?(preamble: UInt8) {
            if preamble == Self.blobPreamble {
                self = .blob
            } else if let lane = Lane(rawValue: preamble) {
                self = .lane(lane)
            } else {
                return nil
            }
        }

        var preamble: UInt8 {
            switch self {
                case .lane(let lane): return lane.rawValue
                case .blob: return Self.blobPreamble
            }
        }
    }

    /// QUIC send priority per stream type: higher goes first.
    static func priority(_ type: StreamType) -> Int32 {
        switch type {
            case .lane(.control): return 3
            case .lane(.interactive): return 2
            case .lane(.bulk): return 1
            case .blob: return 0
        }
    }

    /// Largest blob-stream frame: a sealed chunk plus headroom.
    static let maxBlobFrameLength = 256 * 1024

    /// `kind ‖ topic`.
    static let headerLength = 1 + KeepTalkingIrohSFUFrame.topicLength
    static let maxLength = 8 << 20
    /// Largest frame a link may send before it has shown it shares a
    /// context with us (a hello that opens, or presence through the SFU).
    static let maxUnprovenLength = 64 * 1024

    struct Decoded: Equatable, Sendable {
        let kind: Kind
        let topic: Data
        let payload: Data
    }

    static func encode(kind: Kind, topic: Data, payload: Data) -> Data {
        var frame = Data(capacity: 4 + headerLength + payload.count)
        frame.appendBigEndian(UInt32(headerLength + payload.count))
        frame.append(kind.rawValue)
        frame.append(topic)
        frame.append(payload)
        return frame
    }

    /// The body length a prefix announces, if a link in this state may send
    /// it.
    static func bodyLength(fromPrefix prefix: Data, proven: Bool) -> Int? {
        guard prefix.count == 4 else { return nil }
        let length = Int(prefix.readBigEndianUInt32(at: prefix.startIndex))
        let limit = proven ? maxLength : maxUnprovenLength
        return (headerLength...limit).contains(length) ? length : nil
    }

    /// Nil for an unknown kind or a body shorter than the header.
    static func decode(_ body: Data) -> Decoded? {
        guard body.count >= headerLength, let kind = Kind(rawValue: body[body.startIndex]) else {
            return nil
        }
        let topicStart = body.startIndex + 1
        let topicEnd = topicStart + KeepTalkingIrohSFUFrame.topicLength
        return Decoded(
            kind: kind,
            topic: Data(body[topicStart..<topicEnd]),
            payload: Data(body[topicEnd..<body.endIndex])
        )
    }

    /// The hello payload: `n × (u16 BE length ‖ sealed presence)`.
    enum Hello {
        static let maxBlobs = 64
        static let maxBlobLength = 256

        static func encode(_ blobs: [Data]) -> Data {
            var payload = Data()
            for blob in blobs.prefix(maxBlobs) where blob.count <= maxBlobLength {
                payload.appendBigEndian(UInt16(blob.count))
                payload.append(blob)
            }
            return payload
        }

        static func frame(_ blobs: [Data]) -> Data {
            KeepTalkingIrohPeerFrame.encode(
                kind: .hello,
                topic: KeepTalkingIrohSFUFrame.noTopic,
                payload: encode(blobs)
            )
        }

        /// Nil when malformed or over the caps — the whole hello is refused
        /// rather than half-read, since a hello also says which contexts the
        /// sender is no longer in.
        static func decode(_ payload: Data) -> [Data]? {
            var reader = ByteReader(payload)
            var blobs: [Data] = []
            while reader.remaining > 0 {
                guard blobs.count < maxBlobs,
                    let length = try? Int(reader.uint16()),
                    length <= maxBlobLength,
                    let blob = try? reader.bytes(length)
                else { return nil }
                blobs.append(blob)
            }
            return blobs
        }
    }
}
