import Foundation

/// Wire format of the hub protocol spoken with the Rust `kt-sfu`
/// (ALPN `keeptalking/hub/1`; `KeepTalkingSFU` branch `iroh-sfu`,
/// `src/proto.rs`). The client opens one bidirectional stream and speaks
/// first; both directions carry `[u32 BE length = 1 + body][u8 tag][body]`.
///
/// Rooms are keyed by a 32-byte topic derived from the context secret
/// (`KeepTalkingIrohTopic`), so the hub never sees a context id. Member ids
/// are 32-byte ed25519 endpoint ids. Announced blobs and published payloads
/// are opaque to the hub.
enum KeepTalkingIrohHubFrame {
    static let alpn = Data("keeptalking/hub/1".utf8)
    static let maxPublishLength = 1 << 20
    static let maxFrameLength = maxPublishLength + 64 * 1024
    static let maxAnnounceLength = 16 * 1024
    static let topicLength = 32
    static let endpointIDLength = 32

    enum Tag {
        static let subscribe: UInt8 = 0x21
        static let unsubscribe: UInt8 = 0x22
        static let announce: UInt8 = 0x23
        static let publish: UInt8 = 0x24
        static let snapshot: UInt8 = 0x31
        static let joined: UInt8 = 0x32
        static let left: UInt8 = 0x33
        static let presence: UInt8 = 0x34
        static let deliver: UInt8 = 0x35
        static let error: UInt8 = 0x3F
    }

    struct Member: Equatable, Sendable {
        let endpointID: Data
        /// Empty until the member has announced.
        let blob: Data
    }

    enum Client: Equatable, Sendable {
        case subscribe(topic: Data)
        case unsubscribe(topic: Data)
        case announce(topic: Data, blob: Data)
        /// Reliable fan-out: the hub sends it to every other subscriber.
        case publish(topic: Data, payload: Data)
    }

    enum Server: Equatable, Sendable {
        case snapshot(topic: Data, members: [Member])
        case joined(topic: Data, endpointID: Data)
        case left(topic: Data, endpointID: Data)
        case presence(topic: Data, endpointID: Data, blob: Data)
        /// A payload another subscriber published; the hub doesn't name the
        /// sender (the sealed payload does).
        case deliver(topic: Data, payload: Data)
        case error(reason: String)
    }

    enum DecodeError: Error, Equatable {
        case truncated
        case badLength(Int)
        case unknownTag(UInt8)
    }

    // MARK: - Encode

    static func encode(_ frame: Client) -> Data {
        var body = Data()
        let tag: UInt8
        switch frame {
            case .subscribe(let topic):
                body.append(topic)
                tag = Tag.subscribe
            case .unsubscribe(let topic):
                body.append(topic)
                tag = Tag.unsubscribe
            case .announce(let topic, let blob):
                body.append(topic)
                body.append(blob)
                tag = Tag.announce
            case .publish(let topic, let payload):
                body.append(topic)
                body.append(payload)
                tag = Tag.publish
        }
        return framed(tag: tag, body: body)
    }

    /// Server-side encoding, used by tests to feed the client decoder.
    static func encode(_ frame: Server) -> Data {
        var body = Data()
        let tag: UInt8
        switch frame {
            case .snapshot(let topic, let members):
                body.append(topic)
                body.appendBigEndian(UInt16(members.count))
                for member in members {
                    body.append(member.endpointID)
                    body.appendBigEndian(UInt32(member.blob.count))
                    body.append(member.blob)
                }
                tag = Tag.snapshot
            case .joined(let topic, let endpointID):
                body.append(topic)
                body.append(endpointID)
                tag = Tag.joined
            case .left(let topic, let endpointID):
                body.append(topic)
                body.append(endpointID)
                tag = Tag.left
            case .presence(let topic, let endpointID, let blob):
                body.append(topic)
                body.append(endpointID)
                body.append(blob)
                tag = Tag.presence
            case .deliver(let topic, let payload):
                body.append(topic)
                body.append(payload)
                tag = Tag.deliver
            case .error(let reason):
                body.append(Data(reason.utf8))
                tag = Tag.error
        }
        return framed(tag: tag, body: body)
    }

    static func framed(tag: UInt8, body: Data) -> Data {
        var out = Data(capacity: 5 + body.count)
        out.appendBigEndian(UInt32(1 + body.count))
        out.append(tag)
        out.append(body)
        return out
    }

    /// A hub datagram: `topic ‖ payload`, forwarded as-is to the room.
    static func datagram(topic: Data, payload: Data) -> Data {
        var out = Data(capacity: topic.count + payload.count)
        out.append(topic)
        out.append(payload)
        return out
    }

    static func splitDatagram(_ datagram: Data) -> (topic: Data, payload: Data)? {
        guard datagram.count >= topicLength else { return nil }
        return (Data(datagram.prefix(topicLength)), Data(datagram.dropFirst(topicLength)))
    }

    // MARK: - Decode

    /// Validates the 4-byte length prefix and returns how many bytes follow.
    static func frameLength(fromPrefix prefix: Data) throws -> Int {
        guard prefix.count == 4 else { throw DecodeError.truncated }
        let length = Int(prefix.readBigEndianUInt32(at: prefix.startIndex))
        guard (1...maxFrameLength).contains(length) else {
            throw DecodeError.badLength(length)
        }
        return length
    }

    /// Decodes `[tag][body]` (the bytes after the length prefix).
    static func decodeServer(_ frame: Data) throws -> Server {
        var reader = Reader(frame)
        let tag = try reader.byte()
        switch tag {
            case Tag.snapshot:
                let topic = try reader.bytes(topicLength)
                let count = Int(try reader.uint16())
                var members: [Member] = []
                members.reserveCapacity(count)
                for _ in 0..<count {
                    let id = try reader.bytes(endpointIDLength)
                    let length = Int(try reader.uint32())
                    members.append(Member(endpointID: id, blob: try reader.bytes(length)))
                }
                return .snapshot(topic: topic, members: members)
            case Tag.joined:
                return .joined(
                    topic: try reader.bytes(topicLength),
                    endpointID: try reader.bytes(endpointIDLength)
                )
            case Tag.left:
                return .left(
                    topic: try reader.bytes(topicLength),
                    endpointID: try reader.bytes(endpointIDLength)
                )
            case Tag.presence:
                return .presence(
                    topic: try reader.bytes(topicLength),
                    endpointID: try reader.bytes(endpointIDLength),
                    blob: reader.rest()
                )
            case Tag.deliver:
                return .deliver(topic: try reader.bytes(topicLength), payload: reader.rest())
            case Tag.error:
                return .error(reason: String(decoding: reader.rest(), as: UTF8.self))
            default:
                throw DecodeError.unknownTag(tag)
        }
    }

    private struct Reader {
        private let data: Data
        private var offset: Data.Index

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else {
                throw DecodeError.truncated
            }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }

        mutating func byte() throws -> UInt8 { try bytes(1)[0] }

        mutating func uint16() throws -> UInt16 {
            let raw = try bytes(2)
            return UInt16(raw[raw.startIndex]) << 8 | UInt16(raw[raw.startIndex + 1])
        }

        mutating func uint32() throws -> UInt32 {
            let raw = try bytes(4)
            return raw.readBigEndianUInt32(at: raw.startIndex)
        }

        mutating func rest() -> Data {
            defer { offset = data.endIndex }
            return Data(data[offset..<data.endIndex])
        }
    }
}

extension UUID {
    /// The 16 bytes of `uuid` in RFC 4122 (network) order.
    var rfc4122Bytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    init(rfc4122Bytes bytes: Data) {
        precondition(bytes.count == 16)
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
        self.init(uuid: raw)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    func readBigEndianUInt32(at index: Index) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16
            | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}
