#if canImport(IrohLib)
import Foundation
import NIOConcurrencyHelpers

/// One context's room on a `KeepTalkingIrohTransportHost`, from attach to
/// detach: what a client sends through and hears from.
///
/// Every payload is sealed with the room's topic key (`KeepTalkingIrohTopic`):
/// envelopes as a `KeepTalkingEnvelopePacket`, blob streams chunk by chunk.
/// No context or node id travels in the clear. Inbound frames arrive through
/// the SFU or a peer link and count only if they open.
///
/// The attachment holds no client state. Liveness, heartbeats and resyncs
/// belong to the client; this only reports what the host sees:
/// - links coming up or changing carrier;
/// - the room's status;
/// - the room becoming able to take sends.
final class KeepTalkingIrohAttachment: KeepTalkingTransportAttachment, @unchecked Sendable {
    let host: KeepTalkingIrohTransportHost
    let room: KeepTalkingTransportRoom
    let topic: KeepTalkingIrohTopic
    private let events: KeepTalkingTransportEventHandler

    private struct State {
        var isAttached = true
        var envelopesSent = 0
        var envelopesReceived = 0
        var datagramsSent = 0
        var datagramsReceived = 0
        var lastStatus: KeepTalkingTransportStatus?
    }

    private let state = NIOLockedValueBox(State())

    init(
        host: KeepTalkingIrohTransportHost, room: KeepTalkingTransportRoom,
        events: @escaping KeepTalkingTransportEventHandler
    ) {
        self.host = host
        self.room = room
        self.topic = KeepTalkingIrohTopic(contextID: room.contextID, secret: room.secret)
        self.events = events
    }

    private var isAttached: Bool {
        state.withLockedValue { $0.isAttached }
    }

    /// A detached attachment is silent.
    private func emit(_ event: KeepTalkingTransportEvent) {
        guard isAttached else { return }
        events(event)
    }

    private func log(_ message: String) {
        emit(.log("[iroh \(room.contextID.uuidString.prefix(8))] \(message)"))
    }

    // MARK: - KeepTalkingTransportAttachment

    func detach() {
        let wasAttached = state.withLockedValue { state -> Bool in
            defer { state.isAttached = false }
            return state.isAttached
        }
        guard wasAttached else { return }
        host.detach(self, topic: topic.topic)
    }

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        guard isAttached else { throw KeepTalkingTransportError.notAttached }
        let packet = try JSONEncoder().encode(KeepTalkingEnvelopePacket(envelope))
        do {
            try host.publish(
                .envelope,
                topic: topic.topic,
                payload: try topic.seal(packet),
                to: envelope.targetPeerNodeID,
                lane: envelope.kind.delivery.lane
            )
        } catch KeepTalkingIrohTransportHost.HostError.frameTooLarge(let bytes, let limit) {
            throw KeepTalkingTransportError.envelopeTooLarge(kind: envelope.kind, bytes: bytes, limit: limit)
        } catch let error as KeepTalkingIrohTransportHost.HostError {
            throw Self.transportError(error)
        }
        state.withLockedValue { $0.envelopesSent += 1 }
    }

    func sendDatagram(_ datagram: Data) throws {
        guard isAttached else { throw KeepTalkingTransportError.notAttached }
        do {
            try host.sendDatagram(topic: topic.topic, payload: datagram)
        } catch let error as KeepTalkingIrohTransportHost.HostError {
            throw Self.transportError(error)
        }
        state.withLockedValue { $0.datagramsSent += 1 }
    }

    /// Opens a blob transfer to `node` on a stream of its own, point to
    /// point. The header and every chunk are sealed with the topic's key.
    func openBlobStream(to node: UUID, header: Data) async throws -> any KeepTalkingBlobStreamWriter {
        guard isAttached else { throw KeepTalkingTransportError.notAttached }
        let raw: KeepTalkingIrohBlobStream.Writer
        do {
            raw = try await host.openBlobStream(topic: topic.topic, to: node)
        } catch KeepTalkingIrohTransportHost.HostError.noRoute, KeepTalkingIrohTransportHost.HostError.notMember {
            throw KeepTalkingBlobStreamError.unreachable(node)
        }
        let writer = SealedBlobWriter(raw: raw, topic: topic)
        do {
            try await writer.write(header)
        } catch {
            writer.cancel()
            throw error
        }
        return writer
    }

    func expectBlobStream(from node: UUID) {
        guard isAttached else { return }
        host.expectBlobStream(topic: topic.topic, from: node)
    }

    func status() -> KeepTalkingTransportStatus {
        guard isAttached else { return .offline }
        return host.roomStatus(of: topic.topic)
    }

    func stats() -> KeepTalkingRuntimeStats {
        guard isAttached else { return .zero }
        var stats = host.roomStats(of: topic.topic)
        state.withLockedValue { state in
            stats.envelopesSent = state.envelopesSent
            stats.envelopesReceived = state.envelopesReceived
            stats.datagramsSent = state.datagramsSent
            stats.datagramsReceived = state.datagramsReceived
        }
        return stats
    }

    private static func transportError(_ error: KeepTalkingIrohTransportHost.HostError) -> KeepTalkingTransportError {
        switch error {
            case .notAttached, .stopped:
                return .notAttached
            case .noRoute, .notMember, .frameTooLarge, .sfuInfo, .malformedFrame:
                return .noRoute
        }
    }

    // MARK: - From the host

    func sfuJoined() {
        log("SFU snapshot received")
        emit(.readyToSend)
        reportStatus()
    }

    func sfuStateChanged() {
        reportStatus()
    }

    func peerLinkUp(_ node: UUID) {
        guard node != room.nodeID else { return }
        emit(.peerConnected(node))
        reportStatus()
    }

    func peerLinkDown(_ node: UUID) {
        log("link to \(node.uuidString.prefix(8)) down")
        reportStatus()
    }

    /// The member's traffic moved to its other live link (network died
    /// under Bluetooth, or came back).
    func peerRerouted(_ node: UUID) {
        guard node != room.nodeID else { return }
        log("route to \(node.uuidString.prefix(8)) changed")
        emit(.peerRerouted(node))
        reportStatus()
    }

    func memberLeft(_ node: UUID) {
        log("member \(node.uuidString.prefix(8)) left")
        reportStatus()
    }

    func routeMayHaveChanged() {
        reportStatus()
    }

    func deliver(
        _ kind: KeepTalkingIrohTransportHost.FrameKind,
        payload: Data,
        from node: UUID?,
        route: KeepTalkingIrohTransportHost.Route
    ) {
        // The host consumes hellos; they belong to no topic.
        guard kind == .envelope, isAttached else { return }
        guard let opened = topic.open(payload) else {
            log("unopenable envelope via \(route.rawValue)")
            return
        }
        guard let packet = try? JSONDecoder().decode(KeepTalkingEnvelopePacket.self, from: opened) else {
            log("undecodable envelope packet")
            return
        }
        let envelope = packet.envelope
        if let inner = envelope.transportContextID, inner != room.contextID {
            log("dropped envelope for another context")
            return
        }
        state.withLockedValue { $0.envelopesReceived += 1 }
        emit(.envelope(envelope, from: node))
    }

    /// Datagrams arrive as their sender sealed them (the voice session's
    /// key); they're not sealed again with the topic.
    func deliverRealtime(_ payload: Data, from node: UUID?) {
        guard isAttached else { return }
        state.withLockedValue { $0.datagramsReceived += 1 }
        emit(.datagram(payload))
    }

    /// An incoming blob transfer from `node`: its first frame is the header.
    /// A stream whose header doesn't open with our topic's key is dropped.
    func deliverBlobStream(_ raw: KeepTalkingIrohBlobStream.Reader, from node: UUID) {
        guard isAttached else {
            raw.cancel()
            return
        }
        Task {
            guard let sealed = try? await raw.next(), let header = topic.open(sealed) else {
                raw.cancel()
                return
            }
            guard isAttached else {
                raw.cancel()
                return
            }
            emit(.blobStream(SealedBlobReader(header: header, raw: raw, topic: topic), from: node))
        }
    }

    /// Reports a status change, and `readyToSend` when the room goes from
    /// unable to able to send.
    private func reportStatus() {
        let status = host.roomStatus(of: topic.topic)
        let (changed, becameSendable) = state.withLockedValue { state -> (Bool, Bool) in
            let previous = state.lastStatus
            guard previous != status else { return (false, false) }
            state.lastStatus = status
            return (true, status.canSend && previous?.canSend != true)
        }
        if changed { emit(.statusChanged(status)) }
        if becameSendable { emit(.readyToSend) }
    }
}

/// A blob transfer's writer that seals each chunk with the topic's key.
private final class SealedBlobWriter: KeepTalkingBlobStreamWriter, @unchecked Sendable {
    private let raw: KeepTalkingIrohBlobStream.Writer
    private let topic: KeepTalkingIrohTopic

    init(raw: KeepTalkingIrohBlobStream.Writer, topic: KeepTalkingIrohTopic) {
        self.raw = raw
        self.topic = topic
    }

    func write(_ chunk: Data) async throws {
        try await raw.write(try topic.seal(chunk))
    }

    func finish() async throws {
        try await raw.finish()
    }

    func cancel() {
        raw.cancel()
    }
}

/// A blob transfer's reader that opens each chunk with the topic's key; a
/// chunk that doesn't open ends the transfer.
private final class SealedBlobReader: KeepTalkingBlobStreamReader, @unchecked Sendable {
    let header: Data
    private let raw: KeepTalkingIrohBlobStream.Reader
    private let topic: KeepTalkingIrohTopic

    init(header: Data, raw: KeepTalkingIrohBlobStream.Reader, topic: KeepTalkingIrohTopic) {
        self.header = header
        self.raw = raw
        self.topic = topic
    }

    func next() async throws -> Data? {
        guard let sealed = try await raw.next() else { return nil }
        guard let chunk = topic.open(sealed) else {
            raw.cancel()
            throw KeepTalkingIrohTransportHost.HostError.malformedFrame
        }
        return chunk
    }

    func cancel() {
        raw.cancel()
    }
}
#endif
