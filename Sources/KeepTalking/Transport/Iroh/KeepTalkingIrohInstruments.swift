import Foundation

/// A reading of a `KeepTalkingIrohTransportHost`: endpoint, hub session,
/// attached contexts, peer links and recent events. Values are plain data so
/// a lab can poll and diff them.
@_spi(TransportLab)
public struct KeepTalkingIrohInstruments: Sendable {
    public struct Hub: Sendable {
        public var status: String
        /// Connect attempts so far, including the current one.
        public var attempts: Int
        public var connectLatencyMs: Double?
        public var connectedSince: Date?
        public var selectedPath: String?
        public var rttMs: UInt64?
    }

    public struct Member: Sendable, Hashable {
        public var nodeID: UUID
        public var endpointID: String
    }

    public struct Context: Sendable, Identifiable {
        public var id: UUID
        public var nodeID: UUID
        /// The hub's snapshot for this context has arrived.
        public var joined: Bool
        /// Members whose sealed presence opened with the context secret.
        public var members: [Member]
    }

    public struct Path: Sendable, Hashable {
        public var remoteAddress: String
        public var isRelay: Bool
        public var isSelected: Bool
        public var rttMs: UInt64
    }

    public struct Peer: Sendable, Identifiable {
        /// Remote endpoint id (hex).
        public var id: String
        public var nodeIDs: [UUID]
        /// `dialed` (we hold the lower id) or `accepted`.
        public var side: String
        public var status: String
        public var connectLatencyMs: Double?
        /// Time from connect until a direct path was first selected.
        public var timeToDirectMs: Double?
        public var isDirect: Bool
        public var selectedPath: String?
        public var rttMs: UInt64?
        public var paths: [Path]
        public var framesSent: Int
        public var framesReceived: Int
        public var bytesSent: Int
        public var bytesReceived: Int
        public var datagramsSent: Int
        public var datagramsReceived: Int
        public var lostPackets: Int64?

        public var shortID: String { String(id.prefix(10)) }
    }

    public struct Event: Sendable, Identifiable {
        public let id: Int
        public let at: Date
        public let text: String
    }

    public var endpointID: String?
    public var boundSockets: [String]
    public var hub: Hub
    public var contexts: [Context]
    public var peers: [Peer]
    /// Peer frames dropped because the sender is not a sealed member of the
    /// frame's context.
    public var droppedFrames: Int
    public var events: [Event]
}
