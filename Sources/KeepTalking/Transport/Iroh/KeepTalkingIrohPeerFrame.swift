import Foundation

/// Frames on a peer link (ALPN `keeptalking/peer/1`): one unidirectional
/// stream each way carrying `[u32 BE length][kind][topic(32)][payload]`.
///
/// Envelopes, blobs, pings and pongs are sealed with the topic's key, so only
/// members produce anything that opens. A hello carries no topic (all
/// zeros): it lists freshly sealed presence for every context the sender is
/// attached to, which is how two devices learn — without the SFU — which
/// contexts they share.
enum KeepTalkingIrohPeerFrame {
    enum Kind: UInt8, Sendable {
        case envelope = 0x01
        case blob = 0x02
        case ping = 0x03
        case pong = 0x04
        case hello = 0x05
    }

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
