import Foundation
import Testing

@_spi(TransportLab) @testable import KeepTalkingSDK

/// The hub wire format must match the Rust `kt-sfu` (`src/proto.rs`) byte for
/// byte; topics and sealed payloads must only work for their own context.
struct IrohHubFrameTests {
    private let context = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let topic = Data(repeating: 0xAB, count: 32)
    private let memberID = Data((0..<32).map(UInt8.init))

    @Test("Context ids encode in RFC 4122 byte order")
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

    @Test("SUBSCRIBE is [len=33][0x21][topic], as in kt-sfu")
    func subscribeLayout() {
        let frame = KeepTalkingIrohHubFrame.encode(.subscribe(topic: topic))
        #expect(frame.prefix(5) == Data([0, 0, 0, 33, 0x21]))
        #expect(frame.dropFirst(5) == topic)
    }

    @Test("ANNOUNCE and PUBLISH carry their body after the topic")
    func announceAndPublishLayout() {
        let blob = Data("sealed".utf8)
        let announce = KeepTalkingIrohHubFrame.encode(.announce(topic: topic, blob: blob))
        #expect(announce.prefix(5) == Data([0, 0, 0, UInt8(33 + blob.count), 0x23]))
        #expect(announce.suffix(blob.count) == blob)
        let publish = KeepTalkingIrohHubFrame.encode(.publish(topic: topic, payload: blob))
        #expect(publish[4] == 0x24)
        #expect(publish.suffix(blob.count) == blob)
    }

    @Test(
        "Server frames round-trip through the decoder",
        arguments: [
            KeepTalkingIrohHubFrame.Server.snapshot(
                topic: Data(repeating: 9, count: 32),
                members: [
                    .init(endpointID: Data(repeating: 1, count: 32), blob: Data("a".utf8)),
                    .init(endpointID: Data(repeating: 2, count: 32), blob: Data()),
                ]
            ),
            .joined(topic: Data(repeating: 9, count: 32), endpointID: Data(repeating: 3, count: 32)),
            .left(topic: Data(repeating: 9, count: 32), endpointID: Data(repeating: 4, count: 32)),
            .presence(
                topic: Data(repeating: 9, count: 32),
                endpointID: Data(repeating: 5, count: 32),
                blob: Data("b".utf8)
            ),
            .deliver(topic: Data(repeating: 9, count: 32), payload: Data("payload".utf8)),
            .error(reason: "not subscribed"),
        ]
    )
    func serverRoundTrip(_ frame: KeepTalkingIrohHubFrame.Server) throws {
        let wire = KeepTalkingIrohHubFrame.encode(frame)
        let length = try KeepTalkingIrohHubFrame.frameLength(fromPrefix: wire.prefix(4))
        #expect(length == wire.count - 4)
        #expect(try KeepTalkingIrohHubFrame.decodeServer(wire.dropFirst(4)) == frame)
    }

    @Test("Out-of-range lengths, unknown tags and short bodies are rejected")
    func rejectsBadFrames() {
        #expect(throws: KeepTalkingIrohHubFrame.DecodeError.badLength(0)) {
            try KeepTalkingIrohHubFrame.frameLength(fromPrefix: Data([0, 0, 0, 0]))
        }
        #expect(throws: KeepTalkingIrohHubFrame.DecodeError.self) {
            try KeepTalkingIrohHubFrame.frameLength(fromPrefix: Data([0, 0x20, 0, 1]))
        }
        #expect(throws: KeepTalkingIrohHubFrame.DecodeError.unknownTag(0x99)) {
            try KeepTalkingIrohHubFrame.decodeServer(Data([0x99]))
        }
        #expect(throws: KeepTalkingIrohHubFrame.DecodeError.truncated) {
            try KeepTalkingIrohHubFrame.decodeServer(Data([0x32]) + Data(repeating: 0, count: 40))
        }
    }

    @Test("Hub datagrams are topic ‖ payload")
    func datagrams() throws {
        let datagram = KeepTalkingIrohHubFrame.datagram(topic: topic, payload: Data("voice".utf8))
        let split = try #require(KeepTalkingIrohHubFrame.splitDatagram(datagram))
        #expect(split.topic == topic)
        #expect(split.payload == Data("voice".utf8))
        #expect(KeepTalkingIrohHubFrame.splitDatagram(Data(repeating: 0, count: 31)) == nil)
    }

    @Test("A topic is stable per context and secret, and hides both")
    func topicDerivation() {
        let secret = Data(repeating: 7, count: 32)
        let one = KeepTalkingIrohTopic(contextID: context, secret: secret)
        let again = KeepTalkingIrohTopic(contextID: context, secret: secret)
        let otherSecret = KeepTalkingIrohTopic(contextID: context, secret: Data(repeating: 8, count: 32))
        let otherContext = KeepTalkingIrohTopic(contextID: UUID(), secret: secret)
        #expect(one.topic.count == 32)
        #expect(one.topic == again.topic)
        #expect(one.topic != otherSecret.topic)
        #expect(one.topic != otherContext.topic)
        #expect(one.topic.range(of: context.rfc4122Bytes) == nil)
    }

    @Test("Topic payloads open only with the same topic's key")
    func payloadSeal() throws {
        let secret = Data(repeating: 7, count: 32)
        let topic = KeepTalkingIrohTopic(contextID: context, secret: secret)
        let sealed = try topic.seal(Data("envelope".utf8))
        #expect(topic.open(sealed) == Data("envelope".utf8))
        #expect(sealed.range(of: Data("envelope".utf8)) == nil)
        #expect(KeepTalkingIrohTopic(contextID: context, secret: Data(repeating: 8, count: 32)).open(sealed) == nil)
        #expect(KeepTalkingIrohTopic(contextID: UUID(), secret: secret).open(sealed) == nil)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(topic.open(tampered) == nil)
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
    }

    @Test("Sealed presence carries the Bluetooth endpoint when there is one")
    func sealedPresenceWithBluetooth() throws {
        let secret = Data(repeating: 7, count: 32)
        let node = UUID()
        let bluetoothID = Data(repeating: 0xB1, count: 32)
        let blob = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: node,
            endpointID: memberID,
            bluetoothEndpointID: bluetoothID,
            contextID: context,
            secret: secret
        )
        let opened = try #require(KeepTalkingIrohPresenceSeal.open(blob, contextID: context, secret: secret))
        #expect(opened.nodeID == node)
        #expect(opened.endpointID == memberID)
        #expect(opened.bluetoothEndpointID == bluetoothID)
        let plain = try KeepTalkingIrohPresenceSeal.seal(
            nodeID: node,
            endpointID: memberID,
            contextID: context,
            secret: secret
        )
        #expect(KeepTalkingIrohPresenceSeal.open(plain, contextID: context, secret: secret)?.bluetoothEndpointID == nil)
    }

    #if canImport(IrohLib)
    @Test("Peer frames are [len][kind][topic][payload]")
    func peerFrameLayout() {
        let payload = Data("hello".utf8)
        var body = Data([KeepTalkingIrohTransportHost.FrameKind.envelope.rawValue])
        body.append(payload)
        let frame = KeepTalkingIrohTransportHost.peerFrame(topic: topic, body: body)
        #expect(frame.prefix(4) == Data([0, 0, 0, UInt8(33 + payload.count)]))
        #expect(frame[4] == 0x01)
        #expect(frame[5..<37] == topic)
        #expect(frame.suffix(payload.count) == payload)
    }
    #endif
}
