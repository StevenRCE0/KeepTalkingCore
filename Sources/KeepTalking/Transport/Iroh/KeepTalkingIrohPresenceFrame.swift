import Foundation

/// Wire format of the presence protocol spoken with the Rust `kt-sfu` hub
/// (ALPN `keeptalking/presence/1`, see `KeepTalkingSFU` branch `iroh-sfu`,
/// `src/proto.rs`). The client opens one bidirectional stream and speaks
/// first; both directions carry `[u32 BE length = 1 + body][u8 tag][body]`.
///
/// Context ids travel in RFC 4122 byte order (`UUID.uuid`); member ids are
/// 32-byte ed25519 endpoint ids. Blobs are opaque to the hub — clients put
/// their context-sealed presence there (`KeepTalkingIrohPresenceSeal`).
enum KeepTalkingIrohPresenceFrame {
    static let alpn = Data("keeptalking/presence/1".utf8)
    static let maxFrameLength = 256 * 1024
    static let maxPresenceLength = 16 * 1024
    static let endpointIDLength = 32

    enum Tag {
        static let join: UInt8 = 0x11
        static let leave: UInt8 = 0x12
        static let publish: UInt8 = 0x13
        static let snapshot: UInt8 = 0x14
        static let joined: UInt8 = 0x15
        static let left: UInt8 = 0x16
        static let presence: UInt8 = 0x17
        static let error: UInt8 = 0x3F
    }

    struct Member: Equatable, Sendable {
        let endpointID: Data
        /// Empty until the member has published.
        let blob: Data
    }

    enum Client: Equatable, Sendable {
        case join(context: UUID)
        case leave(context: UUID)
        case publish(context: UUID, blob: Data)
    }

    enum Server: Equatable, Sendable {
        case snapshot(context: UUID, members: [Member])
        case joined(context: UUID, endpointID: Data)
        case left(context: UUID, endpointID: Data)
        case presence(context: UUID, endpointID: Data, blob: Data)
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
            case .join(let context):
                body.append(context.rfc4122Bytes)
                tag = Tag.join
            case .leave(let context):
                body.append(context.rfc4122Bytes)
                tag = Tag.leave
            case .publish(let context, let blob):
                body.append(context.rfc4122Bytes)
                body.append(blob)
                tag = Tag.publish
        }
        return framed(tag: tag, body: body)
    }

    /// Server-side encoding, used by tests to feed the client decoder.
    static func encode(_ frame: Server) -> Data {
        var body = Data()
        let tag: UInt8
        switch frame {
            case .snapshot(let context, let members):
                body.append(context.rfc4122Bytes)
                body.appendBigEndian(UInt16(members.count))
                for member in members {
                    body.append(member.endpointID)
                    body.appendBigEndian(UInt32(member.blob.count))
                    body.append(member.blob)
                }
                tag = Tag.snapshot
            case .joined(let context, let endpointID):
                body.append(context.rfc4122Bytes)
                body.append(endpointID)
                tag = Tag.joined
            case .left(let context, let endpointID):
                body.append(context.rfc4122Bytes)
                body.append(endpointID)
                tag = Tag.left
            case .presence(let context, let endpointID, let blob):
                body.append(context.rfc4122Bytes)
                body.append(endpointID)
                body.append(blob)
                tag = Tag.presence
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
                let context = try reader.uuid()
                let count = Int(try reader.uint16())
                var members: [Member] = []
                members.reserveCapacity(count)
                for _ in 0..<count {
                    let id = try reader.bytes(endpointIDLength)
                    let length = Int(try reader.uint32())
                    members.append(Member(endpointID: id, blob: try reader.bytes(length)))
                }
                return .snapshot(context: context, members: members)
            case Tag.joined:
                return .joined(
                    context: try reader.uuid(),
                    endpointID: try reader.bytes(endpointIDLength)
                )
            case Tag.left:
                return .left(
                    context: try reader.uuid(),
                    endpointID: try reader.bytes(endpointIDLength)
                )
            case Tag.presence:
                return .presence(
                    context: try reader.uuid(),
                    endpointID: try reader.bytes(endpointIDLength),
                    blob: reader.rest()
                )
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

        mutating func uuid() throws -> UUID {
            UUID(rfc4122Bytes: try bytes(16))
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
