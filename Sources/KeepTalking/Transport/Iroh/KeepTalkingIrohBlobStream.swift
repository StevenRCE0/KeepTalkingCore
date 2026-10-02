#if canImport(IrohLib)
import Foundation
import IrohLib

/// One blob transfer on its own peer-link stream: `[0x10][topic(32)]`, then
/// `[u32 BE length][frame]` frames — the first the header — until the
/// stream finishes (complete) or is reset (cancelled). It runs at the lowest
/// priority, and QUIC flow control paces it, so a transfer never needs
/// sleeps and never holds up a lane. Frames here are raw: the context
/// transport seals and opens them.
enum KeepTalkingIrohBlobStream {
    final class Writer: @unchecked Sendable {
        private let send: SendStream

        init(_ send: SendStream) {
            self.send = send
        }

        func write(_ frame: Data) async throws {
            guard frame.count <= KeepTalkingIrohPeerFrame.maxBlobFrameLength else {
                throw KeepTalkingIrohTransportHost.HostError.frameTooLarge(
                    bytes: frame.count,
                    limit: KeepTalkingIrohPeerFrame.maxBlobFrameLength
                )
            }
            var bytes = Data(capacity: 4 + frame.count)
            bytes.appendBigEndian(UInt32(frame.count))
            bytes.append(frame)
            try await send.writeAll(buf: bytes)
        }

        func finish() async throws {
            try await send.finish()
        }

        func cancel() {
            let send = send
            Task { try? await send.reset(errorCode: 1) }
        }
    }

    final class Reader: @unchecked Sendable {
        private let recv: RecvStream

        init(_ recv: RecvStream) {
            self.recv = recv
        }

        /// The next frame, or nil once the sender finished.
        func next() async throws -> Data? {
            guard let prefix = try await KeepTalkingIrohTransportHost.readPrefixOrEnd(recv) else { return nil }
            let length = Int(prefix.readBigEndianUInt32(at: prefix.startIndex))
            guard (1...KeepTalkingIrohPeerFrame.maxBlobFrameLength).contains(length) else {
                throw KeepTalkingIrohTransportHost.HostError.malformedFrame
            }
            return try await recv.readExact(size: UInt32(length))
        }

        func cancel() {
            let recv = recv
            Task { try? await recv.stop(errorCode: 1) }
        }
    }
}

extension KeepTalkingIrohTransportHost {
    /// We're about to pull a blob from `node`: want a link to it for a while,
    /// so whichever side's turn it is dials now.
    func expectBlobStream(topic: Data, from node: UUID) {
        let now = clock.now
        let targets = state.withLockedValue { state -> [(Data, LinkKind)] in
            guard let main = state.membership.members(of: topic).first(where: { $0.nodeID == node })?.main else {
                return []
            }
            state.demand[main] = now + Self.linkDemand
            return [(main, .network)] + (state.membership.bluetoothID(of: main).map { [($0, .bluetooth)] } ?? [])
        }
        for (id, kind) in targets { ensureLink(to: id, kind: kind) }
    }

    /// How long opening a blob transfer waits for a link to the member.
    static let blobLinkTimeout: Duration = .seconds(20)

    /// Opens a blob transfer to `node`, a member of `topic`: asks for a peer
    /// link (rooms on the SFU have none until something needs one), waits
    /// for it, and opens a lowest-priority stream on whichever link carries
    /// the member.
    func openBlobStream(topic: Data, to node: UUID) async throws -> KeepTalkingIrohBlobStream.Writer {
        let now = clock.now
        let (main, bluetooth) = try state.withLockedValue { state -> (Data, Data?) in
            guard !state.isShutDown else { throw HostError.stopped }
            guard let main = state.membership.members(of: topic).first(where: { $0.nodeID == node })?.main else {
                throw HostError.notMember(node)
            }
            state.demand[main] = now + Self.linkDemand
            return (main, state.membership.bluetoothID(of: main))
        }
        ensureLink(to: main, kind: .network)
        if let bluetooth { ensureLink(to: bluetooth, kind: .bluetooth) }
        let deadline = now + Self.blobLinkTimeout
        while true {
            let connection = state.withLockedValue { state in
                state.carrier(of: main).flatMap { state.io[$0]?.connection }
            }
            if let connection {
                let type = KeepTalkingIrohPeerFrame.StreamType.blob
                let send = try await connection.openUni()
                try await send.setPriority(p: KeepTalkingIrohPeerFrame.priority(type))
                var preamble = Data([type.preamble])
                preamble.append(topic)
                try await send.writeAll(buf: preamble)
                return KeepTalkingIrohBlobStream.Writer(send)
            }
            guard clock.now < deadline else { throw HostError.noRoute }
            try await Task.sleep(for: .milliseconds(100), clock: clock)
        }
    }
}
#endif
