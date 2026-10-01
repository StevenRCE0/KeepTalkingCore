import Foundation
import Testing

@_spi(TransportLab) @testable import KeepTalkingSDK

/// The presence wire format must match the Rust hub (`kt-sfu`, `src/proto.rs`)
/// byte for byte, and sealed presence must only open for its own context.
struct IrohPresenceFrameTests {
    private let context = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let memberID = Data((0..<32).map(UInt8.init))

    @Test("Context ids travel in RFC 4122 byte order")
    func uuidByteOrder() {
        #expect(
            context.rfc4122Bytes
                == Data([
                    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                    0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
                ])
        )
        #expect(UUID(rfc4122Bytes: context.rfc4122Bytes) == context)
    }

    @Test("JOIN is [len=17][0x11][ctx]")
    func joinLayout() {
        let frame = KeepTalkingIrohPresenceFrame.encode(.join(context: context))
        #expect(frame.prefix(5) == Data([0, 0, 0, 17, 0x11]))
        #expect(frame.dropFirst(5) == context.rfc4122Bytes)
    }

    @Test("PUBLISH carries the blob after the context")
    func publishLayout() {
        let blob = Data("sealed".utf8)
        let frame = KeepTalkingIrohPresenceFrame.encode(.publish(context: context, blob: blob))
        #expect(frame.prefix(5) == Data([0, 0, 0, UInt8(17 + blob.count), 0x13]))
        #expect(frame.suffix(blob.count) == blob)
    }

    @Test(
        "Server frames round-trip through the decoder",
        arguments: [
            KeepTalkingIrohPresenceFrame.Server.snapshot(
                context: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                members: [
                    .init(endpointID: Data(repeating: 1, count: 32), blob: Data("a".utf8)),
                    .init(endpointID: Data(repeating: 2, count: 32), blob: Data()),
                ]
            ),
            .joined(context: UUID(), endpointID: Data(repeating: 3, count: 32)),
            .left(context: UUID(), endpointID: Data(repeating: 4, count: 32)),
            .presence(context: UUID(), endpointID: Data(repeating: 5, count: 32), blob: Data("b".utf8)),
            .error(reason: "not joined"),
        ]
    )
    func serverRoundTrip(_ frame: KeepTalkingIrohPresenceFrame.Server) throws {
        let wire = KeepTalkingIrohPresenceFrame.encode(frame)
        let length = try KeepTalkingIrohPresenceFrame.frameLength(fromPrefix: wire.prefix(4))
        #expect(length == wire.count - 4)
        #expect(try KeepTalkingIrohPresenceFrame.decodeServer(wire.dropFirst(4)) == frame)
    }

    @Test("Out-of-range lengths and unknown tags are rejected")
    func rejectsBadFrames() {
        #expect(throws: KeepTalkingIrohPresenceFrame.DecodeError.badLength(0)) {
            try KeepTalkingIrohPresenceFrame.frameLength(fromPrefix: Data([0, 0, 0, 0]))
        }
        #expect(throws: KeepTalkingIrohPresenceFrame.DecodeError.self) {
            try KeepTalkingIrohPresenceFrame.frameLength(fromPrefix: Data([0, 0x10, 0, 1]))
        }
        #expect(throws: KeepTalkingIrohPresenceFrame.DecodeError.unknownTag(0x99)) {
            try KeepTalkingIrohPresenceFrame.decodeServer(Data([0x99]))
        }
        #expect(throws: KeepTalkingIrohPresenceFrame.DecodeError.truncated) {
            try KeepTalkingIrohPresenceFrame.decodeServer(Data([0x15, 0x00]))
        }
    }

    @Test("Sealed presence opens only with its own secret and context")
    func sealedPresence() throws {
        let secret = Data(repeating: 7, count: 32)
        let node = UUID()
        let blob = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: node,
            endpointID: memberID,
            contextID: context,
            secret: secret
        )
        let opened = KeepTalkingIrohPresenceSeal.open(blob, contextID: context, secret: secret)
        #expect(opened == .init(nodeID: node, endpointID: memberID))

        #expect(
            KeepTalkingIrohPresenceSeal.open(blob, contextID: context, secret: Data(repeating: 8, count: 32)) == nil)
        #expect(KeepTalkingIrohPresenceSeal.open(blob, contextID: UUID(), secret: secret) == nil)
        var tampered = blob
        tampered[tampered.count - 1] ^= 0x01
        #expect(KeepTalkingIrohPresenceSeal.open(tampered, contextID: context, secret: secret) == nil)
        #expect(KeepTalkingIrohPresenceSeal.open(Data("junk".utf8), contextID: context, secret: secret) == nil)
    }

    #if canImport(IrohLib)
    @Test("Peer frames are [len][kind][ctx][payload]")
    func peerFrameLayout() {
        let payload = Data("hello".utf8)
        let frame = KeepTalkingIrohTransportHost.peerFrame(.envelope, context: context, payload: payload)
        #expect(frame.prefix(4) == Data([0, 0, 0, UInt8(17 + payload.count)]))
        #expect(frame[4] == 0x01)
        #expect(frame[5..<21] == context.rfc4122Bytes)
        #expect(frame.suffix(payload.count) == payload)
    }
    #endif
}
