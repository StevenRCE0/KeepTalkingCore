import Foundation

// MARK: - The process-wide transport

/// The transport one process shares across all its contexts.
///
/// There is one per process and the host app owns it. A `KeepTalkingClient`
/// never builds, starts, stops or restarts a transport: it **attaches** its
/// context when it connects and **detaches** when it disconnects. Everything
/// below the attachment is shared by every attached context and outlives any
/// one client:
///
/// - the endpoints and the SFU session;
/// - peer links, Bluetooth, and per-member queues;
/// - recovery from network changes and lost connections.
///
/// So a model or settings change that rebuilds a client never drops a
/// connection, and a hundred contexts cost one SFU session and one link per
/// peer.
///
/// `unavailable` is for clients that never connect (façades that read the
/// store) and for platforms without a transport (visionOS). Connecting such a
/// client throws ``KeepTalkingTransportError/unavailable``.
public struct KeepTalkingTransport: Sendable {
    let multiplexer: (any KeepTalkingTransportMultiplexer)?

    init(multiplexer: (any KeepTalkingTransportMultiplexer)?) {
        self.multiplexer = multiplexer
    }

    public static let unavailable = KeepTalkingTransport(multiplexer: nil)

    public var isAvailable: Bool { multiplexer != nil }
}

#if canImport(IrohLib)
extension KeepTalkingTransport {
    /// The iroh host as the process's transport. Every client handed this
    /// attaches its context to `host`.
    public static func iroh(_ host: KeepTalkingIrohTransportHost) -> KeepTalkingTransport {
        KeepTalkingTransport(multiplexer: host)
    }
}
#endif

// MARK: - Status

/// How a context's room is doing on the shared transport.
public struct KeepTalkingTransportStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Attached, and nothing usable yet.
        case connecting
        /// Every member is reachable, or the SFU carries the room.
        case ready
        /// Some members are reachable. Frames for the rest wait in their
        /// queues until a link comes up.
        case degraded
        /// Nothing reachable: no SFU and no link. Also the reading of a client
        /// that isn't connected.
        case offline
    }

    /// The path the room's traffic takes, for display only.
    public enum Path: String, Sendable, Equatable {
        /// Fanned out by the SFU.
        case sfu
        /// Peer links, at least one on a direct IP path.
        case direct
        /// Peer links through the relay only.
        case relay
        /// Peer links over Bluetooth only.
        case bluetooth
    }

    public let state: State
    public let path: Path?

    public init(state: State, path: Path?) {
        self.state = state
        self.path = path
    }

    public static let offline = KeepTalkingTransportStatus(state: .offline, path: nil)

    /// Sends go out now rather than waiting in a queue or failing.
    public var canSend: Bool {
        state == .ready || state == .degraded
    }
}

/// One sample of a context's traffic on the shared transport.
public struct KeepTalkingRuntimeStats: Sendable, Equatable {
    public var envelopesSent: Int
    public var envelopesReceived: Int
    public var datagramsSent: Int
    public var datagramsReceived: Int
    /// Members of the room we know of, ourselves excluded.
    public var members: Int
    /// Members a link reaches now.
    public var reachableMembers: Int
    /// Bytes waiting in this room's queues.
    public var queuedBytes: Int
    public var status: KeepTalkingTransportStatus

    public init(
        envelopesSent: Int = 0,
        envelopesReceived: Int = 0,
        datagramsSent: Int = 0,
        datagramsReceived: Int = 0,
        members: Int = 0,
        reachableMembers: Int = 0,
        queuedBytes: Int = 0,
        status: KeepTalkingTransportStatus = .offline
    ) {
        self.envelopesSent = envelopesSent
        self.envelopesReceived = envelopesReceived
        self.datagramsSent = datagramsSent
        self.datagramsReceived = datagramsReceived
        self.members = members
        self.reachableMembers = reachableMembers
        self.queuedBytes = queuedBytes
        self.status = status
    }

    public static let zero = KeepTalkingRuntimeStats()
}

enum KeepTalkingTransportError: LocalizedError, Equatable {
    /// The process has no transport (`KeepTalkingTransport.unavailable`).
    case unavailable
    /// The client isn't connected, so its context has no attachment.
    case notAttached
    /// Nothing can take the frame now. The outbox keeps it and retries.
    case noRoute
    /// Over what one frame carries. The outbox drops the row: retrying can't
    /// help.
    case envelopeTooLarge(kind: KeepTalkingEnvelopeKind, bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
            case .unavailable:
                return "This process has no transport."
            case .notAttached:
                return "The client isn't connected."
            case .noRoute:
                return "No member of the context is reachable right now."
            case .envelopeTooLarge(let kind, let bytes, let limit):
                return "A \(kind.rawValue) envelope of \(bytes) bytes is over the \(limit)-byte limit."
        }
    }
}

// MARK: - The seam

/// What a process-wide transport offers clients: rooms to attach to, one per
/// context.
protocol KeepTalkingTransportMultiplexer: AnyObject, Sendable {
    /// Joins `room` and returns the attachment that carries it, starting the
    /// transport if this is its first attachment. `events` gets the room's
    /// events from the moment the attachment exists until it's detached.
    ///
    /// One attachment per context per process: attaching a context that's
    /// already attached takes it over, and the earlier attachment goes quiet
    /// (its `detach()` then does nothing).
    func attach(
        _ room: KeepTalkingTransportRoom,
        events: @escaping KeepTalkingTransportEventHandler
    ) async throws -> any KeepTalkingTransportAttachment
}

/// A context as the transport sees it.
struct KeepTalkingTransportRoom: Sendable {
    let contextID: UUID
    /// Our node in the context.
    let nodeID: UUID
    /// The context's group secret: it addresses the room and seals every
    /// payload, so only members produce anything that opens.
    let secret: Data
}

typealias KeepTalkingTransportEventHandler = @Sendable (KeepTalkingTransportEvent) -> Void

/// Everything a room's attachment reports to its client.
enum KeepTalkingTransportEvent: Sendable {
    /// A member's envelope. `from` is the node whose link carried it, when the
    /// route names one; the SFU doesn't.
    case envelope(any KeepTalkingEnvelope, from: UUID?)
    /// A lossy realtime datagram (voice audio), as its sender sealed it.
    case datagram(Data)
    /// A member opened a blob transfer to us.
    case blobStream(any KeepTalkingBlobStreamReader, from: UUID)
    /// A link to the member came up.
    case peerConnected(UUID)
    /// The member's traffic moved to another link. Whatever went into the old
    /// one may be lost, so the client resyncs with it.
    case peerRerouted(UUID)
    /// The room can take sends it couldn't before, or has a new route. Sent
    /// once per change, not per queued frame.
    case readyToSend
    case statusChanged(KeepTalkingTransportStatus)
    case log(String)
}

/// One context's place on the process-wide transport, from attach to detach.
protocol KeepTalkingTransportAttachment: AnyObject, Sendable {
    /// Leaves the room. Idempotent; no events follow.
    func detach()
    /// Sends to the room, or to `envelope.targetPeerNodeID` alone. Throws
    /// ``KeepTalkingTransportError`` when it can't take the frame.
    func send(_ envelope: any KeepTalkingEnvelope) throws
    /// Lossy realtime bytes to every member a datagram reaches now. Never
    /// queued.
    func sendDatagram(_ datagram: Data) throws
    /// Opens a blob transfer to `node`, writing `header` first. Blob bytes go
    /// point to point, never through the SFU.
    func openBlobStream(to node: UUID, header: Data) async throws -> any KeepTalkingBlobStreamWriter
    /// We're about to ask `node` for a blob: get a link to it ready, so the
    /// transfer doesn't wait for one.
    func expectBlobStream(from node: UUID)
    func status() -> KeepTalkingTransportStatus
    func stats() -> KeepTalkingRuntimeStats
}

// MARK: - Blob streams

/// The sending side of one blob transfer: chunks in order, then `finish`
/// (complete) or `cancel`. The transport seals each chunk for the context.
protocol KeepTalkingBlobStreamWriter: AnyObject, Sendable {
    func write(_ chunk: Data) async throws
    func finish() async throws
    func cancel()
}

/// The receiving side of one blob transfer.
protocol KeepTalkingBlobStreamReader: AnyObject, Sendable {
    /// The transfer's header, as the sender wrote it.
    var header: Data { get }
    /// The next chunk, or nil once the sender finished.
    func next() async throws -> Data?
    func cancel()
}

enum KeepTalkingBlobStreamError: LocalizedError {
    case unreachable(UUID)
    case cancelled

    var errorDescription: String? {
        switch self {
            case .unreachable(let node): return "Node \(node) can't be reached for a blob transfer."
            case .cancelled: return "The blob transfer was cancelled."
        }
    }
}
