import Foundation

@testable import KeepTalkingSDK

/// A process-wide transport that only does what tests tell it to. Every
/// attach hands out a `FakeAttachment` the test can drive.
final class FakeMultiplexer: KeepTalkingTransportMultiplexer, @unchecked Sendable {
    private let lock = NSLock()
    private var attachments: [FakeAttachment] = []
    var attachError: (any Error)?
    var attachGate: TestGate?
    /// What a fresh attachment reports.
    var initialStatus = KeepTalkingTransportStatus(state: .ready, path: .sfu)

    var transport: KeepTalkingTransport { KeepTalkingTransport(multiplexer: self) }

    var attachCount: Int { lock.withLock { attachments.count } }
    var current: FakeAttachment? { lock.withLock { attachments.last } }
    var all: [FakeAttachment] { lock.withLock { attachments } }

    func attach(
        _ room: KeepTalkingTransportRoom,
        events: @escaping KeepTalkingTransportEventHandler
    ) async throws -> any KeepTalkingTransportAttachment {
        if let attachError { throw attachError }
        let attachment = FakeAttachment(room: room, events: events, status: initialStatus)
        lock.withLock { attachments.append(attachment) }
        if let attachGate { await attachGate.wait() }
        try Task.checkCancellation()
        return attachment
    }
}

final class FakeAttachment: KeepTalkingTransportAttachment, @unchecked Sendable {
    let room: KeepTalkingTransportRoom
    private let events: KeepTalkingTransportEventHandler
    private let lock = NSLock()
    private var currentStatus: KeepTalkingTransportStatus
    private var sentEnvelopes: [any KeepTalkingEnvelope] = []
    private var sentDatagrams: [Data] = []
    private var detaches = 0
    var sendError: (any Error)?

    init(
        room: KeepTalkingTransportRoom, events: @escaping KeepTalkingTransportEventHandler,
        status: KeepTalkingTransportStatus
    ) {
        self.room = room
        self.events = events
        self.currentStatus = status
    }

    var detachCount: Int { lock.withLock { detaches } }
    var envelopes: [any KeepTalkingEnvelope] { lock.withLock { sentEnvelopes } }
    var datagrams: [Data] { lock.withLock { sentDatagrams } }

    /// Delivers `event` to the client as the transport would.
    func emit(_ event: KeepTalkingTransportEvent) {
        events(event)
    }

    /// Moves the room's status and reports it.
    func report(_ status: KeepTalkingTransportStatus) {
        lock.withLock { currentStatus = status }
        events(.statusChanged(status))
    }

    func detach() {
        lock.withLock { detaches += 1 }
    }

    func send(_ envelope: any KeepTalkingEnvelope) throws {
        if let sendError { throw sendError }
        lock.withLock { sentEnvelopes.append(envelope) }
    }

    func sendDatagram(_ datagram: Data) throws {
        lock.withLock { sentDatagrams.append(datagram) }
    }

    func openBlobStream(to node: UUID, header: Data) async throws -> any KeepTalkingBlobStreamWriter {
        throw KeepTalkingBlobStreamError.unreachable(node)
    }

    func expectBlobStream(from node: UUID) {}

    func status() -> KeepTalkingTransportStatus {
        lock.withLock { currentStatus }
    }

    func stats() -> KeepTalkingRuntimeStats {
        lock.withLock {
            KeepTalkingRuntimeStats(envelopesSent: sentEnvelopes.count, status: currentStatus)
        }
    }
}
