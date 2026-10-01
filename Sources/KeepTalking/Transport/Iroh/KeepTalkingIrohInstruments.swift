import Foundation

/// A reading of a `KeepTalkingIrohTransportHost`: endpoint, hub session,
/// attached contexts, peer links and recent events. Values are plain data so
/// a lab can poll and diff them.
@_spi(TransportLab)
public struct KeepTalkingIrohInstruments: Sendable {
    public struct Hub: Sendable {
        public var status: String
        /// Configured, or looked up at `<relay>/kt/hub`; nil until known.
        public var hubID: String?
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
        /// The routing key (hex) derived from the context secret.
        public var topic: String
        public var nodeID: UUID
        /// The hub's snapshot for this topic has arrived.
        public var joined: Bool
        /// Members whose sealed presence opened with the context secret.
        public var members: [Member]
        /// Publishes sent over the mesh / through the hub.
        public var meshPublished: Int
        public var hubPublished: Int
        /// Frames received from peer links / delivered by the hub.
        public var meshReceived: Int
        public var hubReceived: Int
        public var hubDatagramsSent: Int
        public var hubDatagramsReceived: Int

        public var shortTopic: String { String(topic.prefix(10)) }
    }

    public struct Path: Sendable, Hashable {
        public var remoteAddress: String
        /// `relay`, `ip` or `bluetooth`.
        public var kind: String
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
        /// The selected path skips the relay (IP or Bluetooth).
        public var isDirect: Bool
        /// The selected path is Bluetooth.
        public var isBluetooth: Bool
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

    /// The Bluetooth transport, when the host was configured with it.
    public struct Bluetooth: Sendable {
        /// Adapter on and permission granted.
        public var powered: Bool
        public var txBytes: UInt64
        public var rxBytes: UInt64
        public var retransmits: UInt64
        public var devices: [BluetoothDevice]
    }

    public struct BluetoothDevice: Sendable, Identifiable {
        public var id: String
        /// `Discovered`, `Connecting`, `Connected`, …
        public var phase: String
        /// `Gatt` or `L2cap` once a data pipe exists.
        public var connectPath: String?
        /// The peer's endpoint id (hex) once its handshake verified it.
        public var endpointID: String?
        public var failures: Int
    }

    public struct Event: Sendable, Identifiable {
        public let id: Int
        public let at: Date
        public let text: String
    }

    public var endpointID: String?
    public var boundSockets: [String]
    /// Human-readable `DeliveryPolicy`.
    public var policy: String
    public var hub: Hub
    public var contexts: [Context]
    public var peers: [Peer]
    public var bluetooth: Bluetooth?
    /// Peer frames dropped because no attached context has their topic.
    public var droppedFrames: Int
    public var events: [Event]
}
